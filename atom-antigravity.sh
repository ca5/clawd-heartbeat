#!/usr/bin/env bash
# Clawd Heartbeat — Google Antigravity 用アダプタ
#
# Antigravity のフック(.agents/hooks.json / ~/.gemini/config/hooks.json)から呼ばれ、
# エージェントのイベントを LED の状態に変換して送る。Claude Code の led.sh の Antigravity 版。
#
# フックは stdin に JSON(conversationId / toolCall / modelName / stepIdx …)を受け取り、
# stdout に JSON を返す契約。イベント名は stdin に無いので、状態は第 1 引数で渡す。
#   atom-antigravity.sh tool           # PreInvocation / PostInvocation / PostToolUse に割り当て
#   atom-antigravity.sh wait --ask     # PreToolUse(run_command)に割り当て。承認プロンプトを出す
#   atom-antigravity.sh done           # Stop に割り当て
#
# 出力 JSON:
#   wait --ask → {"decision":"ask"}    Antigravity がユーザーに承認を求める(その間 LED は赤)
#   それ以外   → {}                    観測のみ(挙動を変えない)
#
# 送信は Claude Code と同じ BLE デーモン(ble-bridge.py)を共有する。sid に conversationId を使い、
# "ag:" を前置して Claude のセッションと区別する。firmware が両方を集約して 1 個の LED に出す。
# 送信は投げっぱなし(バックグラウンド)にして、フックはすぐ JSON を返す(エージェントを待たせない)。

# ---- 送信経路(led.sh と同じ既定。BLE のソケットとデーモンを共有する)----
ATOM_BLE="1"                          # "1" で BLE。空にすると ATOM_SERIAL / ATOM_URL を使う
ATOM_SERIAL=""                        # 例: /dev/cu.usbserial-XXXX
ATOM_URL="http://192.168.1.50"
ATOM_BLE_SOCK="${TMPDIR:-/tmp}/claude-led-ble.sock"
# 共有 BLE デーモン ble-bridge.py の置き場所。Claude Code の setup が ~/.claude に置くのでそれを共有する。
# Claude Code を使っていない/別の場所に置くなら、ここを変える(このアダプタ自身の置き場所とは無関係)
ATOM_BLE_DIR="$HOME/.claude"
ATOM_BLE_CMD=""                       # 空なら uv があれば "uv run --script"、無ければ python3
ATOM_BLE_PYTHON="python3"

now_ms() { perl -MTime::HiRes=time -e 'printf("%.0f", time()*1000)' 2>/dev/null || echo 0; }

ble_write() {
  [ -S "$ATOM_BLE_SOCK" ] || return 1
  if command -v nc >/dev/null 2>&1; then
    printf '%s\n' "$1" | nc -U -w 2 "$ATOM_BLE_SOCK" >/dev/null 2>&1
  else
    "$ATOM_BLE_PYTHON" - "$ATOM_BLE_SOCK" "$1" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(2)
s.connect(sys.argv[1]); s.sendall((sys.argv[2] + "\n").encode()); s.recv(256); s.close()
PY
  fi
}

ensure_ble_daemon() {
  local lock="$ATOM_BLE_SOCK.lock"
  [ -S "$ATOM_BLE_SOCK" ] && return 0
  if [ -d "$lock" ]; then
    local age
    age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0) ))
    [ "$age" -gt 15 ] && rmdir "$lock" 2>/dev/null
  fi
  local cmd="$ATOM_BLE_CMD"
  if [ -z "$cmd" ]; then
    if command -v uv >/dev/null 2>&1; then cmd="uv run --script"; else cmd="$ATOM_BLE_PYTHON"; fi
  fi
  if mkdir "$lock" 2>/dev/null; then
    ( $cmd "$ATOM_BLE_DIR/ble-bridge.py" --socket "$ATOM_BLE_SOCK" \
        </dev/null >>"${TMPDIR:-/tmp}/claude-led-ble.log" 2>&1 ; rmdir "$lock" 2>/dev/null ) &
    sleep 3
  fi
}

send_state() {   # 引数: 状態, sid
  local line="led s=$1 sid=${2:-default} ts=$(now_ms)"
  if [ -n "$ATOM_BLE" ]; then
    ble_write "$line" && return 0
    ensure_ble_daemon
    local i
    for i in 1 2 3 4; do ble_write "$line" && return 0; sleep 0.5; done
  elif [ -n "$ATOM_SERIAL" ] && [ -c "$ATOM_SERIAL" ]; then
    { stty raw -echo -hupcl clocal 115200 <&3 2>/dev/null; printf '%s\n' "$line" >&3; } 3<>"$ATOM_SERIAL" 2>/dev/null
  else
    curl -s -m 1 "$ATOM_URL/led?s=$1&sid=${2:-default}&ts=$(now_ms)" >/dev/null 2>&1
  fi
}

state="${1:-tool}"
ask=0
[ "${2:-}" = "--ask" ] && ask=1

# stdin の JSON から conversationId を取り出して sid にする(無ければ default)
sid="default"
if [ ! -t 0 ]; then
  input=$(cat)
  cid=$(printf '%s' "$input" | sed -n 's/.*"conversationId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$cid" ] && sid="ag:$cid"
fi

# 呼ばれたことの記録(フックが発火しているかの切り分け用。害は無いので常時残す)。
# 書き込み失敗の stderr も外へ漏らさない(stdout の JSON は別途汚さない)
( printf '%s state=%s sid=%s\n' "$(date '+%F %T')" "$state" "$sid" >> "$HOME/.gemini/config/atom-antigravity.log" ) 2>/dev/null

# 送信は投げっぱなし(フックを待たせない)。初回のデーモン起動もここで裏に回る
( send_state "$state" "$sid" ) </dev/null >/dev/null 2>&1 &

# フックの契約に従い stdout へ JSON を返す(Antigravity は Fail-Closed。不正な出力や非 0 終了は
# ツール実行を遮断するので、必ず適格な JSON を出して exit 0 する)。
#   PreToolUse(wait --ask)→ decision 必須。ask はユーザーに承認を求める(その間 LED は赤)
#   Stop(done)          → decision 必須。stop で「そのまま終了を確定」(continue を強制しない)
#   それ以外(tool)      → 空オブジェクト(意見なし=挙動を変えない)
if [ "$state" = "wait" ] && [ "$ask" -eq 1 ]; then
  printf '{"decision":"ask"}\n'
elif [ "$state" = "done" ]; then
  printf '{"decision":"stop"}\n'
else
  printf '{}\n'
fi
exit 0
