# Clawd Heartbeat

*[English version](README.md)*

M5Atom Lite の LED 1 粒で Claude Code の実行状態を表示するステータスインジケータ。
ターミナルを見ていなくても「動いている」「承認待ちで止まっている」「終わった」が視界の端でわかる。

**電子工作は不要。** はんだ付けも配線もなし——電子部品は市販の M5Atom Lite(2,000 円以下)を 1 つ買うだけ。書き込んで、ガワに入れれば完成。

![4 つの状態](docs/img/thumbnail.jpg)

```
Claude Code hooks ──HTTP GET(WiFi)──────┐
                    行コマンド(USB)─────┼──> M5Atom Lite ──> FastLED ──> SK6812
                    行コマンド(BLE)─────┘
```

送信経路は 3 つ、1 行プロトコルは共通。**WiFi**: hook が HTTP GET を投げる。Atom と Mac が同じネットワークに
いられるとき向け。**USB シリアル**: hook がシリアルポートに 1 行書く。同じネットワークにいられず
(端末間通信を遮断する来客用 WiFi、802.1X の社内 WiFi、DHCP 予約不可)、Atom を Mac に USB 直結できるとき向け。
**BLE**: Mac 側の常駐デーモンが BLE 接続を保持して 1 行を中継する。WiFi が使えない環境で Atom を
無線(USB 電源のみ)にしたいとき向け。BLE はブランチ `bluetooth-spp` にあり、`main` は WiFi + USB シリアル。

Bluetooth Classic(SPP)を使わない理由: macOS はポートを開いたままでも idle で SPP のリンクを切り、
送信ごとに約 2 秒の再接続待ちが入るため、ステータス表示には使えない。BLE は接続を保持できるので
送信は数十ミリ秒で届く(docs/NOTES.md 参照)。

設計の経緯・不採用案(シリアル直叩きがリセットを起こす理由。USB 経路はこれを回避している、NOTES.md 参照)は [`HANDOFF.md`](docs/HANDOFF.md)、
構築後の運用情報・設計判断ログは [`NOTES.md`](docs/NOTES.md)、
イベントのライフサイクルと LED の対応(「Yes 押したのに赤いまま」の理由など)は
[`LIFECYCLE.md`](docs/LIFECYCLE.md) を参照。

## LED 表示

| 状態 | 見た目 | トリガー(hook) |
| :--- | :--- | :--- |
| `idle` | 青(常灯、1/2 輝度) | SessionStart / SessionEnd |
| `tool` | 白の呼吸(1.5 秒周期)— オレンジのケース越しでは**ピンクに見える** | UserPromptSubmit / PreToolUse / PostToolUse |
| `wait` | 赤の 400ms 点滅 × 30 秒 → 赤の常時点灯(10 分で idle へ) | PermissionRequest / AskUserQuestion の表示(led.sh 内で判定) |
| `done` | 緑の 150ms 点滅 × 6 秒 | Stop |
| `err` | 赤の 120ms 高速点滅 | StopFailure |
| レインボー | 10 秒間の虹色スワール、終了後は元の状態表示に戻る | 前面ボタン(LED 面)の押下 |
| 消灯 | 最後のリクエストから 30 分で自動消灯、次のリクエストで復帰 | — |

![待機・作業中・承認待ち・完了のサイクル](docs/img/demo.gif)

*待機 → 作業中 → **承認待ち** → 作業再開 → 完了(`./led-demo.sh clip` で再生したもの)*

ピンクについて: `tool` は LED を白で点灯していますが、オレンジ PLA は緑を強く吸収するため、ハート窓から出てくる光は赤 + 青 = ピンク〜マゼンタになります。意図した色ではありませんが、可愛いのでそのまま採用しています。フィラメントの色を変えれば見え方も変わります(`led-tuning` スキルで色の再選定ができます)。

**複数セッション対応**: セッション別(最大 8)に状態を保持し、`wait > err > done > tool > idle`
の優先度で集約表示する。どれかのセッションが承認待ちなら他が何をしていても赤点滅。
10 分更新のないセッションは自動失効。

## ハードウェア

- M5Atom Lite(ESP32-PICO-D4)、オンボード SK6812 × 1(GPIO27)
- USB Type-C 常時給電
- 追加部品なし

## セットアップ

### 楽な方法: Claude Code にやらせる

このリポジトリには `CLAUDE.md` とスキル 2 つが同梱されています。clone して中で Claude Code を開き、こう言うだけ:

> **「セットアップして」** — 経路の選択(WiFi / USB シリアル)→ 書き込み → 宛先の確認 → hook 設定を、各ステップ検証しながら対話的に進めます
>
> **「緑がケース越しだと暗い」**(色・明るさの不満なんでも)— `led-tuning` スキルが、あなたのフィラメントでの実測 → 調整 → 書き込みのループを回します

手動でやりたい場合は以下が同じ手順です。

### 1. ビルドと書き込み

