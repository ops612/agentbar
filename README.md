# AgentBar

A native macOS menu bar app for live [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Grok CLI](https://grok.x.ai), and [OpenAI Codex CLI](https://github.com/openai/codex) sessions.

Glance at the clock area and know which terminal tabs to check. No accounts, no network, nothing leaves the machine.

## What the icon means

The dot is the most urgent thing happening. Digits next to it never swap meaning.

| Icon | Meaning |
|---|---|
| Blue pulsing dot | A session is waiting on you (permission, question) |
| Green pulsing dot | A turn just finished |
| Red dot | A session is mid-turn |
| Solid green, no number | Every session is idle |
| Hollow grey | No sessions |

Digits: **blue** = waiting, **green** = just finished, **red** = still running. They can show up together.

Open the menu for a list grouped into **Needs you**, **Just finished**, **Running**, and **Idle**. Each row looks like:

```
Grok  agent-bar  ·  s005  ·  running
```

Click a row to jump to that session. Terminal and iTerm select the matching tab. VS Code, Cursor, and similar come to the front on that folder.

## Install

Needs macOS 14+, the Xcode Command Line Tools (`swift`), `jq`, and `python3`.

```bash
./scripts/install.sh
```

That builds a release binary, wraps it as `~/Applications/AgentBar.app`, ad-hoc signs it, installs the Grok and Codex status hooks, and launches the app.

The first launch may need a right-click → **Open** because of Gatekeeper (ad-hoc signature).

| Tool | What install does |
|---|---|
| **Grok** | Copies `~/.grok/hooks/grok-status.sh` and `agent-bar.json`. Restart existing Groks, or press `r` in `/hooks`. |
| **Codex** | Copies `~/.codex/hooks/codex-status.sh` and merges AgentBar handlers into `~/.codex/hooks.json` (existing hooks stay). In Codex, open `/hooks` and trust the new AgentBar commands. |
| **Claude Code** | Copies `~/.claude/hooks/claude-status.sh` and merges AgentBar handlers into `~/.claude/settings.json` (existing settings stay; a one-time `settings.json.agentbar-bak` is kept). Terminal CLIs need no hook — `~/.claude/sessions/<pid>.json` already carries `status` — but desktop-app sessions omit it. Restart existing sessions to pick the hook up. |

Launch at login is on by default. Toggle it from the menu.

Dev build — leaves the `.app` in `.build/`, does not copy to `~/Applications`:

```bash
./scripts/install.sh --dev
```

## Uninstall

1. Turn off **Launch at login** in the panel, then **Quit**.
2. Delete `~/Applications/AgentBar.app`.
3. Remove `~/.grok/hooks/grok-status.sh` and `~/.grok/hooks/agent-bar.json`.
4. Remove `~/.codex/hooks/codex-status.sh`. Edit `~/.codex/hooks.json` and delete the AgentBar command entries (paths ending in `codex-status.sh`).
5. Remove `~/.claude/hooks/claude-status.sh`. Edit `~/.claude/settings.json` and delete the AgentBar command entries (paths ending in `claude-status.sh`), or restore `~/.claude/settings.json.agentbar-bak`.

`~/.grok/session-status`, `~/.codex/session-status` and `~/.claude/session-status` are runtime files. Delete those folders too if you want them gone.

## The panel

Clicking the icon opens a panel rather than a plain menu:

- Sessions grouped by state, each row showing folder, tool, handle, and how long it has held that state
- Count chips in the header for the states that need attention
- A filter field, once there are more than three sessions
- Right-click a row to reveal its folder in Finder or copy its path
- An optional chime when a session starts waiting on you

## How it works

Menu-bar only. No Dock icon, no window, no network. It polls about once a second.

- **Claude** — live interactive sessions from `~/.claude/sessions/<pid>.json`, falling back to a sidecar under `~/.claude/session-status/` for sessions that publish no `status` of their own
- **Grok** — `~/.grok/active_sessions.json` plus a small sidecar written by the Grok hook
- **Codex** — sidecars written by the Codex hook under `~/.codex/session-status/`

Background jobs, subagents, Claude.app, and Codex.app are ignored.

Click-to-focus uses AppleScript for Terminal and iTerm. macOS may ask for Automation permission the first time you click a row.

## Contributing

No pull requests — the code is written by an agent, and PRs are closed automatically. Instead, [open a Prompt issue](../../issues/new?template=prompt.yml) with the prompt you'd give the agent. Good prompts get run against the codebase and shipped. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
