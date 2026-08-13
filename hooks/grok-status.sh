#!/bin/bash
# Write ~/.grok/session-status/<pid>.json from Grok hook events.
# Always exit 0 — never block a Stop gate. Write nothing to stdout
# (Stop stdout is a decision channel).
set -u
exec 1>/dev/null

# stdin may contain user_prompt / lastAssistantMessage — extract fields, drop the rest. Never log it.
input=$(cat)
event=$(printf '%s' "$input" | jq -r '.hookEventName // .hook_event_name // empty')
if [ -z "$event" ]; then
  event="${GROK_HOOK_EVENT:-}"
fi
# UserPromptSubmit -> user_prompt_submit; user_prompt_submit stays snake_case.
event=$(printf '%s' "$event" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]')

sid=$(printf '%s' "$input" | jq -r '.sessionId // .session_id // empty')
if [ -z "$sid" ]; then
  sid="${GROK_SESSION_ID:-}"
fi

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
reason=$(printf '%s' "$input" | jq -r '.reason // .stopReason // .stop_reason // empty')
ntype=$(printf '%s' "$input" | jq -r '.notificationType // .notification_type // .type // .notification.type // empty')

canon() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

LIVE_GROK="$(canon "$HOME/.grok")"
if [ "${AGENTBAR_TEST:-}" = "1" ] && [ -n "${AGENTBAR_GROK_ROSTER:-}" ] && [ -n "${AGENTBAR_GROK_STATUS_DIR:-}" ]; then
  ROSTER="$(canon "$AGENTBAR_GROK_ROSTER")"
  STATUS_DIR="$(canon "$AGENTBAR_GROK_STATUS_DIR")"
  tmp_root="$(canon "${TMPDIR:-/tmp}")"
  case "$ROSTER" in
    "$tmp_root"/*) ;;
    *) exit 0 ;;
  esac
  case "$STATUS_DIR" in
    "$tmp_root"/*) ;;
    *) exit 0 ;;
  esac
else
  ROSTER="$(canon "$HOME/.grok/active_sessions.json")"
  STATUS_DIR="$(canon "$HOME/.grok/session-status")"
  case "$ROSTER" in
    "$LIVE_GROK"/*) ;;
    *) exit 0 ;;
  esac
  case "$STATUS_DIR" in
    "$LIVE_GROK"/*) ;;
    *) exit 0 ;;
  esac
fi

mkdir -p "$STATUS_DIR"
chmod 700 "$STATUS_DIR" 2>/dev/null || true

pid=""
if [ -n "$sid" ] && [ -f "$ROSTER" ]; then
  pid=$(jq -r --arg sid "$sid" '.[] | select(.session_id == $sid) | .pid' "$ROSTER" 2>/dev/null | head -1)
  if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
    cwd=$(jq -r --arg sid "$sid" '.[] | select(.session_id == $sid) | .cwd' "$ROSTER" 2>/dev/null | head -1)
  fi
fi

# Roster pid must be a positive integer so $STATUS_DIR/${pid}.json cannot escape the dir.
case "${pid:-}" in
  ''|null) pid="" ;;
  *[!0-9]*) pid="" ;;
  0*) pid="" ;;
esac

sidecar_path() {
  [ -n "$1" ] || return 1
  printf '%s/%s.json' "$STATUS_DIR" "$1"
}

delete_sidecar() {
  if [ -n "${pid:-}" ]; then
    f="$(sidecar_path "$pid")" || exit 0
    if [ -f "$f" ]; then
      fsid=$(jq -r '.session_id // empty' "$f" 2>/dev/null)
      # Spec: delete the sidecar for this session_id. A sibling sharing the pid keeps its file.
      if [ -z "$fsid" ] || [ "$fsid" = "$sid" ]; then
        rm -f "$f"
      fi
    fi
  fi
  if [ -n "$sid" ]; then
    for f in "$STATUS_DIR"/*.json; do
      [ -f "$f" ] || continue
      base=$(basename "$f" .json)
      case "$base" in
        *[!0-9]*|'') continue ;;
      esac
      fsid=$(jq -r '.session_id // empty' "$f" 2>/dev/null)
      if [ "$fsid" = "$sid" ]; then
        rm -f "$f"
      fi
    done
  fi
}

if [ "$event" = "session_end" ]; then
  delete_sidecar
  exit 0
fi

if [ -z "${pid:-}" ]; then
  exit 0
fi

status=""
case "$event" in
  session_start) status="idle" ;;
  user_prompt_submit) status="running" ;;
  stop)
    # Session-end observe fires are channel_closed / shutdown. Any other
    # Stop (including a missing reason) means the turn is over. Interrupted
    # turns skip Stop entirely — the scanner reads events.jsonl for those.
    case "$reason" in
      channel_closed|shutdown) ;;
      *) status="idle" ;;
    esac
    ;;
  notification)
    case "$ntype" in
      permission_prompt) status="waiting" ;;
      idle_prompt|task_complete) status="idle" ;;
    esac
    ;;
esac

if [ -z "$status" ]; then
  exit 0
fi

if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
  cwd="$HOME"
fi

dest="$(sidecar_path "$pid")" || exit 0
case "$dest" in
  "$STATUS_DIR"/*.json) ;;
  *) exit 0 ;;
esac

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
tmp=$(mktemp "$STATUS_DIR/.tmp.XXXXXX")
if ! jq -n \
  --argjson pid "$pid" \
  --arg sid "$sid" \
  --arg cwd "$cwd" \
  --arg status "$status" \
  --arg ts "$ts" \
  '{pid:$pid,session_id:$sid,cwd:$cwd,status:$status,updated_at:$ts}' \
  > "$tmp"
then
  rm -f "$tmp"
  exit 0
fi
mv -f "$tmp" "$dest"

exit 0
