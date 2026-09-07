#!/usr/bin/env bash
# 発光テスト用スクリプト
#
# 使い方:
#   ./led-test.sh coupon          # テストピース透過テスト(Enter で次の色へ)
#   ./led-test.sh states          # 実際の 5 状態を順に再生(Enter で次へ)
#   ./led-test.sh rgb R G B       # 任意色を直接点灯 (例: ./led-test.sh rgb 0 255 0)
#   ./led-test.sh ramp R G B      # 指定色を暗→明に 8 段階でランプ(Enter で次へ)
#   ./led-test.sh off             # 消灯(idle に戻す)
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
  local cmd="$1" path rest line started=0 sock port
  set -- $cmd
  path="$1"; shift
  case "$ATOM" in
    ble|ble:*)
      # BLE ブリッジへ 1 行送り、応答を受ける。ble:<path> で Unix ソケット、ble:<port> で
      # loopback TCP を指定できる。無指定なら Windows は TCP(47820)、他は既定のソケット
      sock="${ATOM#ble:}"; [ "$sock" = ble ] && sock=""; port=""
      case "$sock" in
        '') case "$(uname -s)" in
              MINGW*|MSYS*|CYGWIN*) port=47820 ;;
              *) sock="${TMPDIR:-/tmp}/claude-led-ble.sock" ;;
            esac ;;
        *[!0-9]*) ;;                     # 数字以外を含む → Unix ソケットのパス
        *) port="$sock"; sock="" ;;      # 全部数字 → TCP ポート
      esac
      if [ -n "$port" ]; then
        # Windows には Unix ソケットが無いので bash の /dev/tcp で loopback に繋ぐ
        ( printf '%s\n' "$cmd" >&3
          while IFS= read -r -t 3 line <&3; do printf '%s\n' "${line%$'\r'}"; done
        ) 3<>"/dev/tcp/127.0.0.1/$port" 2>/dev/null \
          || { echo "BLE ブリッジが起動していません(127.0.0.1:$port)。led.sh 経由か ble-bridge.py を起動してください" >&2; return 1; }
      elif [ ! -S "$sock" ]; then
        echo "BLE ブリッジが起動していません($sock)。led.sh 経由か ble-bridge.py を起動してください" >&2; return 1
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
          while IFS= read -r -t 3 line <&3; do
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

rgb() { atom_send "rgb r=$1 g=$2 b=$3" >/dev/null; }
led() { atom_send "led s=$1" >/dev/null; }

case "${1:-}" in
  coupon)
    # ケース素材の透過確認用。フル輝度の原色 → 実運用で厳しい色、の順
    echo "テストピースを LED にかざして、各色の見え方を確認してください"
    while :; do
      for entry in "紫(tool 相当・ピーク時):80:0:170" "赤(wait 相当・ピーク時):170:0:0" "緑(done 相当):0:255:0" "赤(フル):255:0:0" "青(フル):0:0:255" "白(フル):255:255:255" "青(idle 相当):0:0:170"; do
        IFS=: read -r name r g b <<< "$entry"
        rgb "$r" "$g" "$b"
        read -rp "→ $name を点灯中。Enter で次へ(Ctrl-C で終了) "
      done
      echo "--- 一巡しました。もう一周します ---"
    done
    ;;
  states)
    for s in idle tool wait done err; do
      led "$s"
      read -rp "→ $s を再生中。Enter で次へ "
    done
    led idle
    ;;
  rgb)
    rgb "${2:?r}" "${3:?g}" "${4:?b}"
    echo "rgb($2, $3, $4) 点灯中(led 状態を送るか 10 分で通常動作に戻ります)"
    ;;
  ramp)
    r="${2:?r}"; g="${3:?g}"; b="${4:?b}"
    for pct in 2 5 10 20 40 60 80 100; do
      rgb $((r * pct / 100)) $((g * pct / 100)) $((b * pct / 100))
      read -rp "→ ${pct}% を点灯中。Enter で次へ "
    done
    ;;
  off)
    led idle
    echo "idle に戻しました"
    ;;
  status)
    atom_send status
    ;;
  send)
    # 順序保証(ts)等のデバッグ用: ./led-test.sh send <state> <sid> <ts>
    atom_send "led s=${2:?state} sid=${3:-default} ts=${4:-0}"
    ;;
  *)
    grep '^#   ' "$0" | sed 's/^#   //'
    exit 1
    ;;
esac
