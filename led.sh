#!/usr/bin/env bash
# Claude Code hook → M5Atom Lite ステータス送信
# - stdin の hook JSON から session_id を抽出してセッション別に送る
# - ダイアログ(権限確認 / AskUserQuestion)表示中はマーカーを置き、
#   サブエージェント等の tool イベントによる赤の上書きを防ぐ
# - 手動実行(tty)時は stdin を読まず sid=default で送る
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
    age=$(( $(date +%s) - $(stat -f %m "$marker" 2>/dev/null || echo 0) ))
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
  elif [ "$state" = "tool" ] && [ -f "$marker" ]; then
    mtuid=""; mtool=""
    read -r mtuid mtool < "$marker"
    case "$event" in
      UserPromptSubmit)
        rm -f "$marker"    # 新しいプロンプト = ダイアログは解決済み
        ;;
      PostToolUse|PostToolUseFailure)
        if { [ "$mtuid" != "-" ] && [ "$tuid" = "$mtuid" ]; } \
           || { [ "$mtuid" = "-" ] && [ "$tool" = "$mtool" ]; }; then
          rm -f "$marker"  # 待っていた呼び出しの完了 = ダイアログ応答済み
        else
          state="wait"     # 別の呼び出し(サブエージェント等)の完了: 赤を維持
        fi
        ;;
      *)
        state="wait"       # ダイアログ待ち中の PreToolUse 等も赤を維持
        ;;
    esac
  elif [ "$state" != "tool" ]; then
    rm -f "$marker" "$pending"   # done / err / idle でダイアログ待ちは終了
  fi
fi
# 送信時刻(ms)。async hook + リトライによる着弾順の逆転をデバイス側で排除するために使う
ts=$(perl -MTime::HiRes=time -e 'printf("%.0f", time()*1000)' 2>/dev/null || echo 0)
# ↓ 自分の Atom Lite の固定 IP に書き換える
exec curl -s -m 1 --retry 2 --retry-all-errors "http://192.168.1.50/led?s=$state&sid=${sid:-default}&ts=$ts" >/dev/null 2>&1
