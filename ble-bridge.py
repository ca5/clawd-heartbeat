#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["bleak>=0.22"]
# ///
"""Clawd Heartbeat — BLE 常駐ブリッジ(Mac / Windows 側)

macOS は BLE をシリアルポートとして見せてくれないため、このデーモンが Atom への BLE 接続を
保持し続け、ローカルのソケット経由で受け取った 1 行コマンドを GATT の RX 特性へ write する。
待ち受け口は POSIX なら Unix ソケット、Windows なら loopback TCP(127.0.0.1:47820)。Windows の
CPython には AF_UNIX も asyncio.start_unix_server も無いため、ここだけ自動で切り替わる。
接続は張りっぱなしなので、Bluetooth Classic(SPP)で問題になった「open のたびに約 2 秒の
再接続待ち + idle で切断」が起きない。

  hook (led.sh) ──1行──> Unix ソケット ──> ble-bridge.py ──BLE write──> Atom(RX 特性)
                                            Atom(TX 特性)──notify/read──> status

依存: bleak。uv があれば `uv run ble-bridge.py` で自動的に用意される(PEP 723 のインライン
メタデータ)。uv を使わない場合は `pip install bleak` してから python3 で起動する。
初回は macOS が「Bluetooth の使用を許可しますか」を出すので許可すること(不許可だとスキャンが空振り)。

使い方:
  uv run ble-bridge.py                    # スキャンして name で接続、既定ソケットで待ち受け(推奨)
  uv run ble-bridge.py --address <UUID>   # アドレス直指定(スキャンを省ける。macOS は UUID)
  uv run ble-bridge.py --port 47820       # Unix ソケットではなく loopback TCP で待つ(Windows 既定)
  echo "led s=tool sid=x" | nc -U /tmp/... # 動作確認(led.sh は自動でこのソケットに書く)

ソケットのプロトコル: 1 接続 = 1 行送信 → 1 行(以上)応答。
  "status" を送ると Atom の TX(statusBody)を読んで返す。それ以外は RX に write して "ok"。
"""
import argparse
import asyncio
import os
import sys
import time

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    sys.stderr.write("bleak がありません。`uv run ble-bridge.py` で起動するか `pip install bleak` してください\n")
    sys.exit(2)

SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
RX_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
TX_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
DEFAULT_NAME = "clawd-heartbeat"
DEFAULT_PORT = 47820        # Unix ソケットが使えない環境(Windows)での待ち受けポート


def default_socket():
    base = os.environ.get("TMPDIR", "/tmp")
    return os.path.join(base, "claude-led-ble.sock")


def unix_sockets_available():
    # Windows の CPython は AF_UNIX を持たず、asyncio.start_unix_server も生えていない
    return hasattr(asyncio, "start_unix_server")


def log(msg):
    print(f"[ble-bridge] {msg}", flush=True)


