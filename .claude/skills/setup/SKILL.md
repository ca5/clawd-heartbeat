---
name: setup
description: >
  Clawd Heartbeat の初期セットアップを対話的に進める。ユーザーが「セットアップして」
  「setup」「初期設定」「導入したい」「動かしたい」と言ったとき、または clone 直後に
  何をすればいいか聞かれたときに使う。WiFi 設定 → ビルド・書き込み → IP 固定 →
  hook 設定 → 動作確認まで、検証を挟みながら一つずつ進める。
---

# Clawd Heartbeat セットアップ手順

各フェーズに検証があります。検証を飛ばして先に進まないこと(失敗箇所の切り分けができなくなる)。
ユーザーの言語(日本語/英語)に合わせて進めてください。

## 0. 前提確認

1. `pio --version` で PlatformIO Core CLI の有無を確認。なければ `brew install platformio`(macOS)等で導入
2. M5Atom Lite を USB 接続し、`ls /dev/tty.usb* /dev/ttyUSB* /dev/ttyACM*` でポートが見えるか確認
   - 見えない場合: 充電専用ケーブルが最頻出の原因。データ対応ケーブル(C to C 推奨)に交換してもらう。次点でドライバ(CH9102/CP210x)

## 1. WiFi 設定

1. `cp include/secrets.h.example include/secrets.h`
2. ユーザーに **2.4GHz の SSID とパスワード**を確認して記入(Atom Lite は 5GHz 非対応)。
   ユーザーが自分で編集したい場合はプレースホルダの場所を案内して待つ
3. secrets.h は gitignore 済みであることを伝える

## 2. ビルドと書き込み

```bash
pio run -t upload
```

- 初回は toolchain のダウンロードで数分かかる(異常ではない)
- `espressif32@6.9.0` の解決に失敗したら**ユーザーに報告**。勝手に最新版へ上げない
- 書き込みモードに入らない場合: Atom のボタン(LED 面)を押しながら USB を挿し直してもらう

**検証**: 書き込み成功後、LED が紫(WiFi 接続中)→ 青(idle)になること。
紫のままなら WiFi 未接続(SSID/パスワード/2.4GHz を再確認)。

## 3. IP の確認と固定

1. シリアルから IP と MAC を読む。`pio device monitor` は TTY 必須で背景実行不可なので、
   非対話シェルでは pyserial を使う(ポートを `dtr=False` `rts=False` で開いてから読む)
2. 表示された IP と MAC を伝え、**ルーターの DHCP 予約で IP を固定**してもらう(ユーザー操作)
3. `echo "http://<IP>" > .atom-ip` を作成(gitignore 済み)
4. **検証**: `./led-test.sh status` が state 等を返すこと

## 4. hook 設定

1. `cp led.sh ~/.claude/led.sh && chmod +x ~/.claude/led.sh` して、中の IP(192.168.1.50 のプレースホルダ)を実 IP に書き換える
2. `~/.claude/settings.json` の `hooks` に README 記載の 10 イベントをマージする。
   **既存の settings.json を丸ごと上書きしない**こと。既に hooks キーがある場合は中身を統合。
   編集後は JSON の構文検証を行う
3. すべてのイベントで `"async": true` が付いていることを確認(付いていないと Claude Code がブロックされる)

## 5. 最終検証

1. Claude Code を再起動してもらい、`/hooks` で全イベントが読み込まれていることを確認
2. 適当なファイルを読ませて: 白の呼吸(作業中)→ 緑点滅 6 秒(完了)→ 青(idle)と遷移すること
3. 許可のいらないコマンドを何か実行させて権限ダイアログを出し、赤点滅になること
4. 全部通ったら完了。`docs/LIFECYCLE.md` に「Yes 押したのに赤いまま」等の既知挙動が
   あることを一言案内する

## トラブル時

README のトラブルシュート表と `docs/NOTES.md` を参照。デバイスの状態は
`./led-test.sh status` でセッション別に確認できる。
