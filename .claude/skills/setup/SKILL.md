---
name: setup
description: >
  Interactive first-time setup for Clawd Heartbeat. Use when the user says
  "set this up", "setup", "install", "get it working", "flash it", asks what to do
  after cloning — or in Japanese:「セットアップして」「初期設定」「導入したい」
  「動かしたい」「書き込んで」. Walks through transport choice (WiFi or USB serial) →
  WiFi config → build & flash → device address → hook installation → verification,
  one validated step at a time.
---

# Clawd Heartbeat セットアップ手順

各フェーズに検証があります。検証を飛ばして先に進まないこと(失敗箇所の切り分けができなくなる)。
ユーザーの言語(日本語/英語)に合わせて進めてください。

**サンドボックスの制約**: Claude Code の Bash からは `/dev/cu.*`(シリアル)を開けず、`~/.platformio` と
`~/.claude/led.sh` にも書けない(Write/Edit ツールでファイル作成はできるが chmod は不可)。
`pio run -t upload`・シリアルの疎通確認・`chmod +x` はユーザーに `! <コマンド>` で実行してもらい、
出力を見て次に進む。

## 0. 前提確認

1. `pio --version` で PlatformIO Core CLI の有無を確認。なければ `brew install platformio`(macOS)等で導入
2. M5Atom Lite を USB 接続し、ポートが見えるか確認。macOS/Linux は
   `ls /dev/cu.usb* /dev/ttyUSB* /dev/ttyACM*`、Windows の Git Bash は `ls /dev/ttyS*`
   (`/dev/ttyS<N>` = `COM<N+1>`。PowerShell なら `[System.IO.Ports.SerialPort]::GetPortNames()`)
   - 見えない場合: 充電専用ケーブルか、データ線が断線したケーブルが最頻出の原因。
     電源線だけ生きていると Atom の LED は点くのに OS はデバイスを一切認識しない。
     別の USB 機器が同じポートで認識されるならケーブルを交換してもらう。次点でドライバ(CH9102/CP210x)
3. Windows の場合は Git Bash が必須(`where.exe bash` で PATH を確認)。
   ユーザーが `!` で実行するコマンドは PowerShell で走るので、シェルスクリプトは `bash -c '...'` に包んで渡す

## 1. 経路の選択と WiFi 設定

まず **WiFi か USB シリアルか**を決める(両方同時も可):

| 経路 | 向いている環境 | 必要なもの |
| :--- | :--- | :--- |
| WiFi/HTTP | 自宅など、Mac と Atom を同じ LAN に置ける。Atom を USB 電源だけで好きな場所に置きたい | 2.4GHz の SSID/パスワード、ルーターの DHCP 予約 |
| USB シリアル | 来客用 WiFi(端末間通信の遮断)、802.1X の社内 WiFi、DHCP 予約不可など、Mac から Atom に HTTP が届かない | Atom を Mac に USB 直結しておくこと |
| BLE | WiFi が使えず、かつ Atom を無線(USB 電源のみ)にしたい | uv(または `pip install bleak`)、初回の macOS Bluetooth 許可、常駐デーモン ble-bridge.py |
| HOGP(BLE HID)| 管理端末で MDM が BLE のカスタム UUID を弾く。無線にもしたい | uv(または `pip install hidapi`)、OS 設定でのペアリング、常駐デーモン hid-bridge.py |

**Windows の管理端末では、まず MDM ポリシーを読むこと**。`Bluetooth/ServicesAllowedList`
(`HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Bluetooth`)が SIG 標準 UUID のみを
許可していると、素の BLE 経路はスキャンとサービス探索だけ成功して GATT の read/write が
`AccessDenied` になる。判断はこう:

- 許可リストに **0x1812 がある** → **HOGP 経路**を選ぶ(3d 参照)。0x180A / 0x1813 も必要
- 無い → USB シリアルか WiFi。`AllowAdvertising=0` なら advertising を使う案も塞がれている

### 3d. HOGP(BLE HID)の場合

1. `HID_ENABLED = true`(`main` の既定)のファームウェアを書き込む
2. `./led-test.sh status` の `hid=ready` で HID サービスの起動を確認(シリアルか BLE 経由で)
3. **OS の設定から `clawd-heartbeat` をペアリング**してもらう(ユーザー操作)。暗号化必須なので
   ボンディングが走る。IO 無しの Just Works なので PIN は出ない
4. `uv run hid-bridge.py --scan` で `up=0xFF00` のベンダー定義コレクションとして見えるか確認。
   見えなければペアリングを疑う
5. `uv run hid-bridge.py` で常駐起動 → `ATOM=hid ./led-test.sh status` が返ること
6. hook は `~/.claude/led.conf` に `ATOM_HID="1"`。`ATOM_SERIAL="auto"` も併記すると
   ペアリング切れ時に USB へ落ちる。led.sh が `uv run --script` でデーモンを自動起動する

会社・共有オフィスなら最初から USB シリアルを勧める(WiFi で試してから ARP 未解決で気づくと時間を無駄にする)。

1. `cp include/secrets.h.example include/secrets.h`
2. WiFi を使うなら **2.4GHz の SSID とパスワード**を記入(Atom Lite は 5GHz 非対応)。
   ユーザーが自分で編集したい場合はプレースホルダの場所を案内して待つ。
   USB シリアルだけなら SSID は空文字 `""` にする(WiFi が無効になり、起動時の紫も出ない)
3. secrets.h は gitignore 済みであることを伝える

## 2. ビルドと書き込み

```bash
pio run -t upload
```

