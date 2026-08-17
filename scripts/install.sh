#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEV=0
if [ "${1:-}" = "--dev" ]; then
  DEV=1
fi

swift build -c release --product AgentBar
BIN="$(swift build -c release --show-bin-path)/AgentBar"
if [ ! -x "$BIN" ]; then
  echo "missing binary: $BIN" >&2
  exit 1
fi

if [ "$DEV" -eq 1 ]; then
  APP="$ROOT/.build/AgentBar.app"
else
  mkdir -p "$HOME/Applications"
  APP="$HOME/Applications/AgentBar.app"
fi

# Replacing the .app while a copy is running leaves that process on the old
# inode; `open` then just activates it. Quit first so this launch is the new binary.
pkill -x AgentBar 2>/dev/null || true
sleep 0.2

VERSION="1.1"
GIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD="${GIT}-$(date +%H%M)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN" "$APP/Contents/MacOS/AgentBar"
chmod +x "$APP/Contents/MacOS/AgentBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>AgentBar</string>
  <key>CFBundleIdentifier</key>
  <string>dev.agentbar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AgentBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null

# Installed hook is the trusted execution point — never point live Groks at the working tree.
# Repo hook JSON uses $HOME; expand it so Grok/Codex get a real absolute path.
mkdir -p "$HOME/.grok/hooks" "$HOME/.grok/session-status"
chmod 700 "$HOME/.grok/hooks" "$HOME/.grok/session-status"
cp "$ROOT/hooks/grok-status.sh" "$HOME/.grok/hooks/grok-status.sh"
chmod 700 "$HOME/.grok/hooks/grok-status.sh"
sed "s|\$HOME|$HOME|g" "$ROOT/hooks/agent-bar.json" > "$HOME/.grok/hooks/agent-bar.json"

# Codex discovers ~/.codex/hooks.json only (not a hooks/*.json drop folder).
# Merge AgentBar handlers into any existing file so notify.sh stays put.
mkdir -p "$HOME/.codex/hooks" "$HOME/.codex/session-status"
chmod 700 "$HOME/.codex/hooks" "$HOME/.codex/session-status"
cp "$ROOT/hooks/codex-status.sh" "$HOME/.codex/hooks/codex-status.sh"
chmod 700 "$HOME/.codex/hooks/codex-status.sh"

# Claude publishes ~/.claude/sessions/<pid>.json but leaves out `status` for
# desktop-app sessions, so AgentBar needs a hook here too. Hooks live in
# settings.json alongside unrelated keys — merge, never overwrite.
mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/session-status"
chmod 700 "$HOME/.claude/session-status"
cp "$ROOT/hooks/claude-status.sh" "$HOME/.claude/hooks/claude-status.sh"
chmod 700 "$HOME/.claude/hooks/claude-status.sh"
if [ -f "$HOME/.claude/settings.json" ] && [ ! -f "$HOME/.claude/settings.json.agentbar-bak" ]; then
  cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.agentbar-bak"
fi

merge_hooks() {
python3 - "$1" "$2" "$HOME" <<'PY'
import json, sys

src_path, dest_path, home = sys.argv[1], sys.argv[2], sys.argv[3]


def expand_home(value):
    if isinstance(value, dict):
        return {k: expand_home(v) for k, v in value.items()}
    if isinstance(value, list):
        return [expand_home(v) for v in value]
    if isinstance(value, str):
        return value.replace("$HOME", home)
    return value


incoming = expand_home(json.load(open(src_path)))
try:
    existing = json.load(open(dest_path))
    if not isinstance(existing, dict):
        existing = {}
except (FileNotFoundError, json.JSONDecodeError):
    existing = {}
hooks = existing.setdefault("hooks", {})
if not isinstance(hooks, dict):
    hooks = {}
    existing["hooks"] = hooks
for event, groups in incoming.get("hooks", {}).items():
    dest_groups = hooks.setdefault(event, [])
    if not isinstance(dest_groups, list):
        dest_groups = []
        hooks[event] = dest_groups
    for group in groups:
        commands = {
            h.get("command")
            for g in dest_groups
            for h in (g.get("hooks") or [])
            if isinstance(h, dict)
        }
        new_cmds = [h.get("command") for h in (group.get("hooks") or []) if isinstance(h, dict)]
        if any(cmd in commands for cmd in new_cmds):
            continue
        dest_groups.append(group)
with open(dest_path, "w") as fh:
    json.dump(existing, fh, indent=2)
    fh.write("\n")
PY
}

merge_hooks "$ROOT/hooks/codex-agent-bar.json" "$HOME/.codex/hooks.json"
merge_hooks "$ROOT/hooks/claude-agent-bar.json" "$HOME/.claude/settings.json"

open "$APP"
echo "launched $APP  AgentBar ${VERSION} (${BUILD})"