class Bridge:
    def __init__(self, name, address):
        self.name = name
        self.address = address
        self.client = None
        self.lock = asyncio.Lock()          # BLE 操作を直列化(同時 write の衝突回避)
        self.last_tx = ""                    # 直近に notify で受けた TX(status の即応用)
        self.last_error = ""                 # 直近の接続失敗理由(呼び手に返す)

    def _on_tx(self, _handle, data: bytearray):
        self.last_tx = data.decode(errors="replace")

    async def ensure_connected(self):
        if self.client and self.client.is_connected:
            return True
        # アドレス未指定ならスキャンして探す。macOS は広告に名前を載せないことがあるので、
        # まずサービス UUID で照合し、見つからなければ名前でフォールバックする
        addr = self.address
        try:
            if not addr:
                dev = await BleakScanner.find_device_by_filter(
                    lambda d, adv: SERVICE_UUID.lower() in [u.lower() for u in adv.service_uuids],
                    timeout=12.0)
                if not dev:
                    dev = await BleakScanner.find_device_by_name(self.name, timeout=8.0)
                if not dev:
                    self.last_error = "device not found"
                    log(f"device not found (service {SERVICE_UUID[:8]}… / name '{self.name}')")
                    return False
                addr = dev
            # Windows は GATT の探索結果をキャッシュするので、一度 write に失敗して張り直すと
            # 特性が見つからなくなることがある。毎回探索し直させる(macOS 側は無関係)
            kw = {"winrt": {"use_cached_services": False}} if os.name == "nt" else {}
            self.client = BleakClient(addr, disconnected_callback=lambda _c: log("disconnected"), **kw)
            await self.client.connect()
            try:
                await self.client.start_notify(TX_UUID, self._on_tx)
            except Exception:
                pass  # notify が張れなくても read で status は取れる
            self.last_error = ""
            log("connected")
            return True
        except Exception as e:
            # スキャン/接続で出る例外(Bluetooth オフ = POWERED_OFF など)は握って理由を残す。
            # ここで raise させるとブリッジのタスクが落ちる
            self.last_error = str(e)
            log(f"connect failed: {e}")
            self.client = None
            return False

    async def send_line(self, line: str) -> str:
        async with self.lock:
            if not await self.ensure_connected():
                return f"error: {self.last_error or 'not connected'}\n"
            try:
                if line.strip() == "status":
                    # RX に status を投げ、TX(read)で最新を取る
                    await self.client.write_gatt_char(RX_UUID, b"status\n", response=False)
                    await asyncio.sleep(0.15)
                    val = await self.client.read_gatt_char(TX_UUID)
                    return val.decode(errors="replace")
                await self.client.write_gatt_char(RX_UUID, (line + "\n").encode(), response=False)
                return "ok\n"
            except Exception as e:
                log(f"write failed: {e}")
                self.client = None            # 次回再接続させる
                return f"error: {e}\n"

    async def keepalive(self):
        # 接続が切れていたら黙って張り直す(idle でも接続維持)
        while True:
            if not (self.client and self.client.is_connected):
                await self.ensure_connected()
            await asyncio.sleep(5)


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
            writer.write(f"error: {e}\n".encode())  # 呼び手が理由を見られるように返す
            await writer.drain()
        except Exception:
            pass
    finally:
        writer.close()


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default=DEFAULT_NAME, help="BLE デバイス名(既定: clawd-heartbeat)")
    ap.add_argument("--address", default="", help="BLE アドレス/UUID を直指定(スキャン省略)")
    ap.add_argument("--socket", default=default_socket(), help="待ち受ける Unix ソケットのパス(POSIX)")
    ap.add_argument("--port", type=int, default=None,
                    help=f"Unix ソケットではなく 127.0.0.1:<port> で待ち受ける(Windows 既定: {DEFAULT_PORT})")
    ap.add_argument("--scan", action="store_true", help="近くの BLE デバイスを列挙して終了(診断用)")
    args = ap.parse_args()

    if args.scan:
        log("scanning 8s ...")
        devs = await BleakScanner.discover(timeout=8.0, return_adv=True)
        for d, adv in devs.values():
            uuids = ",".join(adv.service_uuids) or "-"
            mine = " <== clawd?" if SERVICE_UUID.lower() in [u.lower() for u in adv.service_uuids] else ""
            log(f"{d.address}  name={adv.local_name or d.name or '?'}  rssi={adv.rssi}  uuids={uuids}{mine}")
        return

    port = args.port
    if port is None and not unix_sockets_available():
        port = DEFAULT_PORT     # Windows: Unix ソケットが無いので loopback TCP に落とす

    bridge = Bridge(args.name, args.address or None)
    asyncio.create_task(bridge.keepalive())
    handler = lambda r, w: handle_client(r, w, bridge)
    if port is not None:
        # loopback にだけ bind する。外部からは繋がらないが、同じマシンの他プロセスからは
        # 繋がる(Unix ソケットの 0600 ほど厳密ではない)。送れるのは LED コマンドだけ
        server = await asyncio.start_server(handler, host="127.0.0.1", port=port)
        where = f"127.0.0.1:{port}"
    else:
        if os.path.exists(args.socket):
            os.unlink(args.socket)
        server = await asyncio.start_unix_server(handler, path=args.socket)
        os.chmod(args.socket, 0o600)
        where = args.socket
    log(f"listening on {where} (device: {args.address or args.name})")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
