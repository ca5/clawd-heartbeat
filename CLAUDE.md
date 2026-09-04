# Clawd Heartbeat — project context for Claude

A physical Claude Code status indicator: M5Atom Lite firmware (PlatformIO/C++) + a hook script. The LED shows session state through a 3D-printed figure's heart window. Three transports carry the same one-line commands: HTTP over WiFi, USB serial, or BLE (for networks where the Mac can't reach the Atom). BLE needs a resident Mac-side daemon (`ble-bridge.py`, uv-run) that holds the connection.

## Helping the user

- First-time device setup → use the `setup` skill (interactive: transport choice, WiFi, flash, hooks)
- BLE transport lives on the `bluetooth-spp` branch (firmware BLE peripheral + `ble-bridge.py`); `main` has WiFi + USB serial only
- Color/brightness tuning for their filament/case → use the `led-tuning` skill
- "Why is it red/white/off?" questions → read `docs/LIFECYCLE.md` first; most "bugs" are documented behaviors (approval/interrupt are invisible to hooks)

## Project map

- `src/main.cpp` — firmware: per-session state, priority aggregation (`wait > err > done > tool > idle`), all colors/timings. `applyLed` / `applyRgb` / `statusBody` / `handleLine` are shared by the HTTP handlers, the USB serial parser (`pollSerial`), and the BLE characteristic writes (`pollBle`, drained from an SPSC ring the BLE callback fills). WiFi is optional (empty SSID) and non-blocking; `BLE_ENABLED` toggles the BLE peripheral
- `led.sh` — hook script (copy lives at `~/.claude/led.sh`): transport switch (`ATOM_BLE` > `ATOM_SERIAL` > `ATOM_URL`), session_id extraction, AskUserQuestion→wait, dialog-wait marker (subagent overwrite protection), send timestamp, transcript watcher that catches denials/interrupts (which fire no hook event). BLE mode writes lines to the `ble-bridge.py` Unix socket and autostarts the daemon
- `ble-bridge.py` — Mac-side BLE daemon (bleak, uv/PEP723). Holds the BLE connection, exposes a Unix socket, forwards command lines to the RX characteristic. `pyproject.toml` + `uv.lock` make `uv run ble-bridge.py` self-contained
- `led-test.sh` — manual testing (`status` / `states` / `rgb` / `ramp` / `coupon`); device address from `ATOM` env or gitignored `.atom-ip` — `ble` (or `ble:<sock>`) means BLE, `/dev/...` means serial, anything else is an HTTP URL
- `led-demo.sh` — non-interactive animation playback for filming/verification (`states` / `story` / `wait-full`, `--solo` to stop other sessions overriding it)
- `docs/NOTES.md` — design decisions + empirically measured hook behavior (Japanese)
- `docs/LIFECYCLE.md` — event→LED mapping and hook blind spots (Japanese)

## Hard constraints (do not change casually)

- `platform = espressif32@6.9.0` is pinned — newer platforms break with Arduino core 3.x. If resolution fails, tell the user; do not bump
- No `delay()` in `loop()` — animations are `millis()`-based; delay stalls the web server
- WiFi credentials live only in `include/secrets.h` (gitignored). Never commit real credentials, device IPs, or MAC addresses — personal values go in gitignored `docs/LOCAL.md` / `.atom-ip`
- If both `led.sh` here and `~/.claude/led.sh` exist, keep them in sync when editing
- Serial writes must keep DTR/RTS steady: always open the port with `stty -hupcl` (as `send_serial` / `atom_send` do). A plain `echo > /dev/cu.*` or a serial monitor resets the board on close (DTR/RTS are wired to EN/IO0)
- BLE advertising has a 31-byte cap: put the 128-bit service UUID in the adv packet and the name in the scan response (`setScanResponseData`), or macOS never sees the device. `WiFi.setSleep(true)` is required whenever the radio coexists with BLE, else the controller aborts at boot
- BLE firmware needs the 3MB app partition (`board_build.partitions = huge_app.csv` in platformio.ini); do not drop it while BLE is enabled

## Flashing & verification

```bash
pio run -t upload                 # auto-detects port; hold the Atom's button while plugging USB if download mode fails
./led-test.sh status              # aggregated + per-session state from the device
./led-test.sh states              # replay all 5 states visually
```

`pio device monitor` needs a TTY (fails in background shells) — read serial with pyserial setting `dtr=False`/`rts=False` before open (recipe in docs/NOTES.md). With the serial transport, `./led-test.sh status` is usually all you need.

The Claude Code Bash sandbox cannot open `/dev/cu.*`, write `~/.platformio`, or write `~/.claude/led.sh`; ask the user to run `pio run -t upload`, `chmod +x ~/.claude/led.sh` and serial checks themselves (the `!` prefix runs a command in the session).
