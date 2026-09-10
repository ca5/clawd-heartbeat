#!/usr/bin/env bash
# Claude Code hook → M5Atom Lite ステータス送信
# - stdin の hook JSON から session_id を抽出してセッション別に送る
# - ダイアログ(権限確認 / AskUserQuestion)表示中はマーカーを置き、
#   サブエージェント等の tool イベントによる赤の上書きを防ぐ
# - 拒否・中断は hook に流れないため、ダイアログ表示中だけトランスクリプトを
#   監視して痕跡(拒否の tool_result / 中断メッセージ)を検知したら赤を解除する
# - 手動実行(tty)時は stdin を読まず sid=default で送る
# - 送信経路は HOGP / BLE / USB シリアル / WiFi(HTTP)のいずれか(下の設定で選ぶ。上から優先)

# ↓ 送信経路の設定
#   HOGP      : ATOM_HID=1。BLE HID(HID over GATT)としてペアリングした Atom へ、常駐デーモン
#               (hid-bridge.py)が Output Report で送る。BLE リンクは OS の HID ドライバが
#               保持するので再接続・スリープ復帰の面倒が無い。MDM の Bluetooth 許可リストが
#               カスタム UUID を弾く管理端末でも通る(HID の 0x1812 は許可されている)
#   BLE       : ATOM_BLE=1。常駐デーモン(ble-bridge.py)が接続を保持し、hook はローカルの
#               ソケットに 1 行書くだけ。Atom は USB 電源だけで離れた場所に置ける。
#               待ち受けは POSIX が Unix ソケット、Windows が 127.0.0.1:<port>(下の設定参照)。
#               事前に `pip install bleak` と、初回のみ Bluetooth 使用許可(macOS のダイアログ)が要る
#   USB シリアル: ATOM_HID と ATOM_BLE を空にして ATOM_SERIAL にポートを指定。"auto" で自動検出
#               (差し直しで COM 番号が変わる Windows では auto 推奨)。明示するなら
#               macOS: `ls /dev/cu.usbserial-*`、Windows の Git Bash: /dev/ttyS<N> = COM<N+1>
#   WiFi/HTTP : 上の 3 つを空にして ATOM_URL に固定 IP
ATOM_HID=""                          # "1" で HOGP(BLE HID)を使う。BLE より優先
ATOM_BLE=""                          # "1" で BLE を使う
ATOM_SERIAL=""                       # "auto" / /dev/cu.usbserial-XXXX / /dev/ttyS2 等
ATOM_URL="http://192.168.1.50"

# BLE ブリッジの設定(ATOM_BLE=1 のときだけ使う)
ATOM_BLE_SOCK="${TMPDIR:-/tmp}/claude-led-ble.sock"   # デーモンが待ち受ける Unix ソケット
ATOM_BLE_DIR="$HOME/.claude"         # ble-bridge.py の置き場所(led.sh と同じ場所を想定)
# デーモンの起動コマンド。空なら uv があれば "uv run --script"、無ければ "python3" で起動する。
# uv 起動なら bleak は PEP 723 のインラインメタデータから自動で用意される
ATOM_BLE_CMD=""
ATOM_BLE_PYTHON="python3"            # ソケット送信のフォールバック(bleak 不要・標準ライブラリのみ)
ATOM_BLE_PORT=""                     # 空でなければ Unix ソケットではなく 127.0.0.1:<port> を使う

# HOGP ブリッジの設定(ATOM_HID=1 のときだけ使う)。ソケットのプロトコルは BLE と同一
ATOM_HID_SOCK="${TMPDIR:-/tmp}/claude-led-hid.sock"
ATOM_HID_PORT=""                     # 空でなければ 127.0.0.1:<port>(Windows で自動設定)
ATOM_HID_DIR="$HOME/.claude"         # hid-bridge.py の置き場所
ATOM_HID_CMD=""                      # 空なら uv があれば "uv run --script"、無ければ python

