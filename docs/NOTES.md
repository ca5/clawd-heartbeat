# NOTES — 運用情報と設計判断ログ

このファイルは引き継ぎ用。使い方・セットアップは [README.md](../README.md)、
初期構築前の設計経緯は [HANDOFF.md](HANDOFF.md) を参照。

## 稼働情報(この個体)

個体固有の値(IP・MAC・シリアルポート)は `LOCAL.md`(gitignore 済み)に記載。

- 送信経路: WiFi/HTTP か USB シリアルのどちらか(後述の設計判断ログ 2026-09-03 参照)
- デバイス IP(WiFi 経路): ルーターで DHCP 予約して固定する(例: `http://192.168.1.50`)
- シリアルポート(USB 経路): `ls /dev/cu.usbserial-*`。チップのシリアル番号由来なので抜き差しで変わらない
- WiFi 認証情報: `include/secrets.h`(gitignore 済み)。USB 経路だけなら SSID は空でよい
- テストスクリプトの宛先: `.atom-ip`(gitignore 済み)に URL かポートのパスを書くか、環境変数 `ATOM` で指定

## 設計判断ログ

### 承認待ち検知は `Notification` ではなく `PermissionRequest`(2026-08-06)

引き継ぎ資料の指定は `Notification`(matcher: `permission_prompt`)だったが、
実測で「ユーザーがしばらく操作していないときしか発火しない」ことが判明。
`Notification` は通知送信後に発火する副作用イベントで即時性がない。
`PermissionRequest`(matcher: `*`)は agentic loop の同期フロー
(PreToolUse → PermissionRequest → ツール実行)に組み込まれており、
権限確認の瞬間に確実に発火する。

### `PostToolUse` → tool を追加(2026-08-06)

引き継ぎ資料は PostToolUse を意図的に不使用としていたが、それは「ツール完了後も
tool 表示のままが正しいから不要」という理由。承認後に長時間コマンドが走ると
wait の赤が張り付く問題への復帰用途は想定外だったため、追加しても設計意図と矛盾しない。

### LED 表示のチューニング経緯(2026-08-06〜08)

- tool: 黄 250ms 点滅 → 目に痛い → オレンジ 750ms 点滅 → ふわっとさせたい →
  オレンジの呼吸 → オレンジケース越しだと wait の赤と区別不能 → 白の呼吸 →
  紫を試す → 「ラブホみたい」で NG → **白の呼吸で最終確定**
- オレンジを LED で出すときは緑成分をかなり絞る必要がある(CRGB(255,96,0) でも黄色に見える。40 で OK)
- wait: 赤の呼吸 → 目立たせるため **400ms 点滅**に(err の 120ms と速度で区別)
  → さらに二段階化(2026-08-09): **点滅は最初の 30 秒(WAIT_BLINK_MS)だけ、以降は赤の常時点灯**。
  点滅しっぱなしはうるさい一方、常灯が残ることで離席から戻ったときに承認待ちに気づける。
  切替の基準はセッションの wait 開始時刻(waitSince)なので複数セッションでも正しく動く
- done: 緑常灯 3 秒 → 6 秒 → **150ms 点滅 × 6 秒**
- tool / wait はピーク輝度 170 に減光(255 は明るすぎ)。done / err はフル輝度のまま
- idle: 明度 12 の「ごく暗い青」 → ケース越しの視認用に **170(フルの 2/3)** に増光(2026-08-08)
- 白と青の役割を一度反転 → 再反転して元に戻した(2026-08-09)。最終形: **tool = 白の呼吸(ピーク 255)、idle = 青の常灯(128 = 1/2)**
- **オレンジケース越しでは白がピンク〜マゼンタに見える**(2026-08-11、完成品の写真で確認)。
  オレンジの顔料が緑を最も強く吸収するため、白(R+G+B)から緑が抜けて R+B = ピンクになる。
  意図した色ではないが「光るハート」としては可愛いのでそのまま採用し、ドキュメントに補足を入れた。
  同様に idle の青も紫寄りに見える。フィラメントを変えると見え方が変わるので、
  配布先には led-tuning スキルで再調整してもらう前提
- BRIGHTNESS はケース(拡散シェード)前提で 255。裸運用なら 30〜50 に戻す

### 複数セッション対応(2026-08-08)

複数の Claude Code セッションが並行すると状態を上書きし合うため、
ファームウェアでセッション別(最大 8、10 分無更新で失効)に状態を保持し、
`wait > err > done > tool > idle` の優先度で集約表示。
done はセッション単位で 6 秒後に失効するので、他セッション作業中でも完了フラッシュは見える。
`led.sh` が hook の stdin JSON から `session_id` を抽出して `&sid=` で送る。
手動実行(tty)時は `sid=default` になり、実セッションの表示を専有しない。
連打時の取りこぼし対策で curl に `--retry 2 --retry-all-errors` を追加。

