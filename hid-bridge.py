#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = [
#   "hidapi>=0.14",
#   "winrt-runtime>=3.0; sys_platform == 'win32'",
#   "winrt-Windows.Devices.Bluetooth>=3.0; sys_platform == 'win32'",
#   "winrt-Windows.Devices.Bluetooth.GenericAttributeProfile>=3.0; sys_platform == 'win32'",
#   "winrt-Windows.Devices.Enumeration>=3.0; sys_platform == 'win32'",
#   "winrt-Windows.Foundation>=3.0; sys_platform == 'win32'",
#   "winrt-Windows.Foundation.Collections>=3.0; sys_platform == 'win32'",
# ]
# ///
"""Clawd Heartbeat — HOGP(BLE HID)ブリッジ

`ble-bridge.py` の兄弟。ソケットのプロトコルは同一なので led.sh からは同じに見える。
違いは BLE の**接続とデータ転送を OS の HID スタックに任せる**こと: 再接続・ペアリング・
GATT の詳細はドライバ側が持ち、このプロセスは「ソケット → Output Report」を中継する。

ただし **Windows はリンクを勝手には保持してくれない**(実測)。入力トラフィックの無い
ベンダー定義 HID はアイドルで切られ、ボンドは残るのにリンクだけ落ちる(デバイスは広告を
出し続けているのに `connection_status=0`、HID コレクションも消える)。そのため Windows では
`maintain_connection` の GattSession を掴んでリンクを上げたままにする。掴んでいる間だけ
接続が維持され、離すと即座に切れる。

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

# Windows のリンク保持にだけ使う。無ければ保持をあきらめて動く(POSIX ではそもそも不要)
try:
    from winrt.windows.devices.bluetooth import BluetoothLEDevice
    from winrt.windows.devices.bluetooth.genericattributeprofile import GattSession
    from winrt.windows.devices.enumeration import (
        DeviceInformation, DevicePairingKinds, DevicePairingProtectionLevel,
    )
    HAVE_WINRT = True
except ImportError:
    HAVE_WINRT = False


async def find_paired_info(name, paired=True):
    """ペアリング状態で絞って BLE デバイスを名前で探す(Windows)。"""
    sel = BluetoothLEDevice.get_device_selector_from_pairing_state(paired)
    infos = await DeviceInformation.find_all_async_aqs_filter(sel)
    return next((di for di in infos
                 if not name or name.lower() in (di.name or "").lower()), None)


async def repair(name):
    """ボンドを捨てて張り直す。

    Atom が再起動すると Windows 側のボンドと食い違うことがあり、そうなると
    「2 秒ごとに接続しては切れる」を繰り返す(暗号化に失敗して切られるため)。
    リンクは CONNECTED と DISCONNECTED を往復し、HID コレクションも出たり消えたりする。
    ペアリングし直せば直る。IO が無いので Just Works(確認のみ)で完了する。
    """
    if not HAVE_WINRT:
        log("--repair は Windows 専用です")
        return
    di = await find_paired_info(name, True)
    if di is not None:
        r = await di.pairing.unpair_async()
        log(f"unpaired (status={r.status})")
        await asyncio.sleep(3)
    di = await find_paired_info(name, False)
    if di is None:
        log("デバイスが見つかりません。電源が入って広告しているか確認してください")
        return
    custom = di.pairing.custom
    token = custom.add_pairing_requested(lambda s, a: a.accept())
    try:
        res = await custom.pair_with_protection_level_async(
            DevicePairingKinds.CONFIRM_ONLY, DevicePairingProtectionLevel.ENCRYPTION)
        log(f"pair status={res.status} protection={res.protection_level_used}")
    finally:
        custom.remove_pairing_requested(token)

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
        self.session = None              # GattSession。掴んでいる間だけ BLE リンクが上がる

    async def ensure_link(self):
        """ボンド済みでもリンクが落ちるので、GattSession を掴んで上げたままにする(Windows)。

        HOGP は「OS がリンクを保持する」のが売りだが、入力トラフィックの無いベンダー定義 HID は
        アイドルで切られる。セッションを閉じた途端に DISCONNECTED になることを実測で確認済み。
        """
        if not HAVE_WINRT:
            return False
        if self.session is not None and self.session.session_status == 1:   # 1 = Active
            return True
        self.session = None
        try:
            sel = BluetoothLEDevice.get_device_selector_from_pairing_state(True)
            infos = await DeviceInformation.find_all_async_aqs_filter(sel)
            target = next((di for di in infos
                           if not self.name or self.name.lower() in (di.name or "").lower()), None)
            if target is None:
                self.last_error = "paired BLE device not found (OS 設定でペアリングしてください)"
                return False
            dev = await BluetoothLEDevice.from_id_async(target.id)
            if dev is None:
                self.last_error = "BluetoothLEDevice unavailable"
                return False
            s = await GattSession.from_device_id_async(dev.bluetooth_device_id)
            s.maintain_connection = True
            self.session = s
            log(f"holding a GATT session for {target.name} (keeps the link up)")
            return True
        except Exception as e:
            self.last_error = str(e)
            log(f"link keeper failed: {e}")
            return False

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
                # リンクが落ちていると HID コレクション自体が見えなくなる。張り直して待つ
                await self.ensure_link()
                for _ in range(8):
                    await asyncio.sleep(1.0)
                    if self._open():
                        break
                else:
                    return f"error: {self.last_error or 'not connected'}\n"
            payload = line.encode()[:HID_OUT_LEN - 1]
            report = bytes([HID_REPORT_ID]) + payload + b"\0" * (HID_OUT_LEN - len(payload))
            try:
                self.dev.write(report)
                if line.strip() == "status":
                    time.sleep(0.25)     # firmware が loop() で処理して setValue するのを待つ
                    # 再接続直後は read が一度こけることがある(デバイスノードが落ち着く前)
                    for attempt in range(3):
                        try:
                            body = self._read_response()
                            break
                        except Exception:
                            if attempt == 2:
                                raise
                            time.sleep(0.6)
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
    ap.add_argument("--repair", action="store_true",
                    help="ボンドを捨てて張り直す(2 秒ごとに接続と切断を繰り返すときの復旧)")
    args = ap.parse_args()

    if args.repair:
        await repair(args.name or None)
        return

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
    # 最初の hook イベントが来る前にリンクを上げておく(起動直後の取りこぼしを防ぐ)
    await bridge.ensure_link()
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