# 上の既定値は ~/.claude/led.conf があれば上書きされる。経路設定をこのスクリプトに直接書くと、
# リポジトリの更新を `cp led.sh ~/.claude/led.sh` で反映したときに設定ごと消えてしまうため。
#   例) echo 'ATOM_SERIAL="/dev/ttyS2"' > ~/.claude/led.conf
[ -r "$HOME/.claude/led.conf" ] && . "$HOME/.claude/led.conf"

# Windows(Git Bash/MSYS)は CPython に AF_UNIX が無く、ble-bridge.py も Unix ソケットで
# 待ち受けられないので loopback TCP に切り替える(既定ポートは ble-bridge.py の DEFAULT_PORT)。
# python3 は WindowsApps の Store スタブを踏むことがあるので python を既定にする
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    [ -n "$ATOM_BLE_PORT" ] || ATOM_BLE_PORT=47820
    [ -n "$ATOM_HID_PORT" ] || ATOM_HID_PORT=47821
    ATOM_BLE_PYTHON="python"
    ;;
esac

# 現在時刻。結果は $NOW_MS / $NOW_S に入れる(コマンド置換 $(...) は毎回 fork するため使わない)。
# bash 5 以降は組み込み変数で 0 プロセスで済む。macOS 標準の bash 3.2 は外部コマンドに落ちる
if [ -n "${EPOCHREALTIME:-}" ]; then
  now_ms() { local t="${EPOCHREALTIME/[.,]/}"; NOW_MS="${t:0:${#t}-3}"; }   # 秒.マイクロ秒 → ミリ秒
  now_s()  { NOW_S="$EPOCHSECONDS"; }
else
  now_ms() { NOW_MS=$(perl -MTime::HiRes=time -e 'printf("%.0f", time()*1000)' 2>/dev/null) || NOW_MS=0; }
  now_s()  { NOW_S=$(date +%s); }
fi

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

# 常駐デーモンのソケットへ 1 行送る。ble-bridge.py と hid-bridge.py はプロトコルが同一なので
# ここを共有する。$1=Unix ソケットのパス / $2=TCP ポート(空なら Unix) / $3=送る行。
# nc -U が無ければ python でフォールバック。接続できなければ非 0
sock_write() {
  if [ -n "$2" ]; then
    # bash の /dev/tcp なら nc も python も要らない。subshell に入れておけば、繋がらずに
    # リダイレクトがこけても呼び手は死なない(exec だと非対話シェルごと終了してしまう)
    ( printf '%s\n' "$3" >&3
      # デーモンの応答を見る。"error: ..." を成功扱いにすると、ペアリングが切れていても
      # led.sh は届いたと判断してフォールバックが働かない(実測で踏んだ)。
      # 応答が無い(タイムアウト)場合は投げっぱなしとして成功扱いのまま
      IFS= read -r -t 2 reply <&3
      case "$reply" in error:*) exit 1 ;; esac
      : ) 2>/dev/null 3<>"/dev/tcp/127.0.0.1/$2" && return 0
    "$ATOM_BLE_PYTHON" - "$2" "$3" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2)
s.sendall((sys.argv[2] + "\n").encode()); s.recv(256); s.close()
PY
    return
  fi
  [ -S "$1" ] || return 1
  if command -v nc >/dev/null 2>&1; then
    printf '%s\n' "$3" | nc -U -w 2 "$1" >/dev/null 2>&1
  else
    "$ATOM_BLE_PYTHON" - "$1" "$3" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(2)
s.connect(sys.argv[1]); s.sendall((sys.argv[2] + "\n").encode()); s.recv(256); s.close()
PY
  fi
}