要件: [PlatformIO Core CLI](https://platformio.org/)(`brew install platformio`)

```bash
cp include/secrets.h.example include/secrets.h   # WiFi の SSID / パスワードを記入(2.4GHz のみ)。USB シリアルだけで使うなら SSID は空でよい
pio run -t upload
```

書き込みモードに入らないときは、Atom のボタン(LED 面そのもの)を押しながら USB を挿す。

**WiFi 経路**: 初回起動時はシリアルで IP と MAC を確認し、ルーターの DHCP 予約で IP を固定する:

```bash
pio device monitor   # "ready: http://<IP>" と "mac: <MAC>" が出る
```

**USB シリアル経路**: IP は不要。`ls /dev/cu.usbserial-*` でポートを確認し(名前はチップのシリアル番号由来なので抜き差ししても変わらない)、疎通を見る:

```bash
echo /dev/cu.usbserial-XXXXXXXX > .atom-ip   # gitignore 済み。led-test.sh / led-demo.sh が読む
./led-test.sh status                          # state=idle ... が返れば OK
```

WiFi は任意。SSID を空にすると WiFi を一切使わず(起動時の紫も出ない)、SSID があれば両経路が同時に使える。WiFi が切れてもデバイスは再起動しなくなった。

**BLE 経路**(ブランチ `bluetooth-spp`): ファームウェアが BLE ペリフェラルとして広告し、Mac 側の常駐デーモンが接続を保持してコマンドを中継する。[uv](https://docs.astral.sh/uv/)(または `pip install bleak`)と、初回の macOS Bluetooth 使用許可が要る。

```bash
uv run ble-bridge.py            # スキャン→接続→保持。初回の許可ダイアログは許可する
ATOM=ble ./led-test.sh status   # state=... ble=connected が出れば OK
```

hook を BLE にするには `~/.claude/led.sh` 冒頭の `ATOM_BLE="1"`(`ATOM_SERIAL` は空のまま)。SessionStart hook に `led.sh ensure-ble` を足すと、最初のイベントより前にデーモン(と BLE 接続)が立ち上がる。led.sh は必要時に `uv run --script` で自動起動もする(フォールバック):

```json
"SessionStart": [{ "hooks": [
  { "type": "command", "command": "$HOME/.claude/led.sh ensure-ble", "async": true },
  { "type": "command", "command": "$HOME/.claude/led.sh idle", "async": true }
] }]
```

3MB のアプリ領域が前提(`platformio.ini` で設定済み)。

`platform = espressif32@6.9.0` は意図的なバージョン固定。勝手に上げないこと(docs/NOTES.md 参照)。

### 2. hook 設定

リポジトリの [`led.sh`](led.sh) を `~/.claude/led.sh` にコピーし、冒頭で経路を設定する。USB なら `ATOM_SERIAL` にポートのパス、WiFi なら空のままにして `ATOM_URL` に固定 IP:

```bash
cp led.sh ~/.claude/led.sh && chmod +x ~/.claude/led.sh
```

led.sh は単なる送信ラッパーではなく、以下を担っている(詳細は docs/NOTES.md):

- stdin の hook JSON から `session_id` を抽出してセッション別に送信
- AskUserQuestion(選択肢ダイアログ)の表示を wait に変換
- ダイアログ応答待ち中はマーカーファイルを置き、サブエージェント等の
  tool イベントによる赤の上書きを防ぐ(該当呼び出しの完了だけが解除できる)
- ダイアログ表示中はトランスクリプトを監視し、hook に流れない「拒否」「Ctrl+C 中断」を
  検知して数秒で赤を解除する
- 送信時刻(ms)を付与し、async hook の着弾順逆転をデバイス側で排除
- USB ではポートを `-hupcl` で開き、DTR/RTS を動かさない(動くと hook のたびにボードが
  リセットされる。シリアル案が当初不採用だった理由)

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

## FAQ — 既知の挙動(検知済みだが対処不能なもの)

Claude Code の hook はダイアログへの「回答」や「中断」を通知しないため、
以下は仕様として受け入れています。詳しい仕組みは [LIFECYCLE.md](docs/LIFECYCLE.md) 参照。

**Q. 承認(Yes)したのに赤のまま**
承認の瞬間に発火するイベントが存在しません。次の信号は承認したコマンドの
「完了」なので、赤の長さ = そのコマンドの実行時間です。長いビルドを承認すると
実行中ずっと赤です。目安: 点滅の赤 = 未回答の可能性が高い、常灯の赤 = 回答済みで
実行中の可能性が高い(点滅は最初の 30 秒だけ)。

**Q. No で拒否 / Ctrl+C で中断したのに赤のまま**
拒否・中断はどの hook イベントも発火しません(全イベントにロガーを仕込んで実測済み)。
その補完として、led.sh はダイアログ表示中だけセッションのトランスクリプトを監視し、
拒否・中断の痕跡を検知して数秒で赤を解除します(文字列マッチによるベストエフォート)。
取りこぼした場合も、次のプロンプト入力で即復帰、放置でも 10 分で idle に戻ります。

**Q. 終わったはずなのに白の呼吸が続く**
別のセッション(並行して開いている Claude Code)が作業中だとそちらが表示されます。
`./led-test.sh status` でどのセッションが状態を握っているか確認できます。
手動テスト送信の残留の場合は 2 分で自動失効します。

**Q. 何も点いていない**
最後のイベントから 30 分で自動消灯します。故障ではなく、次のイベントで復帰します。

**Q. 起動直後に紫が点いている**
WiFi 接続中の表示です。点きっぱなしの場合は 2.4GHz の SSID か確認してください。

## デバイス API(HTTP / シリアル)

同じ 3 コマンドが両経路で使える。シリアルは 115200bps、1 行 1 コマンド(改行終端)。応答は 1 行(`ok` / `stale` / `unknown state`)、`status` だけは内訳のあとに空行が付く。

| HTTP | シリアル | 説明 |
| :--- | :--- | :--- |
| `GET /led?s=<state>&sid=<id>&ts=<ms>` | `led s=<state> sid=<id> ts=<ms>` | 状態送信。`state` は idle/tool/wait/done/err、`sid` はセッション ID(省略時 default)。`ts` より古い更新は棄却される(省略時は常に適用) |
| `GET /rgb?r=&g=&b=` | `rgb r= g= b=` | 任意色を直接点灯(発光テスト用。次の `led` か 10 分で通常動作に復帰) |
| `GET /` | `status` | 集約状態・セッション数・uptime・RSSI・WiFi 状態(`off` / `connecting` / IP) |

## 発光テスト

```bash
./led-test.sh coupon        # ケース素材の透過テスト(対話式。通常のターミナルで実行)
./led-test.sh states        # 5 状態を順に再生
./led-test.sh rgb 0 255 0   # 任意色を点灯
./led-test.sh ramp 0 255 0  # 指定色を 8 段階で暗→明
./led-test.sh status        # デバイスの状態確認
./led-test.sh off           # idle に戻す
```

撮影や動作確認には `led-demo.sh` を使うと、キー操作なしでアニメーションが自動再生されます(録画を回してから放置できる):

```bash
./led-demo.sh                  # 5 状態を順に再生
./led-demo.sh clip             # 動画/GIF 用の 16 秒シーケンス(撮影が楽)
./led-demo.sh story            # 実運用の流れ: 作業中 → 承認待ち → 承認後 → 完了
./led-demo.sh wait-full        # wait の点滅 → 30 秒で常灯に切り替わるところまで
./led-demo.sh states --solo    # 他セッションを黙らせて確実に再生(撮影向け)
./led-demo.sh states --loop --lead 10   # 繰り返し + 準備時間 10 秒
```

静止画は `led-test.sh rgb R G B`(10 分間色を固定)を使うと、点滅を追いかけずに落ち着いて撮れます。

## トラブルシュート

| 症状 | 対処 |
| :--- | :--- |
| LED が紫のまま | WiFi 未接続。2.4GHz の SSID か確認(5GHz 不可)。紫は 20 秒で諦めて青になる。USB なら最初のコマンドで即終わる |
| WiFi で hook がデバイスに届かない | 来客用・社内 WiFi は端末間通信を遮断していることが多い(クライアント分離)。USB シリアルか BLE 経路に切り替える |
| BLE でデバイスが見つからない | 広告を分割(UUID を広告、名前をスキャン応答)しているか、macOS が Bluetooth 使用を許可しているか確認。`uv run ble-bridge.py --scan` で見えているデバイスを一覧できる |
| hook のたびにデバイスが再起動する(USB) | `-hupcl` なしでポートを開く何か(シリアルモニタ等)が動いている。閉じる。led.sh 自身の送信では DTR/RTS は動かない |
| 書き込みモードに入らない | ボタンを押しながら USB を挿す |
| 承認待ちなのに赤くならない | `/hooks` で PermissionRequest の読み込みを確認 |
| Claude Code が重い | hooks の `async: true`(WiFi なら curl の `-m 1` も)を確認 |
| `pio device monitor` が動かない | TTY 必須のためバックグラウンド実行不可。docs/NOTES.md の pyserial 手順を使う |

## ケース

Clawd 風のピクセルアートなフィギュアで、胸のハート窓はデッドフロント構造(本体と一体で印刷した 0.4mm のオレンジ PLA 薄皮 + LED からの空気層 8〜10mm)。idle の暗い青を含む全色が透けます。目は別印刷(AMS 不要)、お腹と背中は 6mm × 3mm の円形磁石 4 個で固定(ネジ・接着なしで開けられる)、四方の切り欠きで USB-C をどの方向にも逃がせます。STL: [MakerWorld](https://makerworld.com/ja/models/3159586-clawd-heartbeat)。

## ライセンスと免責

コードは [MIT ライセンス](LICENSE)です。本プロジェクトは**非公式のファンプロジェクト**であり、Anthropic とは無関係です(提携・承認・後援を受けていません)。"Claude"、"Claude Code"、Clawd のキャラクターは Anthropic に帰属します。
