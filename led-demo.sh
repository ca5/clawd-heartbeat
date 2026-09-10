#!/usr/bin/env bash
# アニメーション自動再生(撮影・動作確認用)
#
# 対話操作なしで各状態を一定時間ずつ再生する。録画を開始してから放置できる。
#
#   ./led-demo.sh                 # 全状態を順に再生(既定)
#   ./led-demo.sh clip            # 動画/GIF 用の 16 秒シーケンス(撮影はこれが楽)
#   ./led-demo.sh story           # 実運用の流れを再現(作業→承認待ち→承認後→完了)
#   ./led-demo.sh wait-full       # wait の点滅→常灯の切替(30秒)まで見せる
#   ./led-demo.sh states --loop   # 中断するまで繰り返す
#   ./led-demo.sh states --lead 10  # 開始前に 10 秒の準備時間を入れる(既定 5 秒)
#   ./led-demo.sh states --solo   # 他セッションを idle にして確実に再生(撮影向け)
#
# 注意: 他の Claude Code セッションが作業中だと優先度集約で上書きされる。
# --solo を付けるか、通常のターミナルから実行すること(実セッションの表示は
# 次の hook イベントで自然に復帰する)。
set -eu

# 宛先の決定: 環境変数 ATOM > .atom-ip ファイル(gitignore 済み) > プレースホルダ
# 値が ble(または ble:<socket>)なら BLE、/dev/ で始まれば USB シリアル、それ以外は HTTP の URL
here=$(cd "$(dirname "$0")" && pwd)
if [ -z "${ATOM:-}" ] && [ -f "$here/.atom-ip" ]; then
  ATOM=$(cat "$here/.atom-ip")
fi
ATOM="${ATOM:-http://192.168.1.50}"

# コマンド送信の抽象化。引数はシリアル形式で渡し、HTTP のときは URL に変換する:
#   atom_send "led s=idle sid=demo"  →  シリアル: そのまま 1 行 / HTTP: /led?s=idle&sid=demo
#   atom_send status                 →  シリアル: 応答を空行まで読む / HTTP: GET /
# シリアルは open/close で DTR/RTS が動くとボードがリセットされるため -hupcl を毎回セットする
# (led.sh と同じ対策)。応答は "state=" 行が来るまでのノイズ(古い ok 等)を読み飛ばす
atom_send() {
  local cmd="$1" path rest line started=0 sock port kind defport defsock n=0
  set -- $cmd
  path="$1"; shift
  case "$ATOM" in
    ble|ble:*|hid|hid:*)
      # 常駐ブリッジへ 1 行送り、応答を受ける。BLE(ble-bridge.py)と HOGP(hid-bridge.py)は
      # ソケットのプロトコルが同一で、既定のソケット/ポートだけが違う。
      # <kind>:<path> で Unix ソケット、<kind>:<port> で loopback TCP を明示できる
      case "$ATOM" in
        hid*) kind=hid; defport=47821; defsock="${TMPDIR:-/tmp}/claude-led-hid.sock" ;;
        *)    kind=ble; defport=47820; defsock="${TMPDIR:-/tmp}/claude-led-ble.sock" ;;
      esac
      sock="${ATOM#${kind}:}"; [ "$sock" = "$kind" ] && sock=""; port=""
      case "$sock" in
        '') case "$(uname -s)" in
              MINGW*|MSYS*|CYGWIN*) port="$defport" ;;
              *) sock="$defsock" ;;
            esac ;;
        *[!0-9]*) ;;                     # 数字以外を含む → Unix ソケットのパス
        *) port="$sock"; sock="" ;;      # 全部数字 → TCP ポート
      esac
      if [ -n "$port" ]; then
        # Windows には Unix ソケットが無いので bash の /dev/tcp で loopback に繋ぐ
        ( printf '%s\n' "$cmd" >&3
          while IFS= read -r -t 3 line <&3; do printf '%s\n' "${line%$'\r'}"; done
        ) 2>/dev/null 3<>"/dev/tcp/127.0.0.1/$port" \
          || { echo "$kind ブリッジが起動していません(127.0.0.1:$port)。led.sh 経由か ${kind}-bridge.py を起動してください" >&2; return 1; }
      elif [ ! -S "$sock" ]; then
        echo "$kind ブリッジが起動していません($sock)。led.sh 経由か ${kind}-bridge.py を起動してください" >&2; return 1
      elif command -v nc >/dev/null 2>&1; then
        printf '%s\n' "$cmd" | nc -U -w 3 "$sock"
      else
        python3 - "$sock" "$cmd" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(3)
s.connect(sys.argv[1]); s.sendall((sys.argv[2] + "\n").encode())
import sys as _s
while True:
    d = s.recv(512)
    if not d: break
    _s.stdout.write(d.decode(errors="replace"))