# デーモンが待ち受けているか。どちらの経路も「実際に繋いでみる」で判定する。
# Unix ソケットを存在(`[ -S ]`)だけで判定してはいけない: デーモンが後片付けせずに
# 死ぬと接続を拒否する残骸ファイルが残り(`[ -S ]` は真、connect は ECONNREFUSED)、
# それを生存と誤判定すると ensure_*_daemon が二度と起動せず、LED が黙ったまま復旧しない。
# 残骸の削除は不要。デーモンが bind の前に自分で unlink する
sock_alive() {
  if [ -n "$2" ]; then
    ( : ) 2>/dev/null 3<>"/dev/tcp/127.0.0.1/$2"
  else
    [ -S "$1" ] || return 1
    # bash は AF_UNIX に繋げない(`/dev/tcp` は TCP 専用)ので python で繋いで確かめる。
    # macOS の nc は `-U -z` を併用すると生きているソケットでも失敗するため使えない(実測)。
    # python が無い環境では存在チェック止まり = 従来の挙動に落とす
    command -v "$ATOM_BLE_PYTHON" >/dev/null 2>&1 || return 0
    "$ATOM_BLE_PYTHON" - "$1" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(1)
s.connect(sys.argv[1]); s.close()
PY
  fi
}

ble_write() { sock_write "$ATOM_BLE_SOCK" "$ATOM_BLE_PORT" "$1"; }
ble_alive() { sock_alive "$ATOM_BLE_SOCK" "$ATOM_BLE_PORT"; }
hid_write() { sock_write "$ATOM_HID_SOCK" "$ATOM_HID_PORT" "$1"; }
hid_alive() { sock_alive "$ATOM_HID_SOCK" "$ATOM_HID_PORT"; }

# デーモンが居なければ起動(二重起動は mkdir ロックで防ぐ)。接続確立まで少し待つ
ensure_ble_daemon() {
  local lock="$ATOM_BLE_SOCK.lock"
  ble_alive && return 0
  # ソケットが無いのにロックだけ残っている = 前回の起動が後片付けせず落ちた残骸。
  # デーモンは起動後 3 秒ほどでソケットを作るので、ロックが 15 秒より古ければ掃除する
  if [ -d "$lock" ]; then
    local age
    now_s
    age=$(( NOW_S - $(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0) ))
    [ "$age" -gt 15 ] && rmdir "$lock" 2>/dev/null
  fi
  local cmd="$ATOM_BLE_CMD"
  if [ -z "$cmd" ]; then
    if command -v uv >/dev/null 2>&1; then cmd="uv run --script"; else cmd="$ATOM_BLE_PYTHON"; fi
  fi
  local listen="--socket $ATOM_BLE_SOCK"
  [ -n "$ATOM_BLE_PORT" ] && listen="--port $ATOM_BLE_PORT"
  if mkdir "$lock" 2>/dev/null; then
    # リダイレクトはサブシェル自体に掛ける。コマンドだけに掛けるとサブシェルが hook の
    # stdout/stderr パイプを掴んだままになり、hook の出力を読む側が EOF を待って固まる
    ( $cmd "$ATOM_BLE_DIR/ble-bridge.py" $listen ; rmdir "$lock" 2>/dev/null ) \
        </dev/null >>"${TMPDIR:-/tmp}/claude-led-ble.log" 2>&1 &
    sleep 3   # スキャン + 接続の確立を待つ(初回だけ)
  fi
}

# シリアルポートの解決。Windows は USB を差し直すと COM 番号(= /dev/ttyS<N>)が変わるため、
# 設定されたパスが消えていたら候補から探し直し、見つけたものをキャッシュする。
# ATOM_SERIAL="auto" にしておけば最初から自動検出になる(推奨)。
# 候補が 1 本ならそのまま使い、複数あるときだけ status を投げて firmware かどうか確かめる
ATOM_SERIAL_CACHE="${TMPDIR:-/tmp}/claude-led-serial"

# 存在する候補デバイスを列挙(存在しない glob は [ -c ] で落ちるので OS 差は吸収される)
serial_candidates() {
  local p
  for p in /dev/ttyS* /dev/cu.usbserial-* /dev/cu.wchusbserial* /dev/cu.SLAB_USBtoUART* /dev/cu.usbmodem*; do
    [ -c "$p" ] && printf '%s\n' "$p"
  done
}