- 初回は toolchain のダウンロードで数分かかる(異常ではない)
- `espressif32@6.9.0` の解決に失敗したら**ユーザーに報告**。勝手に最新版へ上げない
- 書き込みモードに入らない場合: Atom のボタン(LED 面)を押しながら USB を挿し直してもらう

**検証**: 書き込み成功後、LED が青(idle)になること。WiFi 設定ありなら紫(接続中)を経由する。
紫が 20 秒以上続いたあと青になるなら WiFi 未接続(SSID/パスワード/2.4GHz を再確認)。
USB シリアルだけで使うなら紫は無視してよい。

## 3. 宛先の確認

### 3c. BLE の場合

1. `BLE_ENABLED = true` のファームウェアを書き込む(`main` の既定で有効)
2. `uv run ble-bridge.py --scan` で Atom(`<== clawd?` 付き)が見えるか確認。見えなければ広告分割か Bluetooth 許可を疑う
3. `uv run ble-bridge.py` で常駐起動 → 初回の許可ダイアログを許可 → ログに `connected`
4. **検証**(ユーザー実行): `ATOM=ble ./led-test.sh status` が `ble=connected` を返し、`ATOM=ble ./led-test.sh send tool default` が 1 秒未満で返ること
5. hook は `~/.claude/led.conf` に `ATOM_BLE="1"` を書く(`ATOM_SERIAL` は空)。led.sh が `uv run --script` でデーモンを自動起動する
6. Windows では Unix ソケットが使えないため、デーモンは自動で `127.0.0.1:47820` の loopback TCP に切り替わる(設定不要)

### 3a. USB シリアルの場合

1. ポートのパスを確認。macOS は `ls /dev/cu.usbserial-*`(チップのシリアル番号由来で抜き差ししても変わらない)、
   Windows は `ls /dev/ttyS*`(**抜き差しで COM 番号が変わる**)
2. `echo auto > .atom-ip` を作成(gitignore 済み)。`auto` は候補からポートを探してキャッシュするので、
   Windows の番号変化に追従する。固定したいなら実パスを書いてもよい
3. **検証**(ユーザー実行): `./led-test.sh status` が `state=idle` 等を返すこと。
   書き込み直後の**最初の 1 回だけ**は初回オープンでボードがリセットされ空応答になることがあるので、もう 1 回叩く
4. **リセット検証**(ユーザー実行): `for i in $(seq 1 15); do ./led-test.sh send tool default; done; ./led-test.sh status; ./led-test.sh off`
   で `ok` が並び、`uptime=` が小さく戻っていないこと。戻っていたら送信のたびにリセットしている
   (`-hupcl` が効いていない)。docs/NOTES.md「USB シリアル経路の追加」の次善策(ポート保持プロセス)を検討

### 3b. WiFi の場合

1. シリアルから IP と MAC を読む。`pio device monitor` は TTY 必須で背景実行不可なので、
   非対話シェルでは pyserial を使う(ポートを `dtr=False` `rts=False` で開いてから読む。
   起動ログを見たいときは `rts=True` を 0.2 秒だけ立ててリセットする)。
   ファームウェアの `status` コマンドの `wifi=` 行でも IP は分かる
2. 表示された IP と MAC を伝え、**ルーターの DHCP 予約で IP を固定**してもらう(ユーザー操作)。
   固定できない環境なら `http://atom.local`(mDNS)も使えるが、mDNS を止めるネットワークもある
3. `echo "http://<IP>" > .atom-ip` を作成(gitignore 済み)
4. **検証**: `./led-test.sh status` が state 等を返すこと。返らない場合は Mac から
   `arp -n <IP>` を見る。`incomplete` ならネットワークが端末間通信を遮断している → 3a に切り替える

## 4. hook 設定

1. `cp led.sh ~/.claude/led.sh && chmod +x ~/.claude/led.sh`。
   **経路は led.sh 本体ではなく `~/.claude/led.conf` に書く**(led.sh が既定値の直後に読む):
   USB なら `echo 'ATOM_SERIAL="auto"' > ~/.claude/led.conf`、WiFi なら `ATOM_URL` を実 IP で。
   本体に直接書くと、リポジトリ更新の再コピーで設定が消え、HTTP 経路に落ちて curl が exit 28 を
   返すだけの無言の失敗になる(stderr にも出ないので原因が掴めない)
2. `~/.claude/settings.json` の `hooks` に README 記載の 10 イベントをマージする。
   コマンドは `bash ~/.claude/led.sh <state>` の形にする。`$HOME` は hook が PowerShell や cmd から
   起動されたときに展開されず、`.sh` も直接実行できない。`~` はそのまま bash に渡って bash が展開する
   **既存の settings.json を丸ごと上書きしない**こと。既に hooks キーがある場合は中身を統合。
   編集後は JSON の構文検証を行う
3. すべてのイベントで `"async": true` が付いていることを確認(付いていないと Claude Code がブロックされる)
4. `diff led.sh ~/.claude/led.sh` に差分が無いことを確認(経路は led.conf 側にあるので一致するはず)

## 5. 最終検証

1. Claude Code を再起動してもらい、`/hooks` で全イベントが読み込まれていることを確認
2. 適当なファイルを読ませて: 白の呼吸(作業中)→ 緑点滅 6 秒(完了)→ 青(idle)と遷移すること
3. 許可のいらないコマンドを何か実行させて権限ダイアログを出し、赤点滅になること
4. 全部通ったら完了。`docs/LIFECYCLE.md` に「Yes 押したのに赤いまま」等の既知挙動が
   あることを一言案内する

## トラブル時

README のトラブルシュート表と `docs/NOTES.md` を参照。デバイスの状態は
`./led-test.sh status` でセッション別に確認できる。
