#!/bin/bash
# Write ~/.codex/session-status/<pid>.json from Codex hook events.
# Always exit 0. Write nothing to stdout — PreToolUse/Stop stdout is a
# decision channel.
set -u
exec 1>/dev/null

# stdin may contain prompt / tool_input — extract fields, drop the rest.
input=$(cat)
event=$(printf '%s' "$input" | jq -r '.hookEventName // .hook_event_name // empty')
event=$(printf '%s' "$event" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]')

sid=$(printf '%s' "$input" | jq -r '.sessionId // .session_id // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
reason=$(printf '%s' "$input" | jq -r '.reason // .stopReason // .stop_reason // empty')
agent_id=$(printf '%s' "$input" | jq -r '.agentId // .agent_id // empty')

# Subagent hooks reuse the parent session_id. Ignore them so a child stop
# cannot flip the interactive tab to idle mid-turn.
if [ -n "$agent_id" ]; then
  exit 0
fi
case "$event" in
  subagent_start|subagent_stop) exit 0 ;;
esac

canon() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

LIVE_CODEX="$(canon "$HOME/.codex")"
if [ "${AGENTBAR_TEST:-}" = "1" ] && [ -n "${AGENTBAR_CODEX_STATUS_DIR:-}" ]; then
  STATUS_DIR="$(canon "$AGENTBAR_CODEX_STATUS_DIR")"
  tmp_root="$(canon "${TMPDIR:-/tmp}")"
  case "$STATUS_DIR" in
    "$tmp_root"/*) ;;
    *) exit 0 ;;
  esac
else
  STATUS_DIR="$(canon "$HOME/.codex/session-status")"
  case "$STATUS_DIR" in
    "$LIVE_CODEX"/*) ;;
    *) exit 0 ;;
  esac
fi

mkdir -p "$STATUS_DIR"
chmod 700 "$STATUS_DIR" 2>/dev/null || true

pid=""
if [ "${AGENTBAR_TEST:-}" = "1" ] && [ -n "${AGENTBAR_CODEX_PID:-}" ]; then
  pid="${AGENTBAR_CODEX_PID}"
else
  pid="${PPID:-}"
  if [ -n "$pid" ]; then
    pcomm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    base=$(printf '%s' "$pcomm" | sed 's|.*/||')
    case "$base" in
      bash|sh|zsh|dash|fish)
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        ;;
    esac
  fi
fi

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
  user_prompt_submit|pre_tool_use) status="running" ;;
  permission_request) status="waiting" ;;
  stop) status="idle" ;;
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