### 中断・拒否時の赤張り付き: hook では検知不可能と結論(2026-08-09)

権限ダイアログを No で拒否 / Ctrl+C で中断しても、**どの hook イベントも発火しない**
(v2.1.226 で実測確定)。全 15 イベント(PermissionDenied / PostToolUseFailure /
PostToolBatch / MessageDisplay / Stop / Notification 等)にロガーを仕込んでテストし、
ダイアログ表示の PermissionRequest 以降は完全に無音だった。
`PermissionDenied` はドキュメントどおり「auto mode classifier による拒否」専用で、
手動拒否では発火しない(設定には残してあるが実質未使用)。
`Stop` は正常完了時のみで、中断時は発火しない。

**現状の挙動(仕様として受容)**: 拒否・中断後の赤は
(1) 次のプロンプト入力(UserPromptSubmit → tool)で即解除、
(2) 何もしなければ 10 分のセッション失効(STALE_MS)で idle に落ちる。
wait 専用の短い失効は「離席中の本物の承認待ちが消えてしまう」ため意図的に入れていない。

**再調査するときのデバッグ手法**: stdin の JSON をログに落とすだけのスクリプト
(`date; cat >> ~/.claude/led-events.log`)を全イベントに `async: true` で仕込むと、
何がいつ発火するか確実に観測できる。

### 選択肢ダイアログ(AskUserQuestion)も wait 扱い(2026-08-09)

AskUserQuestion に専用イベントはないが、ツール呼び出しなので PreToolUse が発火する。
`led.sh` 側で「PreToolUse かつ tool_name = AskUserQuestion」なら tool の代わりに wait を送る。
回答すると PostToolUse → tool で自動解除。settings.json の変更は不要(matcher で分けると
`*` と二重マッチして tool/wait が競合するため、led.sh 内で判定するのが正解)。
led.sh は毎回実行されるので変更は再起動不要で即反映される。

### 着弾順逆転の排除: 送信タイムスタンプ(2026-08-09)

権限ダイアログでは PreToolUse(tool)と PermissionRequest(wait)が async でほぼ同時に走り、
curl のリトライも絡むと着弾順が逆転して「ダイアログ表示中なのに白」になることがある
(「同じコマンド連続で赤にならない」として発覚)。
対策: led.sh が送信時刻(ms、perl Time::HiRes)を `&ts=` で付け、
ファームウェアはセッションごとに最後に適用した ts を記憶して**古い ts の更新を棄却**(`stale` 応答)。
ts なし(手動 curl)は常に適用。検証は `./led-test.sh send <state> <sid> <ts>` で
wait(ts大)→ tool(ts小)を送り、state=wait が維持されることを確認。

### サブエージェント・連続 Permission による白上書きの根治(2026-08-09)

実測でわかった事実:
- **サブエージェントのツールイベントは親と同じ session_id で発火する**。メインが
  ダイアログ待ちでも、裏のサブエージェントが tool を送り続けて赤を上書きしていた
- **PermissionRequest の hook JSON には tool_use_id が無い**(v2.1.207 / v2.1.226 で生 JSON を
  3 回観測して確定。実フィールドは session_id / transcript_path / cwd / prompt_id /
  permission_mode / effort / hook_event_name / tool_name / tool_input / permission_suggestions)。
  なお公式ドキュメントは PermissionRequest の入力フィールドを明示しておらず
  「tool_use_id は event-specific」とだけ記載(具体例は PreToolUse のもの)。
  つまり「ドキュメントと矛盾」ではなく「ドキュメントが書いていない部分の実測」。
  tool_use_id は直前(同秒)の PreToolUse には有る
- **割り込みメッセージ(Ctrl+C 後の入力)では UserPromptSubmit が発火しない**ことがある

対策(led.sh 内、実物は repo の `led.sh` を参照):
- PreToolUse ごとに「直近の呼び出し(tool_use_id + tool 名)」を pending ファイルに記録
- ダイアログ表示(PermissionRequest / AskUserQuestion)で marker ファイルを作成。
  PermissionRequest は pending から tool_use_id を補完(tool 名一致を確認)
- marker 存在中の tool イベントは wait に変換(赤を維持)。解除は
  (1) marker と同じ tool_use_id の PostToolUse / PostToolUseFailure、
  (2) UserPromptSubmit、(3) done / err / idle、(4) marker の TTL 10 分
- settings.json に PostToolUseFailure → tool を追加(失敗完了でも解除できるように)

検証: `led-test.sh send` 相当の偽 JSON を led.sh に流し、/ のセッション別内訳
(この対応と同時にファームウェアへ追加)で「ダイアログ中の別イベントで wait 維持 →
該当呼び出しの完了で tool 復帰」を確認済み。

### 手動送信(sid=default)の失効を 2 分に短縮(2026-08-09)

