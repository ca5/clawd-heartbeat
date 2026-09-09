#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["hidapi>=0.14"]
# ///
"""Clawd Heartbeat — HOGP(BLE HID)ブリッジ

`ble-bridge.py` の兄弟。ソケットのプロトコルは同一なので led.sh からは同じに見える。
違いは BLE リンクを **自分で張らない**こと: HOGP(HID over GATT)でペアリングした Atom は
OS の HID ドライバがリンクを保持するので、このプロセスは「ソケット → Output Report」を
中継するだけの薄いパイプになる。再接続・keepalive・スリープ復帰は OS 任せ。

なぜ HID なのか: 会社の管理端末では MDM ポリシー `Bluetooth/ServicesAllowedList` が
SIG 標準 UUID しか許可しておらず、NUS のカスタム UUID では GATT の read/write が
`AccessDenied` になる。HOGP(0x1812)は許可リストに載っているので通る。キーボードとして
振る舞うのではなく、**ベンダー定義 usage page の Output Report** をコマンドチャネルに使う
(キーボード/マウスのコレクションは OS がユーザー空間から開かせないが、ベンダー定義は開ける)。

  hook (led.sh) ──1行──> ソケット ──> hid-bridge.py ──Output Report──> Atom
                                       Atom <──Input Report の read── status の応答

status の読み出しは notify ではなく **GATT read**(Windows では HidD_GetInputReport)で行う。
notify の購読は BLE リンクが張り直されると黙って失われることがあり、依存できない(実測)。

使い方:
  uv run hid-bridge.py --scan     # 候補の HID デバイスを列挙(まずこれで見えるか確認)
  uv run hid-bridge.py            # 既定のソケット/ポートで待ち受け
"""
import argparse
import asyncio
import os
import sys
import time

try:
    import hid
except ImportError:
    sys.stderr.write("hidapi がありません。`uv run hid-bridge.py` で起動するか `pip install hidapi` してください\n")
    sys.exit(2)

# firmware(src/main.cpp)と一致させること
HID_REPORT_ID = 1
HID_OUT_LEN = 64             # host → Atom(コマンド 1 行)
HID_IN_LEN = 512             # Atom → host(status の本文を丸ごと)
VENDOR_USAGE_PAGE = 0xFF00   # report map の Usage Page (Vendor Defined)
DEFAULT_NAME = "clawd-heartbeat"
DEFAULT_PORT = 47821         # ble-bridge.py の 47820 とぶつけない


def default_socket():
    base = os.environ.get("TMPDIR", "/tmp")
    return os.path.join(base, "claude-led-hid.sock")


def unix_sockets_available():
    return hasattr(asyncio, "start_unix_server")


def log(msg):
    print(f"[hid-bridge] {msg}", flush=True)


def candidates(name, vid, pid):
    """ベンダー定義 usage page のコレクションだけを返す。キーボード/マウスには触らない。"""
    out = []
    for d in hid.enumerate():
        if d.get("usage_page", 0) < VENDOR_USAGE_PAGE:
            continue
        if vid and d["vendor_id"] != vid:
            continue
        if pid and d["product_id"] != pid:
            continue
        if name and name.lower() not in (d.get("product_string") or "").lower():
            continue
        out.append(d)
    return out


