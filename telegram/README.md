# Standalone Telegram receiver

This Stow package runs `@cp_claudebot` without Claude Code Channels or Remote
Control. It polls the Telegram Bot API, enforces the existing channel
allowlist, invokes a fresh non-interactive `claude -p` process for each
message, and sends the result back through Telegram.

Runtime credentials and state intentionally remain outside this repository:

- `~/.claude/channels/telegram/.env` — Telegram bot token (`0600`)
- `~/.claude/channels/telegram/access.json` — sender/group policy (`0600`)
- `~/.claude/secrets/setup-token` — Claude setup token (`0600`)
- `~/.claude/channels/telegram/receiver-state/` — offset and heartbeat

Install or refresh the links with:

```sh
stow -t "$HOME" telegram
```

The LaunchAgent label remains `com.pattybot.claude-telegram`, and the existing
`com.pattybot.claude-telegram-healthcheck` job monitors its persisted
heartbeat.
