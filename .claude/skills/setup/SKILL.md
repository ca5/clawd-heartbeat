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
2. M5Atom Lite を USB 接続し、`ls /dev/cu.usb* /dev/ttyUSB* /dev/ttyACM*` でポートが見えるか確認
   - 見えない場合: 充電専用ケーブルが最頻出の原因。データ対応ケーブル(C to C 推奨)に交換してもらう。次点でドライバ(CH9102/CP210x)

## 1. 経路の選択と WiFi 設定

まず **WiFi か USB シリアルか**を決める(両方同時も可):

| 経路 | 向いている環境 | 必要なもの |
| :--- | :--- | :--- |
| WiFi/HTTP | 自宅など、Mac と Atom を同じ LAN に置ける。Atom を USB 電源だけで好きな場所に置きたい | 2.4GHz の SSID/パスワード、ルーターの DHCP 予約 |
| USB シリアル | 来客用 WiFi(端末間通信の遮断)、802.1X の社内 WiFi、DHCP 予約不可など、Mac から Atom に HTTP が届かない | Atom を Mac に USB 直結しておくこと |
| BLE(ブランチ `bluetooth-spp`)| WiFi が使えず、かつ Atom を無線(USB 電源のみ)にしたい | uv(または `pip install bleak`)、初回の macOS Bluetooth 許可、常駐デーモン ble-bridge.py |

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

### 3c. BLE の場合(ブランチ `bluetooth-spp`)

1. `BLE_ENABLED = true` のファームウェアを書き込む(`main` は WiFi + USB のみ)
2. `uv run ble-bridge.py --scan` で Atom(`<== clawd?` 付き)が見えるか確認。見えなければ広告分割か Bluetooth 許可を疑う
3. `uv run ble-bridge.py` で常駐起動 → 初回の許可ダイアログを許可 → ログに `connected`
4. **検証**(ユーザー実行): `ATOM=ble ./led-test.sh status` が `ble=connected` を返し、`ATOM=ble ./led-test.sh send tool default` が 1 秒未満で返ること
5. hook は `~/.claude/led.sh` の `ATOM_BLE="1"`(`ATOM_SERIAL` は空)。led.sh が `uv run --script` でデーモンを自動起動する

### 3a. USB シリアルの場合

1. `ls /dev/cu.usbserial-*` でポートのパスを確認(チップのシリアル番号由来で、抜き差ししても変わらない)
2. `echo "/dev/cu.usbserial-XXXX" > .atom-ip` を作成(gitignore 済み)
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

1. `cp led.sh ~/.claude/led.sh && chmod +x ~/.claude/led.sh` して、冒頭の経路設定を書き換える:
   USB なら `ATOM_SERIAL="/dev/cu.usbserial-XXXX"`、WiFi なら `ATOM_SERIAL=""` のまま `ATOM_URL` を実 IP に
2. `~/.claude/settings.json` の `hooks` に README 記載の 10 イベントをマージする。
   **既存の settings.json を丸ごと上書きしない**こと。既に hooks キーがある場合は中身を統合。
   編集後は JSON の構文検証を行う
3. すべてのイベントで `"async": true` が付いていることを確認(付いていないと Claude Code がブロックされる)
4. `diff led.sh ~/.claude/led.sh` で差分が経路設定の行だけであることを確認

## 5. 最終検証

1. Claude Code を再起動してもらい、`/hooks` で全イベントが読み込まれていることを確認
2. 適当なファイルを読ませて: 白の呼吸(作業中)→ 緑点滅 6 秒(完了)→ 青(idle)と遷移すること
3. 許可のいらないコマンドを何か実行させて権限ダイアログを出し、赤点滅になること
4. 全部通ったら完了。`docs/LIFECYCLE.md` に「Yes 押したのに赤いまま」等の既知挙動が
   あることを一言案内する

## トラブル時

README のトラブルシュート表と `docs/NOTES.md` を参照。デバイスの状態は
`./led-test.sh status` でセッション別に確認できる。