# そのポートが Clawd Heartbeat か(status に state= が返るか)。読むので 1 秒ほどかかる
serial_is_atom() {
  local line n=0
  {
    stty raw -echo -hupcl clocal 115200 <&3 2>/dev/null || true
    printf 'status\n' >&3
    # 行数に上限を置く。ブートループ中のデバイスは起動ログを延々流すので、
    # 上限が無いとここで固まる(led-test.sh で実測)
    while [ "$n" -lt 60 ] && IFS= read -r -t 1 line <&3; do
      n=$((n + 1))
      case "${line%$'\r'}" in state=*) return 0 ;; esac
    done
  } 2>/dev/null 3<>"$1"
  return 1
}

# $ATOM_SERIAL を実在するポートに解決する。成功で 0。設定どおりに在れば探索も読み出しもしない
resolve_serial() {
  [ -c "$ATOM_SERIAL" ] && return 0
  local cached=""
  [ -r "$ATOM_SERIAL_CACHE" ] && read -r cached < "$ATOM_SERIAL_CACHE" 2>/dev/null
  if [ -n "$cached" ] && [ -c "$cached" ]; then ATOM_SERIAL="$cached"; return 0; fi
  local cands p
  cands=$(serial_candidates)
  [ -n "$cands" ] || return 1
  set -- $cands
  if [ $# -eq 1 ]; then
    ATOM_SERIAL="$1"
  else
    ATOM_SERIAL=""
    for p in "$@"; do
      if serial_is_atom "$p"; then ATOM_SERIAL="$p"; break; fi
    done
    [ -n "$ATOM_SERIAL" ] || return 1
  fi
  printf '%s\n' "$ATOM_SERIAL" > "$ATOM_SERIAL_CACHE" 2>/dev/null
  return 0
}

# HOGP: 1 行を hid-bridge.py のソケットへ送る。BLE リンクは OS が保持しているので、
# デーモンは開いた HID デバイスに Output Report を書くだけ。起動も BLE より速い
send_hid() {
  hid_write "$1" && return 0
  ensure_hid_daemon
  local i
  for i in 1 2 3; do
    hid_write "$1" && return 0
    sleep 0.3
  done
  return 1
}

# デーモンが居なければ起動(二重起動は mkdir ロックで防ぐ)
ensure_hid_daemon() {
  local lock="$ATOM_HID_SOCK.lock"
  hid_alive && return 0
  if [ -d "$lock" ]; then
    local age
    now_s
    age=$(( NOW_S - $(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0) ))
    [ "$age" -gt 15 ] && rmdir "$lock" 2>/dev/null
  fi
  local cmd="$ATOM_HID_CMD"
  if [ -z "$cmd" ]; then
    if command -v uv >/dev/null 2>&1; then cmd="uv run --script"; else cmd="$ATOM_BLE_PYTHON"; fi
  fi
  local listen="--socket $ATOM_HID_SOCK"
  [ -n "$ATOM_HID_PORT" ] && listen="--port $ATOM_HID_PORT"
  if mkdir "$lock" 2>/dev/null; then
    ( $cmd "$ATOM_HID_DIR/hid-bridge.py" $listen ; rmdir "$lock" 2>/dev/null ) \
        </dev/null >>"${TMPDIR:-/tmp}/claude-led-hid.log" 2>&1 &
    sleep 1   # HID デバイスを開くだけなので BLE のスキャン待ちより短い
  fi
}

# USB シリアル送信。Atom Lite は DTR/RTS が EN/IO0 に配線されており、ポートの open/close で
# 信号が動くとボードがリセットされる。対策として -hupcl を毎回セットして信号を固定する。
# tty.* はキャリア待ちで固まることがあるので cu.* を使う。応答は読まない(hook は投げて終わり)
send_serial() {
  [ -c "$ATOM_SERIAL" ] || return 1
  # Windows の COM ポートは排他オープンで、hook が並行して発火すると 2 本目以降の open が
  # Permission denied になる(macOS の cu.* は同時に開ける)。1 回の送信は数十 ms で終わるので、
  # 短い間隔で数回やり直せば取りこぼさない。open できたら即 return する
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    {
      # MSYS の COM ポートでは raw/-echo/速度をまとめて設定できず stty が非 0 を返す(適用できる分は
      # 適用される。-hupcl 単体は成功し、実測でもボードはリセットされない)。set -e 下で落ちないよう許容する
      stty raw -echo -hupcl clocal 115200 <&3 2>/dev/null || true
      printf '%s\n' "$1" >&3
    } 2>/dev/null 3<>"$ATOM_SERIAL" && return 0
    sleep 0.1
  done
  return 1
}

send_state() {
  now_ms
  local line="led s=$1 sid=${2:-default} ts=$NOW_MS"
  if [ -n "$ATOM_HID" ]; then
    send_hid "$line" && return 0
    # HOGP が落ちている(ペアリング切れ・デーモン起動失敗)ときは、設定されていれば
    # USB シリアルに落ちる。HTTP には落ちない(既定のプレースホルダ IP に 1 秒待たされるため)
    [ -n "$ATOM_SERIAL" ] && resolve_serial && send_serial "$line"
    return
  fi
  if [ -n "$ATOM_BLE" ]; then
    send_ble "$line"
  elif [ -n "$ATOM_SERIAL" ]; then
    resolve_serial && send_serial "$line"
  else
    curl -s -m 1 --retry 2 --retry-all-errors "$ATOM_URL/led?s=$1&sid=${2:-default}&ts=$NOW_MS" >/dev/null 2>&1
  fi
}
# GNU(Linux / Git Bash)を先に試す。逆順にすると GNU の `stat -f` が「ファイルシステム情報」の
# 意味で成功してしまい、ファイルサイズや mtime の代わりにブロック数が返る(BSD は -c を知らず落ちる)
file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }

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
  now_s
  end=$(( NOW_S + 600 ))           # マーカーの TTL と同じ 10 分で自然終了
  while now_s && [ "$NOW_S" -lt "$end" ]; do
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

