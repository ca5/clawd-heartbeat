#!/usr/bin/env bash
# Claude Code hook → M5Atom Lite ステータス送信
# - stdin の hook JSON から session_id を抽出してセッション別に送る
# - ダイアログ(権限確認 / AskUserQuestion)表示中はマーカーを置き、
#   サブエージェント等の tool イベントによる赤の上書きを防ぐ
# - 拒否・中断は hook に流れないため、ダイアログ表示中だけトランスクリプトを
#   監視して痕跡(拒否の tool_result / 中断メッセージ)を検知したら赤を解除する
# - 手動実行(tty)時は stdin を読まず sid=default で送る
# - 送信経路は BLE / USB シリアル / WiFi(HTTP)のいずれか(下の設定で選ぶ。上から優先)

# ↓ 送信経路の設定
#   BLE       : ATOM_BLE=1。Mac 側の常駐デーモン(ble-bridge.py)が接続を保持し、hook は
#               Unix ソケットに 1 行書くだけ。Atom は USB 電源だけで離れた場所に置ける。
#               事前に `pip install bleak` と、初回のみ Bluetooth 使用許可(macOS のダイアログ)が要る
#   USB シリアル: ATOM_BLE を空にして ATOM_SERIAL にポート(`ls /dev/cu.usbserial-*`)
#   WiFi/HTTP : ATOM_BLE と ATOM_SERIAL を空にして ATOM_URL に固定 IP
ATOM_BLE=""                          # "1" で BLE を使う
ATOM_SERIAL=""                       # 例: /dev/cu.usbserial-XXXXXXXXXX
ATOM_URL="http://192.168.1.50"

# BLE ブリッジの設定(ATOM_BLE=1 のときだけ使う)
ATOM_BLE_SOCK="${TMPDIR:-/tmp}/claude-led-ble.sock"   # デーモンが待ち受ける Unix ソケット
ATOM_BLE_DIR="$HOME/.claude"         # ble-bridge.py の置き場所(led.sh と同じ場所を想定)
# デーモンの起動コマンド。空なら uv があれば "uv run --script"、無ければ "python3" で起動する。
# uv 起動なら bleak は PEP 723 のインラインメタデータから自動で用意される
ATOM_BLE_CMD=""
ATOM_BLE_PYTHON="python3"            # ソケット送信のフォールバック(bleak 不要・標準ライブラリのみ)

now_ms() { perl -MTime::HiRes=time -e 'printf("%.0f", time()*1000)' 2>/dev/null || echo 0; }

# BLE: 1 行を常駐デーモンのソケットへ送る。デーモンが居なければ起こしてから送る。
# デーモンは BLE 接続を張りっぱなしにするので、送信ごとの再接続待ちが無い(応答は読まない)。
send_ble() {
  ble_write "$1" && return 0
  ensure_ble_daemon
  local i
  for i in 1 2 3 4 5 6 7 8; do
    ble_write "$1" && return 0
    sleep 0.5
  done
  return 1
}

# ソケットへ 1 行送る。nc -U が無ければ python でフォールバック。接続できなければ非 0
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

# デーモンが居なければ起動(二重起動は mkdir ロックで防ぐ)。接続確立まで少し待つ
ensure_ble_daemon() {
  local lock="$ATOM_BLE_SOCK.lock"
  [ -S "$ATOM_BLE_SOCK" ] && return 0
  local cmd="$ATOM_BLE_CMD"
  if [ -z "$cmd" ]; then
    if command -v uv >/dev/null 2>&1; then cmd="uv run --script"; else cmd="$ATOM_BLE_PYTHON"; fi
  fi
  if mkdir "$lock" 2>/dev/null; then
    ( $cmd "$ATOM_BLE_DIR/ble-bridge.py" --socket "$ATOM_BLE_SOCK" \
        </dev/null >>"${TMPDIR:-/tmp}/claude-led-ble.log" 2>&1 ; rmdir "$lock" 2>/dev/null ) &
    sleep 3   # スキャン + 接続の確立を待つ(初回だけ)
  fi
}

# USB シリアル送信。Atom Lite は DTR/RTS が EN/IO0 に配線されており、ポートの open/close で
# 信号が動くとボードがリセットされる。対策として -hupcl を毎回セットして信号を固定する。
# tty.* はキャリア待ちで固まることがあるので cu.* を使う。応答は読まない(hook は投げて終わり)
send_serial() {
  [ -c "$ATOM_SERIAL" ] || return 1
  {
    stty raw -echo -hupcl clocal 115200 <&3 2>/dev/null
    printf '%s\n' "$1" >&3
  } 3<>"$ATOM_SERIAL" 2>/dev/null
}