s.close()
PY
      fi
      ;;
    /dev/*)
      [ -c "$ATOM" ] || { echo "シリアルポートが見つかりません: $ATOM" >&2; return 1; }
      {
        # MSYS の COM ポートでは raw/-echo/速度をまとめて設定できず stty が非 0 を返す(適用できる分は
        # 適用される。-hupcl 単体は成功し、実測でもボードはリセットされない)。set -e 下で落ちないよう許容する
        stty raw -echo -hupcl clocal 115200 <&3 2>/dev/null || true
        printf '%s\n' "$cmd" >&3
        if [ "$path" = status ]; then
          # 行数に上限を置く。パニックでブートループしているデバイスは起動ログを延々
          # 流し続けるので、上限が無いとここで固まってポートを掴んだままになる(実測)
          while [ "$n" -lt 200 ] && IFS= read -r -t 3 line <&3; do
            n=$((n + 1))
            line=${line%$'\r'}
            case "$line" in state=*) started=1 ;; esac
            [ "$started" -eq 1 ] || continue
            [ -n "$line" ] || break
            printf '%s\n' "$line"
          done
        else
          { IFS= read -r -t 3 line <&3 && printf '%s\n' "${line%$'\r'}"; } || true   # 応答なしでも失敗にしない(set -e 対策)。Bluetooth は接続に約 1.5 秒かかる
        fi
      } 3<>"$ATOM" 2>/dev/null
      ;;
    *)
      rest=$(IFS='&'; printf '%s' "$*")
      [ "$path" = status ] && path=""
      curl -s -m 2 "$ATOM/$path${rest:+?$rest}"
      ;;
  esac
}

# シリアル(特に Bluetooth)は open のたびに接続し直すので、再生中はポートを開いたまま接続を維持する。
# fd 9 を掴んでおくだけ。atom_send 内の fd 3 とは独立
# ただし Windows(MSYS)の COM ポートは排他オープンなので、掴んだままだと atom_send 側の
# open が Permission denied になる。USB シリアルは open ごとの再接続待ちも無いので掴まない
keep_open=1
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) keep_open=0 ;; esac
case "$ATOM" in
  /dev/*)
    if [ -c "$ATOM" ] && [ "$keep_open" -eq 1 ]; then
      exec 9<>"$ATOM"
      stty -hupcl <&9 2>/dev/null || true
      sleep 2   # Bluetooth の接続確立(約 1.5 秒)を待つ
    fi
    ;;
esac

mode="states"
loop=0
lead=5
solo=0
while [ $# -gt 0 ]; do
  case "$1" in
    states|story|wait-full|clip) mode="$1"; shift ;;
    --loop) loop=1; shift ;;
    --solo) solo=1; shift ;;
    --lead) lead="${2:?seconds}"; shift 2 ;;
    -h|--help) grep '^#   ' "$0" | sed 's/^#   //'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

send() { atom_send "led s=$1 sid=demo" >/dev/null; }

# 他セッションが動いていると優先度集約で上書きされるので警告する
check_conflict() {
  local others
  others=$(atom_send status 2>/dev/null | awk '/^  / && $2 != "idle" && $1 != "demo" {print "  " $0}') || return 0
  if [ -n "$others" ]; then
    echo "⚠ 他のセッションが待機中以外の状態です。再生が上書きされる可能性があります:"
    echo "$others"
    echo "  (Claude Code を終了するか、そのターンが終わるのを待つと確実です)"
    echo
  fi
}

# 他セッションを idle に落として再生を独占する(--solo)。
# 実セッションの表示は次の hook イベントで自然に復帰するので副作用は一時的。
silence_others() {
  local ids id
  ids=$(atom_send status 2>/dev/null | awk '/^  / && $1 != "demo" {print $1}') || return 0
  for id in $ids; do
    atom_send "led s=idle sid=$id" >/dev/null 2>&1 || true
  done
  [ -n "$ids" ] && echo "他セッションを idle にしました: $(echo "$ids" | tr '\n' ' ')"
  return 0
}

# hold <state> <seconds> <説明>
hold() {
  local state="$1" secs="$2" label="$3" i
  send "$state"
  for i in $(seq "$secs" -1 1); do
    printf '\r  %-6s %-34s %2ds ' "$state" "$label" "$i"
    sleep 1
  done
  printf '\r  %-6s %-34s done\n' "$state" "$label"
}

play_states() {
  hold idle 5 "青の常灯(待機)"
  hold tool 9 "白の呼吸(作業中)"
  hold wait 6 "赤の点滅(承認待ち)"
  hold done 7 "緑の点滅(完了)→ 待機へ"
  hold err  5 "赤の高速点滅(エラー)"
  hold idle 4 "青の常灯(待機)"
}

play_story() {
  hold idle 4 "待機中"
  hold tool 8 "プロンプト送信 → 作業中"
  hold wait 8 "権限確認ダイアログ(呼ばれている)"
  hold tool 6 "承認 → コマンド実行中"
  hold done 7 "ターン完了"
  hold idle 4 "待機に戻る"
}

# 動画・GIF 用に詰めた 16 秒。SNS / README で最後まで見てもらえる長さに収めている
play_clip() {
  hold idle 2 "待機(青)"
  hold tool 4 "作業中(呼吸)"
  hold wait 5 "承認待ち(赤の点滅)← 主役"
  hold tool 2 "承認後、作業再開"
  hold done 3 "完了(緑)"
}

play_wait_full() {
  hold idle 3 "待機中"
  hold wait 40 "点滅 30 秒 → 常灯に切り替わる"
  hold idle 4 "待機に戻る"
}

cleanup() {
  printf '\r%-60s\r' ' '
  send idle 2>/dev/null || true
  echo "再生を終了しました(demo セッションは 10 分で自動失効します)"
}
trap cleanup EXIT INT TERM

if [ "$solo" -eq 1 ]; then
  silence_others
else
  check_conflict
fi
echo "再生モード: $mode  宛先: $ATOM"
if [ "$lead" -gt 0 ]; then
  for i in $(seq "$lead" -1 1); do
    printf '\r  録画の準備をしてください… %2ds ' "$i"
    sleep 1
  done
  printf '\r%-40s\r' ' '
fi

while :; do
  case "$mode" in
    states)    play_states ;;
    clip)      play_clip ;;
    story)     play_story ;;
    wait-full) play_wait_full ;;
  esac
  [ "$loop" -eq 1 ] || break
  echo "--- 繰り返し(Ctrl-C で終了)---"
done