class Bridge:
    def __init__(self, name, vid, pid):
        self.name, self.vid, self.pid = name, vid, pid
        self.dev = None
        self.path = None
        self.lock = asyncio.Lock()       # HID 操作を直列化(同時 write の衝突回避)
        self.last_error = ""

    def _open(self):
        # 開いたままにしておく。デバイスが消えれば write が例外になるので、そこで開き直す
        if self.dev:
            return True
        cands = candidates(self.name, self.vid, self.pid)
        if not cands:
            self.last_error = "device not found (paired via HOGP?)"
            return False
        for d in cands:
            try:
                h = hid.device()
                h.open_path(d["path"])
                h.set_nonblocking(0)
                self.dev, self.path = h, d["path"]
                self.last_error = ""
                log(f"opened {d['vendor_id']:04x}:{d['product_id']:04x} "
                    f"up=0x{d.get('usage_page', 0):04X} {d.get('product_string') or '?'}")
                return True
            except Exception as e:
                self.last_error = str(e)
        log(f"open failed: {self.last_error}")
        return False

    def _close(self):
        if self.dev:
            try:
                self.dev.close()
            except Exception:
                pass
        self.dev = None

    def _read_response(self):
        """Input Report を GATT read して NUL 終端の本文を取り出す。"""
        data = self.dev.get_input_report(HID_REPORT_ID, HID_IN_LEN + 1)
        if not data:
            return ""
        b = bytes(data)
        if len(b) > HID_IN_LEN:
            b = b[1:]                    # 先頭が report ID の実装(Windows)を吸収
        end = b.find(b"\0")
        return b[:end if end >= 0 else len(b)].decode(errors="replace")

    async def send_line(self, line: str) -> str:
        async with self.lock:
            if not self._open():
                return f"error: {self.last_error or 'not connected'}\n"
            payload = line.encode()[:HID_OUT_LEN - 1]
            report = bytes([HID_REPORT_ID]) + payload + b"\0" * (HID_OUT_LEN - len(payload))
            try:
                self.dev.write(report)
                if line.strip() == "status":
                    time.sleep(0.25)     # firmware が loop() で処理して setValue するのを待つ
                    body = self._read_response()
                    return (body if body.endswith("\n") else body + "\n") if body else "error: no response\n"
                return "ok\n"
            except Exception as e:
                log(f"write failed: {e}")
                self._close()            # 次回開き直す(ペアリング切れ・スリープ復帰など)
                return f"error: {e}\n"


async def handle_client(reader, writer, bridge: Bridge):
    try:
        data = await asyncio.wait_for(reader.readline(), timeout=5)
        line = data.decode(errors="replace").rstrip("\r\n")
        if line:
            resp = await bridge.send_line(line)
            writer.write(resp.encode())
            await writer.drain()
    except Exception as e:
        log(f"client error: {e}")
        try:
            writer.write(f"error: {e}\n".encode())
            await writer.drain()
        except Exception:
            pass
    finally:
        writer.close()


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default=DEFAULT_NAME,
                    help="product string の部分一致で絞る(既定: clawd-heartbeat。空文字で無効)")
    ap.add_argument("--vid", type=lambda v: int(v, 0), default=0, help="USB/HID ベンダー ID を直指定")
    ap.add_argument("--pid", type=lambda v: int(v, 0), default=0, help="USB/HID プロダクト ID を直指定")
    ap.add_argument("--socket", default=default_socket(), help="待ち受ける Unix ソケットのパス(POSIX)")
    ap.add_argument("--port", type=int, default=None,
                    help=f"Unix ソケットではなく 127.0.0.1:<port> で待ち受ける(Windows 既定: {DEFAULT_PORT})")
    ap.add_argument("--scan", action="store_true", help="ベンダー定義 HID コレクションを列挙して終了(診断用)")
    args = ap.parse_args()

    if args.scan:
        # 名前で絞らずに全部出す。どれが Atom か分からないときのため
        rows = [d for d in hid.enumerate() if d.get("usage_page", 0) >= VENDOR_USAGE_PAGE]
        log(f"vendor-defined HID collections: {len(rows)}")
        for d in rows:
            mine = " <== clawd?" if DEFAULT_NAME.lower() in (d.get("product_string") or "").lower() else ""
            log(f"  {d['vendor_id']:04x}:{d['product_id']:04x} up=0x{d.get('usage_page', 0):04X} "
                f"usage=0x{d.get('usage', 0):02X} {d.get('product_string') or '?'}{mine}")
        if not rows:
            log("何も見えません。Windows の設定で Atom を HOGP としてペアリングしてください")
        return

    port = args.port
    if port is None and not unix_sockets_available():
        port = DEFAULT_PORT      # Windows: Unix ソケットが無いので loopback TCP

    bridge = Bridge(args.name or None, args.vid, args.pid)
    handler = lambda r, w: handle_client(r, w, bridge)
    if port is not None:
        server = await asyncio.start_server(handler, host="127.0.0.1", port=port)
        where = f"127.0.0.1:{port}"
    else:
        if os.path.exists(args.socket):
            os.unlink(args.socket)
        server = await asyncio.start_unix_server(handler, path=args.socket)
        os.chmod(args.socket, 0o600)
        where = args.socket
    log(f"listening on {where} (looking for {args.name or 'any vendor-defined HID'})")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