send_state() {
  if [ -n "$ATOM_BLE" ]; then
    send_ble "led s=$1 sid=${2:-default} ts=$(now_ms)"
  elif [ -n "$ATOM_SERIAL" ]; then
    send_serial "led s=$1 sid=${2:-default} ts=$(now_ms)"
  else
    curl -s -m 1 --retry 2 --retry-all-errors "$ATOM_URL/led?s=$1&sid=${2:-default}&ts=$(now_ms)" >/dev/null 2>&1
  fi
}
file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# ダイアログ応答待ちの間、トランスクリプト(JSONL)の追記分を 1 秒間隔で監視する。
# 「No で拒否」「Ctrl+C で中断」はどの hook イベントも発火しない(実測)が、
# トランスクリプトには即座に記録されるため、それを検知して赤を解除する。
# パターンは実際の JSONL 構造への構造的マッチ(会話文中の引用は \" にエスケープ
# されるため誤発火しない)。マーカーが消えたら通常経路で解決済みとして終了。
watch_dialog() {
  local tr="$1" marker="$2" sid="$3"
  local deny='"content"[[:space:]]*:[[:space:]]*"The user doesn'\''t want to proceed with this tool use'
  local intr='"text"[[:space:]]*:[[:space:]]*"\[Request interrupted by user'
  local size new end
  size=$(file_size "$tr")
  end=$(( $(date +%s) + 600 ))     # マーカーの TTL と同じ 10 分で自然終了
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep 1
    [ -f "$marker" ] || return 0   # 承認完了・新プロンプト等の通常経路で解決済み
    new=$(file_size "$tr")
    if [ "$new" -gt "$size" ]; then
      if tail -c +"$((size + 1))" "$tr" 2>/dev/null | grep -Eq "$deny|$intr"; then
        rm -f "$marker"
        send_state idle "$sid"     # ターンが続く場合は直後の hook がすぐ上書きする
        return 0
      fi
      size=$new
    fi
  done
}

state="$1"
sid=""
if [ ! -t 0 ]; then
  input=$(cat)
  jget() { printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }
  sid=$(jget session_id)
  event=$(jget hook_event_name)
  tool=$(jget tool_name)
  tuid=$(jget tool_use_id)
  tmp="${TMPDIR:-/tmp}"
  marker="$tmp/claude-led-wait-${sid:-default}"     # "<tuid|-> <tool>" ダイアログ応答待ち
  pending="$tmp/claude-led-pending-${sid:-default}" # "<tuid> <tool>" 直近の PreToolUse

  # マーカーの TTL(10分): 解除イベントの取りこぼしで赤が永続しないように
  if [ -f "$marker" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || echo 0) ))
    [ "$age" -gt 600 ] && rm -f "$marker"
  fi

  # 選択肢ダイアログ(AskUserQuestion)の表示も承認待ちと同じ扱いにする
  if [ "$state" = "tool" ] && [ "$event" = "PreToolUse" ] && [ "$tool" = "AskUserQuestion" ]; then
    state="wait"
  fi

  # PermissionRequest に tool_use_id が無いため、直前の PreToolUse を控えておいて紐付ける
  if [ "$event" = "PreToolUse" ] && [ -n "$tuid" ]; then
    printf '%s %s' "$tuid" "$tool" > "$pending"
  fi

  if [ "$state" = "wait" ]; then
    # ダイアログ表示: どのツール呼び出しの応答待ちかを記録
    if [ -n "$tuid" ]; then
      printf '%s %s' "$tuid" "$tool" > "$marker"          # AskUserQuestion(PreToolUse 由来)
    else
      ptuid=""; ptool=""
      [ -f "$pending" ] && read -r ptuid ptool < "$pending"
      if [ -n "$ptuid" ] && [ "$ptool" = "$tool" ]; then
        printf '%s %s' "$ptuid" "$tool" > "$marker"       # PermissionRequest(PreToolUse から補完)
      else
        printf '%s %s' "-" "$tool" > "$marker"            # 補完失敗時はツール名だけで照合
      fi
    fi
    # 拒否・中断の監視を起動(ダイアログ 1 回ごとの短命プロセス)
    tpath=$(jget transcript_path)
    if [ -n "$tpath" ] && [ -f "$tpath" ]; then
      ( watch_dialog "$tpath" "$marker" "${sid:-default}" ) </dev/null >/dev/null 2>&1 &
    fi
  elif [ "$state" = "tool" ] && [ -f "$marker" ]; then
    # ダイアログ応答待ち中に届く tool イベントの扱い:
    # サブエージェントは同じ session_id で hook を発火し続けるため、
    # そのまま送ると赤(wait)が白(tool)に上書きされてしまう
    case "$event" in
      UserPromptSubmit)
        rm -f "$marker"       # 新しいプロンプト = ダイアログは解決済み
        ;;
      PostToolUse|PostToolUseFailure)
        waiting=""; wtool=""
        read -r waiting wtool < "$marker" 2>/dev/null || true
        if { [ "$waiting" != "-" ] && [ "$tuid" = "$waiting" ]; } \
           || { [ "$waiting" = "-" ] && [ "$tool" = "$wtool" ]; }; then
          rm -f "$marker"     # 待っていた呼び出しの完了 = ダイアログ応答済み
        else
          state="wait"        # 別の呼び出し(サブエージェント等)の完了: 赤を維持
        fi
        ;;
      *)
        state="wait"          # ダイアログ待ち中の PreToolUse 等も赤を維持
        ;;
    esac
  elif [ "$state" != "tool" ]; then
    rm -f "$marker" "$pending"   # done / err / idle でダイアログ待ちは終了
  fi
fi
send_state "$state" "$sid"
