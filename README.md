# atom-led

M5Atom Lite の LED 1 粒で Claude Code の実行状態を表示するステータスインジケータ。
ターミナルを見ていなくても「動いている」「承認待ちで止まっている」「終わった」が視界の端でわかる。

```
Claude Code hooks ──HTTP GET──> M5Atom Lite (WebServer:80) ──> FastLED ──> SK6812
```

設計の経緯・不採用案(シリアル直叩き等)は [`HANDOFF.md`](HANDOFF.md)、
構築後の運用情報・設計判断ログは [`NOTES.md`](NOTES.md) を参照。

## LED 表示

| 状態 | 見た目 | トリガー(hook) |
| :--- | :--- | :--- |
| `idle` | 青(常灯、1/2 輝度) | SessionStart / SessionEnd |
| `tool` | 白の呼吸(1.5 秒周期) | UserPromptSubmit / PreToolUse / PostToolUse |
| `wait` | 赤の 400ms 点滅 × 30 秒 → 赤の常時点灯(10 分で idle へ) | PermissionRequest / AskUserQuestion の表示(led.sh 内で判定) |
| `done` | 緑の 150ms 点滅 × 6 秒 | Stop |
| `err` | 赤の 120ms 高速点滅 | StopFailure |
| 消灯 | 最後のリクエストから 30 分で自動消灯、次のリクエストで復帰 | — |

**複数セッション対応**: セッション別(最大 8)に状態を保持し、`wait > err > done > tool > idle`
の優先度で集約表示する。どれかのセッションが承認待ちなら他が何をしていても赤点滅。
10 分更新のないセッションは自動失効。

## ハードウェア

- M5Atom Lite(ESP32-PICO-D4)、オンボード SK6812 × 1(GPIO27)
- USB Type-C 常時給電(L 字アダプタで直立)
- 追加部品なし

## セットアップ

### 1. ビルドと書き込み

要件: [PlatformIO Core CLI](https://platformio.org/)(`brew install platformio`)

```bash
cp include/secrets.h.example include/secrets.h   # WiFi の SSID / パスワードを記入(2.4GHz のみ)
pio run -t upload
```

書き込みモードに入らないときは、Atom のボタン(LED 面そのもの)を押しながら USB を挿す。

初回起動時はシリアルで IP と MAC を確認し、ルーターの DHCP 予約で IP を固定する:

```bash
pio device monitor   # "ready: http://<IP>" と "mac: <MAC>" が出る
```

`platform = espressif32@6.9.0` は意図的なバージョン固定。勝手に上げないこと(NOTES.md 参照)。

### 2. hook 設定

リポジトリの [`led.sh`](led.sh) を `~/.claude/led.sh` にコピーし、中の IP を自分の環境に合わせる:

```bash
cp led.sh ~/.claude/led.sh && chmod +x ~/.claude/led.sh
```

led.sh は単なる curl ラッパーではなく、以下を担っている(詳細は NOTES.md):

- stdin の hook JSON から `session_id` を抽出してセッション別に送信
- AskUserQuestion(選択肢ダイアログ)の表示を wait に変換
- ダイアログ応答待ち中はマーカーファイルを置き、サブエージェント等の
  tool イベントによる赤の上書きを防ぐ(該当呼び出しの完了だけが解除できる)
- 送信時刻(ms)を付与し、async hook の着弾順逆転をデバイス側で排除

`~/.claude/settings.json` の `hooks` に以下をマージ(全イベント `"async": true` 必須):

```json
{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/led.sh idle", "async": true }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/led.sh tool", "async": true }] }],
    "PreToolUse":        [{ "matcher": "*", "hooks": [{ "type": "command", "command": "$HOME/.claude/led.sh tool", "async": true }] }],
    "PostToolUse":       [{ "matcher": "*", "hooks": [{ "type": "command", "command": "$HOME/.claude/led.sh tool", "async": true }] }],
    "PostToolUseFailure": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "$HOME/.claude/led.sh tool", "async": true }] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "$HOME/.claude/led.sh wait", "async": true }] }],
    "PermissionDenied":  [{ "matcher": "*", "hooks": [{ "type": "command", "command": "$HOME/.claude/led.sh idle", "async": true }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/led.sh done", "async": true }] }],
    "StopFailure":       [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/led.sh err", "async": true }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "$HOME/.claude/led.sh idle", "async": true }] }]
  }
}
```

Claude Code を再起動し、`/hooks` で読み込みを確認。

## HTTP API

| エンドポイント | 説明 |
| :--- | :--- |
| `GET /led?s=<state>&sid=<id>&ts=<ms>` | 状態送信。`state` は idle/tool/wait/done/err、`sid` はセッション ID(省略時 default)。`ts` より古い更新は棄却される(省略時は常に適用) |
| `GET /rgb?r=&g=&b=` | 任意色を直接点灯(発光テスト用。次の `/led` か 10 分で通常動作に復帰) |
| `GET /` | 集約状態・セッション数・uptime・RSSI |

## 発光テスト

```bash
./led-test.sh coupon        # ケース素材の透過テスト(対話式。通常のターミナルで実行)
./led-test.sh states        # 5 状態を順に再生
./led-test.sh rgb 0 255 0   # 任意色を点灯
./led-test.sh ramp 0 255 0  # 指定色を 8 段階で暗→明
./led-test.sh status        # デバイスの状態確認
./led-test.sh off           # idle に戻す
```

## トラブルシュート

| 症状 | 対処 |
| :--- | :--- |
| LED が紫のまま | WiFi 未接続。2.4GHz の SSID か確認(5GHz 不可) |
| 書き込みモードに入らない | ボタンを押しながら USB を挿す |
| 承認待ちなのに赤くならない | `/hooks` で PermissionRequest の読み込みを確認 |
| Claude Code が重い | hooks の `async: true` と curl の `-m 1` を確認 |
| `pio device monitor` が動かない | TTY 必須のためバックグラウンド実行不可。NOTES.md の pyserial 手順を使う |