# SessionStart hook 用: BLE デーモンだけを先に起こす(状態は送らない)。
# 最初の実イベントより前に接続を確立させ、1 個目の取りこぼしを無くす。
# ATOM_BLE を使っていなければ何もしない。多重起動はソケットロックで防ぐ
if [ "$state" = "ensure-ble" ]; then
  [ -n "$ATOM_HID" ] && ensure_hid_daemon
  [ -n "$ATOM_BLE" ] && ensure_ble_daemon
  exit 0
fi

sid=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' input      # cat の起動を避けて stdin を丸ごと読む(EOF で非 0 になるだけ)
  # JSON の文字列フィールドを 1 個取り出して $2 の変数に入れる。sed + head + コマンド置換で
  # 1 フィールドあたり 3 プロセス起動していたのを bash の正規表現に置き換えた(bash 3.2 でも動く)。
  # JSON 文字列の内側では引用符が \" にエスケープされるので、素の "key" はキーとしてしか現れない
  jget() {
    local re="\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    if [[ $input =~ $re ]]; then printf -v "$2" '%s' "${BASH_REMATCH[1]}"
    else printf -v "$2" '%s' ""; fi
  }
  jget session_id     sid
  jget hook_event_name event
  jget tool_name      tool
  jget tool_use_id    tuid
  tmp="${TMPDIR:-/tmp}"
  marker="$tmp/claude-led-wait-${sid:-default}"     # "<tuid|-> <tool>" ダイアログ応答待ち
  pending="$tmp/claude-led-pending-${sid:-default}" # "<tuid> <tool>" 直近の PreToolUse

  # マーカーの TTL(10分): 解除イベントの取りこぼしで赤が永続しないように
  if [ -f "$marker" ]; then
    now_s
    age=$(( NOW_S - $(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || echo 0) ))
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
    jget transcript_path tpath
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
