# Google Antigravity で使う

Clawd Heartbeat は Claude Code 専用ではない。デバイス側(ファームウェア + BLE デーモン + 行コマンド
プロトコル)はエージェント非依存なので、Antigravity のフックから同じ LED を光らせられる。Claude Code と
同時に使っても、firmware がセッション別に集約するので 1 個の LED を共有できる。

構成は Claude Code と同じで、フックに割り当てる薄いアダプタ [`atom-antigravity.sh`](../atom-antigravity.sh) を
足すだけ。送信は Claude Code と同じ BLE デーモン(`ble-bridge.py`)を共有する。

## イベント → 状態の対応

Antigravity のフックは 5 種類(`PreToolUse` / `PostToolUse` / `PreInvocation` / `PostInvocation` / `Stop`)。
これを次のように割り当てる。

| フック | 状態 | 見え方 |
| :--- | :--- | :--- |
| PreInvocation / PostInvocation | tool | 白の呼吸(作業中)|
| PreToolUse(matcher `run_command`)| wait | 赤(コマンドの承認待ち)|
| PostToolUse(matcher `run_command`)| tool | 白に戻る(コマンド完了)|
| Stop | done | 緑の点滅(完了)→ 自動で青 |
| (イベントなし)| idle | 青の常灯。done 失効やセッション失効で自動的に戻る |

idle(青)は送らない。firmware が「何も active でない」ときに自動的に青へ戻る(done は 6 秒で失効)。

## 承認待ちの赤について(重要)

Antigravity のフックには権限・承認専用のイベントが無い。代わりに **PreToolUse フックが返す `decision`** で
承認を制御できる。このアダプタは `run_command` の PreToolUse で `{"decision":"ask"}` を返し、Antigravity に
ユーザー承認を求めさせる。その瞬間から LED が赤になり、承認してコマンドが走り、完了(PostToolUse)で白に戻る。

トレードオフ:

- PreToolUse は `decision` が必須で、**中立に観測するモードが無い**。フックを入れた対象は、そのフックが
  権限の決定権を持つ。だから対象を **`run_command` だけ**に絞っている。他のツールや Antigravity の既定
  ポリシーには一切手を付けない。
- この設定では **シェルコマンドが毎回承認プロンプトを挟む**(`ask` は「Always Allow」を尊重するので、
  許可済みのコマンドは確認不要=赤も出ない)。常に確認したいなら `atom-antigravity.sh wait --ask` の
  `--ask` を、アダプタ側で `force_ask` に変えてもよい(常に確認・常に赤)。全自動で走らせたい場合は
  PreToolUse の行を `hooks.json` から外す(承認待ちの赤は出なくなるが、白/緑/青は残る)。
- 承認を拒否した場合、PostToolUse は発火しないので赤が残るが、次のモデル呼び出しの PostInvocation で
  白に戻る(保険)。それも無ければセッション失効で青に落ちる。

## セットアップ

前提: BLE 経路が動いていること(`ble-bridge.py` と `~/.claude/ble-bridge.py`、[README](../README.md) の
BLE 節参照)。Claude Code を BLE で使っていれば、デーモンはそのまま共有される。

1. アダプタを配置する。

   ```bash
   cp atom-antigravity.sh ~/.claude/atom-antigravity.sh && chmod +x ~/.claude/atom-antigravity.sh
   ```

2. フックを設定する。[`antigravity-hooks.json`](../antigravity-hooks.json) を Antigravity の設定場所に置く。
   - ワークスペース単位: そのリポジトリの `.agents/hooks.json`
   - 全体: `~/.gemini/config/hooks.json`

   ```bash
   mkdir -p ~/.gemini/config && cp antigravity-hooks.json ~/.gemini/config/hooks.json
   ```

3. Antigravity を再起動してフックを読み込ませる。適当なコマンドをエージェントに実行させ、
   承認プロンプトで赤 → 承認して白 → 完了で緑 → 青、と遷移すれば OK。

`hooks.json` の `command` は `$HOME/.claude/atom-antigravity.sh ...` を指す。アダプタの送信経路は
冒頭の `ATOM_BLE` / `ATOM_SERIAL` / `ATOM_URL` で切り替わる(既定は BLE、led.sh と同じ)。

## 注意

- Antigravity のフックは非同期オプションが無く同期実行(既定タイムアウト 30 秒)。このアダプタは送信を
  バックグラウンドに回して即座に JSON を返すので、エージェントを待たせない。BLE デーモン未起動時の初回だけ
  裏で起動(数秒)が走る。
- バージョンによって `Stop` / `PostToolUse` が発火しない報告がある(Antigravity の既知の不具合)。
  白/緑が出ないときは、そのバージョンのフック動作を疑う。
- `sid` は `ag:<conversationId>`。Claude Code のセッション(別 sid)と同じ LED を共有し、
  優先度 `wait > err > done > tool > idle` で集約される(どちらかが承認待ちなら赤)。
