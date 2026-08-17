#!/bin/bash
# Write ~/.claude/session-status/<pid>.json from Claude Code hook events.
# Claude publishes ~/.claude/sessions/<pid>.json but no status field for
# desktop-app sessions, so the status comes from here instead.
# Always exit 0 — never block a Stop gate. Write nothing to stdout
# (UserPromptSubmit stdout is injected into the prompt; Stop stdout is a
# decision channel).
set -u
exec 1>/dev/null

input=$(cat)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // .hookEventName // empty')
event=$(printf '%s' "$event" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]')

sid=$(printf '%s' "$input" | jq -r '.session_id // .sessionId // empty')
[ -n "$sid" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

SESSIONS_DIR="$HOME/.claude/sessions"
STATUS_DIR="$HOME/.claude/session-status"

mkdir -p "$STATUS_DIR"
chmod 700 "$STATUS_DIR" 2>/dev/null || true

# Claude keys session files by pid; find the one holding this session_id.
pid=""
for f in "$SESSIONS_DIR"/*.json; do
  [ -f "$f" ] || continue
  fsid=$(jq -r '.sessionId // .session_id // empty' "$f" 2>/dev/null)
  if [ "$fsid" = "$sid" ]; then
    pid=$(basename "$f" .json)
    if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
      cwd=$(jq -r '.cwd // empty' "$f" 2>/dev/null)
    fi
    break
  fi
done

# pid must be a positive integer so $STATUS_DIR/${pid}.json cannot escape the dir.
case "${pid:-}" in
  ''|null) exit 0 ;;
  *[!0-9]*) exit 0 ;;
  0*) exit 0 ;;
esac

delete_sidecar() {
  f="$STATUS_DIR/${pid}.json"
  if [ -f "$f" ]; then
    fsid=$(jq -r '.session_id // empty' "$f" 2>/dev/null)
    if [ -z "$fsid" ] || [ "$fsid" = "$sid" ]; then
      rm -f "$f"
    fi
  fi
}

if [ "$event" = "session_end" ]; then
  delete_sidecar
  exit 0
fi

status=""
case "$event" in
  session_start) status="idle" ;;
  user_prompt_submit) status="busy" ;;
  # Notification fires for permission prompts and for a turn left idle.
  notification) status="waiting" ;;
  stop) status="idle" ;;
esac
[ -n "$status" ] || exit 0

if [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
  cwd="$HOME"
fi

dest="$STATUS_DIR/${pid}.json"
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