led.sh / led-test.sh をターミナルから手で叩くと `default` セッションとして記録されるが、
10 分間 tool 等に残留して「ターン完了後も白い呼吸が続く(緑→idle に見えない)」事故が起きた。
default だけ失効を DEFAULT_STALE_MS(2 分)に短縮。テスト後は `./led-test.sh off` で
明示的に idle に戻すのが行儀としては正しい。

### 拒否・中断をトランスクリプト監視で検知(2026-08-14)

「No / Ctrl+C はどの hook でも検知不可能」の結論は hook の世界では今も正しいが、
[claude-session-browser](https://github.com/juppeee/claude-session-browser) が
トランスクリプト(JSONL)を tail して状態推測しているのを見て、盲点の補完に採用した。

- 拒否 → `"content": "The user doesn't want to proceed with this tool use..."` の
  tool_result、中断 → `"text": "[Request interrupted by user]"` が**即座に**記録される
  (実セッションのトランスクリプトから実測)
- led.sh がダイアログのマーカー作成時に短命の監視プロセスを spawn し、
  hook JSON の transcript_path の追記分を 1 秒間隔で監視。検知したら marker 削除 + idle 送信
- **構造的マッチ**が重要: 会話文中で同じ文字列を引用すると JSON 内では `\"` に
  エスケープされるため、`"content": "The user...` のようにフィールド構造ごと
  マッチすれば誤発火しない(偽陽性テスト済み)
- 監視はマーカー消失(通常経路で解決)か 10 分(マーカー TTL と同じ)で自然終了。
  常駐デーモンなし
- 文字列は Claude Code のバージョンで変わり得るベストエフォート。取りこぼしても
  従来の保険(次プロンプト / 10 分 TTL)がそのまま効く

なお同ツールの「トランスクリプトだけで全状態を推測」への全面移行はしない。
permission prompt はトランスクリプトに記録されず(同ツールの README にも明記)、
承認待ちの検知は hooks(PermissionRequest)の方が確実なため。hooks 主 + 監視補完。

### USB シリアル経路の追加(2026-09-03)

HANDOFF.md で「シリアル直叩きは hook のたびにボードがリセットされるので不採用」と結論していたが、
オフィス環境で WiFi 経路が成立しないケースが出たため、リセットを回避する形でシリアルを **第 2 の経路**として追加した。
WiFi 経路は従来どおり残す(ファームウェアもスクリプトも両対応)。

WiFi が成立しなかった状況(実測):
- Atom は来客用 2.4GHz WiFi に接続できる(LED 青)が、来客用 WiFi は**端末間通信を遮断**している。
  Mac を同じ来客用 WiFi(同一 /22 サブネット)に入れても、ゲートウェイへの ARP は解決するのに
  Atom への ARP が `incomplete` のまま → 典型的なクライアント分離
- 社内 WiFi は 802.1X 想定でファームウェア非対応、DHCP 予約も利用者にはできない
- 結論: hook(Mac)→ Atom の到達経路が LAN 上に存在しない。USB は常時つながっているのでこれを使う

リセット問題の正体と対策:
- Atom Lite の USB-UART(CH9102F)は DTR/RTS が EN/IO0 の自動リセット回路に配線されている。
  ホストがポートを close すると termios の `hupcl` により DTR/RTS が落ち、その落ち方の順序次第で
  EN が一瞬 Low になって再起動する。open 時は両方同時にアサートされるので起きない(pyserial の
  既定 open でリセットしなかったことで確認)
- 対策は「**信号を常時アサートで固定する**」こと: 送信のたびに `stty raw -echo -hupcl clocal 115200 <&3`
  を掛けてから書き、close で信号を落とさせない。実測: 15 回連続送信で uptime が単調増加(再起動なし)
- 唯一起きるのは**プラグ直後・書き込み直後の初回 open**で信号線が初期化されるときの 1 回。
  セッション状態は消えるが、次の hook イベントで復帰するので許容。書き込み直後の初回 `status` が
  空応答になるのはこれ
- `tty.*` ではなく `cu.*` を使う(tty.* はキャリア待ちで open が固まることがある)
- 常駐デーモン(ポートを開いたまま Unix socket で中継)も検討したが、-hupcl だけで足りたので不採用。
  もし将来 -hupcl が効かないドライバに当たったら、led.sh がポートを開いたまま寝るだけの保持プロセスを
  遅延起動する方式が次の手

プロトコル: HTTP のクエリを `key=value` の空白区切りにしただけ(`led s=tool sid=x ts=123` / `rgb r= g= b=` / `status`)。
ファームウェア側は `applyLed` / `applyRgb` / `statusBody` を HTTP ハンドラとシリアル行パーサで共用。
複数 hook プロセスが同時に書くと行が混線する可能性はあるが、1 行 100 バイト未満の単発 write なので
実用上は起きにくく、起きても `unknown ...` で捨てて次のイベントで直る設計(1 イベントの取りこぼしは許容)。

WiFi を任意に: SSID が空なら `WIFI_OFF` でシリアル専用。SSID があっても接続はブロッキングせず裏で行い、
20 秒で繋がらなくても**再起動しない**(以前は `ESP.restart()` していたが、シリアル運用でセッション状態が消える)。
起動時の紫は「WiFi 設定あり・未接続・コマンド未受信・起動 20 秒以内」のときだけ。
`status` に `wifi=` 行(`off` / `connecting` / IP)を追加したため、led-demo.sh の内訳パースは
行番号依存(`NR>4`)からインデント判定(`/^  /`)に変更した。

セットアップ時の落とし穴: Claude Code の Bash サンドボックスからは `/dev/cu.*` を開けず、
`~/.platformio` にも書けない。書き込みとシリアル確認はユーザーに `!` プレフィックスで実行してもらう。

### BLE 経路の追加、Bluetooth Classic SPP は不採用(2026-09-04)

USB が届く範囲に縛られない無線経路が欲しくなり、まず Bluetooth Classic SPP を試したが**不採用**。
macOS は SPP の RFCOMM リンクを、ポートを開いたままでも idle で切る。開くたびに約 2 秒の再接続待ちが入り、
接続前に閉じたデータは消える。ポートを保持する中継プロセスも、macOS が「開いているのに未接続」で固まらせるため
成立しなかった(実測を repo 履歴とデーモンの試作に残した)。

代わりに **BLE** を採用(ブランチ `bluetooth-spp`)。ファームウェアは BLE ペリフェラル
(Nordic UART 互換 UUID `6e400001-…`、RX=write / TX=read+notify)。Mac 側は常駐デーモン
`ble-bridge.py`(bleak)が BLE 接続を張りっぱなしにし、Unix ソケットで受けた 1 行を RX へ write する。
BLE はアイドルでも接続を維持できるので、送信は実測 40ms 前後(SPP の 2 秒に対して)。

踏んだ罠:
- **広告 31 バイト上限**: 128bit UUID(18B)と名前(17B)を両方メイン広告に載せると溢れ、広告設定ごと
  失敗して macOS から一切見えなくなる。UUID をメイン広告(`setAdvertisementData`)、名前をスキャン応答
  (`setScanResponseData`)に分けると両方見える。`--scan` で確認できるようにした
- **名前検索は不安定**: macOS は広告に名前を載せないことがあるので、デーモンはサービス UUID で照合し、
  名前はフォールバック
- **WiFi 共存**: `WiFi.setSleep(true)` が必須(false のままだと無線コントローラ有効化で abort し起動ループ)。
  WiFi 未接続時のスキャン連打も BLE の広告を痩せさせるので、自動再接続を切って間欠試行にした(SPP 時と同じ対策)
- **書き込みは BLE タスクで走る**ため、受信は SPSC リングに積んで実処理は loop() でやる(sessions[]/FastLED を
  1 スレッドに寄せる)。応答は TX 特性に載せ、status は read で取れる(1 秒ごとに TX を更新)

led.sh は `ATOM_BLE=1` でこの経路を選び、`uv run --script ble-bridge.py` でデーモンを自動起動する
(初回のみ macOS の Bluetooth 使用許可が要る)。デバイス再起動時はデーモンの keepalive が 5 秒間隔で張り直す。

### 端末の役割分担: 焼く端末とつなぐ端末(2026-09-09)

混同しやすいので明記する。**ファームウェアはどこか 1 台で焼けば済む**。デバイスに書き込まれた
あとは、LED をつなぐ端末が何台増えても再ビルドは要らない。

- **焼く端末**: PlatformIO + ツールチェーンが必要。TLS 検査下では初回取得に CA の対処が要る(後述)
- **つなぐ端末**: `led.sh` / `~/.claude/led.conf` / ブリッジスクリプト(`hid-bridge.py` か
  `ble-bridge.py`)/ uv(または pip)だけ。**PlatformIO は不要なので CA の問題も踏まない**

実例として、HOGP 対応の書き込みは Windows から行い、Mac は書き込まずに BLE でつないだ
(それまでの書き込みは Mac から行っていた)。どちらの端末が焼いてもよい。
2 台目以降を足す作業は README の「2. hook 設定」から始められる。

### HOGP(BLE HID)経路の追加(2026-09-09)

管理 Windows 端末の MDM が `Bluetooth/ServicesAllowedList` で SIG 標準 UUID しか許可せず、
NUS のカスタム UUID では GATT が `AccessDenied` になる(前節の「未解決」)。許可リストを実際に
読むと **0x1812(HID over GATT)、0x180A、0x1813 が載っていた**ので、そこにコマンドチャネルを
移して回避した。NUS は残したまま**同じ GATT サーバーに HID サービスを併設**する。

キーボードとしては振る舞わない。report map を**ベンダー定義 usage page(0xFF00)**の
Output / Input Report にしてある:

- キーボードの usage を含まないので、誤ってキー入力が飛ぶ事故が原理的に起きない
- OS はキーボード/マウスのコレクションをユーザー空間から開かせない(キーロガー対策)が、
  ベンダー定義は開ける。この端末で既存のベンダーコレクション 6 個が管理者権限なしで
  open できることを先に実測してから設計した
- Output Report(host→Atom, 64B)= コマンド 1 行を NUL 埋め。`getValue().c_str()` が NUL で
  切れる性質を使って 1 write = 1 行として扱い、NUS と同じ SPSC リングに積む
- Input Report(Atom→host, 512B)= 本文を NUL 終端で丸ごと。**ホストは notify ではなく
  GATT read**(Windows は `HidD_GetInputReport`)で取る。Output は 64B のまま(コマンドは短く、
  無駄に長いと BLE の long write になる)。Report Count が 256 以上なので `0x95` の 1 バイト形式では
  表現できず `0x96` の 2 バイト形式を使う

**当初 notify + 分割送出にして失敗した**。`[len][payload]` を複数レポートに分けて notify する
設計だったが、2 つの理由で破綻した:

1. **read で取れるのは「最後に setValue した値」だけ**。分割すると終端レポート(`len=0`)しか
   読めない。実測で `get_input_report` が 65B 返すのに中身が全ゼロで気づいた
2. **notify の購読は BLE リンクが張り直されると黙って失われる**。しばらく動いていた `status` が
   ある時点から `error: no response` になり、`connection_status=1`(CONNECTED)・広告も正常・
   書き込みも届く(LED は変化する)のに応答だけ来ない状態になった

教訓: **HOGP で host ← device の応答を取るなら read を正とする**。notify は購読状態に依存し、
その状態を host 側から確認する手段が無い。read なら購読と無関係に必ず取れる。
分割をやめたことでファームウェアもブリッジも短くなった

**リンクの維持は OS がやってくれる(2026-09-10、一度誤診してから訂正)**。当初
「入力トラフィックの無いベンダー定義 HID は Windows がアイドルで切る」と結論し、
`maintain_connection` の `GattSession` を掴み続ける対策を入れたが、**これは誤診だった**。
根拠にしていた「セッションを離すと即 DISCONNECTED」「リンクが上がらない」という観測は、
すべて後述のボンド不一致が起きている最中のもので、Windows が接続 → 暗号化失敗 → 切断を
繰り返していただけだった。ボンドを直したあとに検証すると、**セッションを一切掴まなくても
リンクは UP のまま、HID コレクションも見えたまま**だった。

`GattSession` を掴む処理は残してあるが、役割は「落ちているリンクを能動的に上げる」ことと、
後述の自動復旧の判定材料であって、「切られるのを防ぐ」ためではない。

**Atom の再起動でボンドが食い違う**。症状は特徴的で、**2 秒ごとに接続と切断を繰り返す**
(`link=UP` → 2 秒後 `link=down` を延々。60 秒で 4 往復を実測)。Windows が保存した LTK を
Atom 側が知らず、接続直後の暗号化に失敗して切られる。`maintain_connection` を立てていても
無関係に切れるので、セッションの問題と紛らわしい。復旧はペアリングのやり直しで、
`uv run hid-bridge.py --repair` を用意した(unpair → CONFIRM_ONLY の Just Works で再ペアリング。
IO が無いので UI 操作なしに完了する)。

**原因は `setRespEncryptionKey` の欠落だった(修正済み)**。当初「Atom が電源断でボンドを失う」と
考えたが、`status` に `bonds=`(`esp_ble_get_bond_device_num()`)を足して観測したところ、
**ボンドの件数は再起動をまたいで残っていた**(書き込み直後でも `bonds=2`)。永続化は元から
効いていて、問題は保存された鍵がホスト側と一致しないことだった。

`BLESecurity` が `setInitEncryptionKey` だけを設定していたのが原因。BLE では init_key が
「セントラルが配る鍵」、rsp_key が「ペリフェラルが配る鍵」で、こちらはペリフェラルなので
rsp_key を設定しないと自分の鍵を配布できない。ボンドの器はあるのに中身が食い違う状態になる。
`setRespEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK)` を足したところ、
**リセット後に再ペアリング無しでそのまま復帰する**ことを実測で確認した。

「件数が残る」と「鍵が一致する」は別物で、前者だけ見て永続化が効いていると判断すると
見誤る。`bonds=` を status に残してあるのは、次に同種の疑いが出たときに切り分けるため。

保険として **hid-bridge.py が自動で復旧する**: セッションを
掴んでもデバイスが出てこなければボンド不一致とみなして再ペアリングする(5 分のクールダウン付き。
正常時に誤発火しないことを確認済み)。

ついでに見つかった 2 件(どちらも hook の実害あり):

- **`2>/dev/null` を `3<>` より前に置く規則を TCP 側に適用し忘れていた**。デーモンが落ちていると
  `led.sh: connect: Connection refused` が hook の stderr に漏れる。シリアル側では既に守っていた
  規則で、CLAUDE.md にも書いてあったのに TCP の 6 箇所で抜けていた
- **自動起動したデーモンが hook の stdout/stderr パイプを掴んだままになる**。リダイレクトを
  デーモンのコマンドにだけ掛けていたため、サブシェルは親の fd を保持し続け、hook の出力を
  読む側が EOF を待って固まる(実測で 300 秒たっても終わらなかった)。リダイレクトは
  `( ... ) </dev/null >>log 2>&1 &` のようにサブシェル自体に掛ける

実測結果:

| 項目 | 結果 |
| :--- | :--- |
| GATT のアクセス | 通る(0x1812 は許可リストにある) |
| ユーザー空間からの open | 成功。`3a30:7180 up=0xFF00 clawd-heartbeat`。ドライバ・管理者権限不要 |
| NUS との同時接続 | 成功。`ble=connected n=2`(Mac の NUS + Windows の HOGP) |
| hook のレイテンシ | **0.19〜0.22 秒/イベント**。USB シリアル(0.40 秒)より速い。ポートの open/close が無いため |
| 完全ワイヤレス | 成功。USB を抜いた状態で動作 |

「HOGP にすると同時 3 接続が後退する」という懸念は、NUS を置き換えず併設したことで回避できた
(上限 3 に対して 2 使用)。HID の characteristic だけが `ESP_GATT_PERM_*_ENCRYPTED` なので、
HID を触るホストだけがペアリングを要求され、Mac は平文の NUS を使い続けられる。

踏んだ罠:

- **`BLEHIDDevice::manufacturer(std::string)` は未初期化ポインタを触る**。コンストラクタは
  `m_manufacturerCharacteristic` を作らず、引数なしの `manufacturer()` が生成側。そのまま呼ぶと
  `LoadProhibited` でブートループする(実測。`addr2line` で BLEHIDDevice.cpp:90 と判明)。
  `manufacturer()->setValue(...)` が正しい。`pnp()` / `hidInfo()` / `reportMap()` は
  コンストラクタで作られた characteristic を使うので直接呼んでよい
- **広告は 29/31 バイト**(flags 3 + HID 16bit 4 + Appearance 4 + NUS 128bit 18)。
  `addData` は上限超過分を黙って捨てるので、HID 側を先に積んで、溢れたときに落ちるのを
  NUS の UUID 側にしてある(NUS が落ちても ble-bridge.py は名前で見つけられる)
- **PnP ID のバイト順**: ライブラリが vid/pid をビッグエンディアンで書くため、
  `pnp(0x02, 0x303A, 0x8071, ...)` はホストから `3a30:7180` と見える。表示上の問題だけで、
  hid-bridge.py は usage page と product string で照合しているので動作に影響はない
- **led.sh がデーモンのエラーを見ていなかった**。`sock_write` は応答を 1 行読むだけで内容を
  見ておらず、デーモンが `error: ...` を返しても成功扱いになり、USB シリアルへのフォールバックが
  働かなかった。`error:` で始まる応答は失敗として扱うように修正(応答なし=タイムアウトは
  投げっぱなしとして成功のまま)
- **ブートループ中は診断ツールが固まる**。パニックしたデバイスは起動ログを延々流すので、
  `led-test.sh status` の `while read -t 3` が終わらず COM ポートを掴んだまま固まった。
  読み取り行数に上限を入れて修正済み(led-test.sh / led-demo.sh / led.sh の serial_is_atom)

この端末では他に 2 つ、企業環境固有の壁があった(いずれも Mac には無い):

- **TLS 検査**: 社内ルート CA が Windows 証明書ストアにはあるが `requests` の certifi には無く、
  `pio` のパッケージ取得が `HTTPClientError`(実体は `CERTIFICATE_VERIFY_FAILED`)になる。
  Windows のルート CA を PEM に書き出して certifi と結合し `REQUESTS_CA_BUNDLE` で渡すと通る。
  **必要なのは初回のパッケージ取得だけ**で、導入後の通常ビルドは CA 無しで通る(実測 7.7 秒で成功)。
  再度必要になるのは platform のバージョン変更・`~/.platformio` の削除・`lib_deps` の追加など、
  再取得が走るとき。`uv` は rustls で OS の証明書ストアを見るため影響を受けない
  (hidapi / bleak / pyserial はいずれも素で取得できた)
- **DLP(Purview Information Protection)**: `~/.platformio` 配下の `.csv` が `.pfile` に暗号化
  ラップされ、パーティション生成が `UnicodeDecodeError` で落ちる(20 個全滅)。書き直しても
  数秒で再暗号化される。正本をリポジトリ外に置いて `-c` で別 ini から指す形で回避した
  (`.h` / `.cpp` は無傷、スクラッチパッドとリポジトリ内の `.csv` は保護されない)

### Windows 対応(2026-09-07)

Windows でも BLE 経路を動かせるようにした。bleak の WinRT バックエンドは Windows でそのまま動くので、
詰まったのは BLE 本体ではなく周辺の 3 点だった。

- **Unix ソケットが無い**: Windows の CPython には `socket.AF_UNIX` も `asyncio.start_unix_server` も
  無いため、デーモンは起動直後に `AttributeError` で落ちる(依存の `uv sync` は通るので「インストール失敗」に見える)。
  `--port` を足し、Unix ソケットが使えない環境では自動で `127.0.0.1:47820` の loopback TCP に落とすようにした。
  シェル側(`led.sh` / `atom-antigravity.sh` / `led-test.sh` / `led-demo.sh`)は bash の `/dev/tcp` で書く。
  `nc -U` も python も要らない。`exec 3<>` ではなく subshell + リダイレクトにしてあるのは、接続失敗時に
  `exec` が非対話シェルごと終了させてしまうため
- **CRLF**: `core.autocrlf=true` の Windows で clone すると `.sh` が CRLF になり、shebang 末尾の `\r` で
  `bad interpreter` になる。`.gitattributes` で `*.sh` / `*.py` を `eol=lf` に固定した
- **GATT のキャッシュ**: Windows は探索結果をキャッシュするので、write に一度失敗して張り直すと
  「特性が見つからない」に化ける。Windows のときだけ `winrt={"use_cached_services": False}` を渡す

USB シリアル経路でも Windows 固有の罠が 4 つあった(いずれも実機 COM3 で確認):

- **`stat` の BSD/GNU 差異**: `stat -f %m ... || stat -c %Y ...` の順序が逆だった。GNU では `-f` が
  「ファイルシステム情報」の意味で**成功してしまう**ため `||` に落ちず、mtime の代わりにブロック数が
  返って `age=$(( ... ))` が構文エラーになる。GNU(`-c`)を先に試す順序へ直した。macOS の BSD stat は
  `-c` を知らないので確実にフォールバックする
- **`stty` が非 0**: MSYS の COM ポートでは `raw` / `-echo` / 速度をまとめて設定できず
  `unable to perform all requested operations` で exit 1 になる(`-hupcl` 単体・`clocal` 単体は成功)。
  `set -eu` の led-test.sh / led-demo.sh はここで黙って落ちていた。`|| true` で許容する。
  適用できる分は適用されるので、DTR/RTS は固定されたまま(open/close を繰り返しても uptime は単調増加)
- **COM ポートは排他オープン**: macOS の `cu.*` と違い、2 本目以降の open が `Permission denied` になる。
  hook が並行発火すると取りこぼすため、`send_serial` に 0.1 秒間隔 × 10 回のリトライを入れた
  (6 並行で全て着弾することを確認)。リダイレクトは左から処理されるので、シェル自身のエラーを消すには
  `2>/dev/null` を `3<>` **より前**に書く必要がある。led-demo.sh が fd 9 でポートを掴み続ける仕掛けは
  同じ理由で Windows では自分の `atom_send` を弾くので、MSYS では掴まない
- **プロセス起動が重い**: Git Bash は 1 プロセス約 70ms かかり、hook 1 回で十数個起動していたため
  1.18 秒/イベントになっていた。`now_ms` の perl を `EPOCHREALTIME` に、`jget` の sed+head+コマンド置換を
  bash の `[[ =~ ]]` + `printf -v` に、`cat` を `read -d ''` に置き換えて **0.40 秒/イベント**まで short-cut。
  いずれも bash 3.2 で動く構文なので macOS 側の挙動は変わらない

USB シリアル(Windows)と BLE(Mac)は同時に使える。firmware は 3 経路を同じ `handleLine` に流して
sid ごとに集約するので、両方のセッションが 1 個の LED に並んで出る(`status` の `sessions=` で確認できる)。

**シリアルポートは固定せず自動検出にした(2026-09-07)**。Windows では USB を差し直すと COM 番号
(= `/dev/ttyS<N>`)が変わるため、`ATOM_SERIAL="auto"` で候補から探すようにした。候補は
`/dev/ttyS*`(Windows)と `/dev/cu.usbserial-*` / `cu.wchusbserial*` / `cu.SLAB_USBtoUART*` /
`cu.usbmodem*`(macOS)。存在しない glob は `[ -c ]` で落ちるので OS 判定は要らない。
見つけたパスは `$TMPDIR/claude-led-serial` にキャッシュし、次回は `[ -c ]` 一発で済ませる
(実測: 初回 0.51 秒、キャッシュヒット 0.40 秒 = 固定指定時と同じ)。候補が 1 本ならそのまま使い、
複数あるときだけ `status` を投げて `state=` が返るものを選ぶ(1 本あたり最大 1 秒、変わった時だけ)。
ポートが無い間は hook が 0.28 秒で静かに失敗し、stderr も汚さない。

注意: 候補列挙に `set -- $cands` を使うとスクリプト本体の `$1`(サブコマンド名)を壊す。
led.sh は関数内なので影響しないが、led-test.sh ではトップレベルなので配列を使うこと。

**経路設定を `~/.claude/led.conf` に分離した(2026-09-07)**。従来は `~/.claude/led.sh` の冒頭を直接
書き換える手順だったが、リポジトリ側の更新を `cp led.sh ~/.claude/led.sh` で反映すると設定が消え、
`ATOM_SERIAL` が空のまま HTTP 経路(既定の `192.168.1.50`)に落ちる。curl が 1 秒でタイムアウトして
`led.sh` の終了コードが 28 になるだけで、stderr には何も出ないので気づきにくい(実際にこれで
「hook は発火しているのに LED が変わらない」を踏んだ)。`led.sh` は既定値の直後に led.conf を
`.` で読むので、再コピーしても設定は残る。

hook 側の切り分けでは、Windows でも `bash ~/.claude/led.sh <state>` / `async: true` / `matcher: "*"`
すべて正常に発火することを確認した(5 通りの起動形をログ付きラッパーで比較)。`$HOME` ではなく `~` に
してあるのは、hook が PowerShell や cmd から起動されても `~` は展開されずそのまま bash に渡り、
bash 側が展開してくれるため。`$HOME` は PowerShell/cmd では空になる。

**未解決(環境側)**: 会社の管理端末では MDM が `Bluetooth/ServicesAllowedList` を強制していることがある
(`HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Bluetooth`)。許可リストは SIG 標準 UUID だけなので、
NUS の `6E400001-…` は載っておらず、**スキャンとサービス探索は成功するのに GATT の read/write だけが
`AccessDenied`(`GattCommunicationStatus=3`、`protocol_error=None`)になる**。ペアリングの有無とは無関係で、
デバイス／サービスの `request_access_async` はどちらも Allowed(=1)を返す。この状態はスクリプト側では
回避できない。情シスに UUID を許可リストへ追加してもらうか、USB シリアル / WiFi 経路を使う。

### プロジェクトの uv 化(2026-09-04)

Python は `ble-bridge.py` の bleak 依存だけ。`pyproject.toml` + `uv.lock` を置き、スクリプト冒頭に
PEP 723 のインラインメタデータ(`dependencies = ["bleak>=0.22"]`)を書いた。`uv run ble-bridge.py` で
bleak(+ macOS では pyobjc)が自動で用意される。`pip install` 不要。`.venv/` と `__pycache__/` は gitignore 済み。

### 自動消灯(2026-08-06)

最後の HTTP リクエストから 30 分(`OFF_MS`)で完全消灯、次のリクエストで復帰。
`STALE_MS`(セッション失効)とは別のタイマー(`lastRequest`)。

## ケース設計(3D プリント、Clawd 風キャラ)

- 胸のハート窓のデッドフロント構造: オレンジ PLA 薄皮 **0.4mm** を本体と一体印刷
  (実測で idle の暗い青含む全色視認 OK、2026-08-08)+ LED からの空気層 **8〜10mm**
  (目安: 窓幅の半分以上)。白拡散板も検討したが、0.4mm 薄皮のみで全色見えたため**最終的に不採用**
- 目は別ジョブで印刷して接着(AMS 不要にするため)。ケーブルは四方の切り欠きでどの方向にも出せる
- お腹と背中の 2 パーツ構成で、**6mm×3mm 円形磁石 × 4 個**で留める(ネジ・接着なし、書き込み時に開けられる)
- 遮光したい壁は 1.5mm 以上。窓の周囲はペリメータを増やしてソリッドにしないとインフィルが透ける
- 白 PLA は最も光を通す色 = 白試作で OK ならオレンジ本番はより遮光される
- オレンジ PLA は色フィルタとして働く(緑・青を減衰)。tool を白にしたのはこのため
- ハート上部の谷は幅 1.5mm 以上ないと潰れる
- ボタン穴なし(書き込み時はケースから外す運用)。手元では L 字 USB アダプタで立てているが、アダプタの個体差で合わないものがあるため公開文面には書かない
- 帽子デザイン案は AMS がないため見送り

## 開発の落とし穴

- `pio device monitor` は TTY 必須でバックグラウンド実行不可。代わりに pyserial で
  `dtr = False` / `rts = False` を設定してからポートを開いて読む
  (PlatformIO 同梱の python: `/opt/homebrew/Cellar/platformio/*/libexec/bin/python`)
- `platform = espressif32@6.9.0` 固定は Espressif が PlatformIO 公式プラットフォームの
  保守を終了しているため。最新にすると Arduino core 3.x との噛み合わせでビルドが通らないことがある
- `loop()` に `delay()` を入れない(handleClient が止まる)。点滅は全て `millis()` 差分で描画
- 起動時の WiFi 接続中インジケータは紫の常灯(tool の白い呼吸とは動きで区別)
