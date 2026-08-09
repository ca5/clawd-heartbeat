# NOTES — 運用情報と設計判断ログ

このファイルは引き継ぎ用。使い方・セットアップは [README.md](README.md)、
初期構築前の設計経緯は [HANDOFF.md](HANDOFF.md) を参照。

## 稼働情報(この個体)

個体固有の値(IP・MAC・シリアルポート)は `LOCAL.md`(gitignore 済み)に記載。

- デバイス IP: ルーターで DHCP 予約して固定する(例: `http://192.168.1.50`)
- WiFi 認証情報: `include/secrets.h`(gitignore 済み)
- テストスクリプトの宛先: `.atom-ip`(gitignore 済み)に実 URL を書くか、環境変数 `ATOM` で指定

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
- 白と青の役割を反転(2026-08-09): **tool = 青の呼吸、idle = 白の常灯**(「動いてる時は青がいい」)
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

### 自動消灯(2026-08-06)

最後の HTTP リクエストから 30 分(`OFF_MS`)で完全消灯、次のリクエストで復帰。
`STALE_MS`(セッション失効)とは別のタイマー(`lastRequest`)。

## ケース設計(3D プリント、Clawd 風キャラ)

- 胸のハート窓のデッドフロント構造: オレンジ PLA 薄皮 **0.4mm**
  (実測で idle の暗い青含む全色視認 OK、2026-08-08)+ 裏に白拡散板 0.4〜0.6mm +
  LED からの空気層 **8〜10mm**(目安: 窓幅の半分以上)
- 遮光したい壁は 1.5mm 以上。窓の周囲はペリメータを増やしてソリッドにしないとインフィルが透ける
- 白 PLA は最も光を通す色 = 白試作で OK ならオレンジ本番はより遮光される
- オレンジ PLA は色フィルタとして働く(緑・青を減衰)。tool を白にしたのはこのため
- ハート上部の谷は幅 1.5mm 以上ないと潰れる
- ボタン穴なし(書き込み時はケースから外す運用)。立てるのは L 字 USB アダプタ
- 帽子デザイン案は AMS がないため見送り

## 開発の落とし穴

- `pio device monitor` は TTY 必須でバックグラウンド実行不可。代わりに pyserial で
  `dtr = False` / `rts = False` を設定してからポートを開いて読む
  (PlatformIO 同梱の python: `/opt/homebrew/Cellar/platformio/*/libexec/bin/python`)
- `platform = espressif32@6.9.0` 固定は Espressif が PlatformIO 公式プラットフォームの
  保守を終了しているため。最新にすると Arduino core 3.x との噛み合わせでビルドが通らないことがある
- `loop()` に `delay()` を入れない(handleClient が止まる)。点滅は全て `millis()` 差分で描画
- 起動時の WiFi 接続中インジケータは紫の常灯(tool の白い呼吸とは動きで区別)
