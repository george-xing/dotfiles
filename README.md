# dotfiles

Personal config for my Mac mini. Each top-level directory is a **package** — a tree of files whose layout mirrors where they belong under `$HOME`. GNU `stow` (`brew install stow`) creates symlinks from `$HOME/...` back into the repo, so edits land in `$HOME` but are version-controlled here.

## Usage

```bash
cd ~/dotfiles
stow -t ~ twitter-digest       # install
stow -t ~ -D twitter-digest    # uninstall
stow -t ~ -R twitter-digest    # reinstall (idempotent refresh after layout changes)
```

`stow` refuses to clobber pre-existing real files in `$HOME` — it'll list them as conflicts and abort. Move them aside first and rerun.

## Packages

- **`twitter-digest/`** — Morning (08:00 ET) and evening (22:00 ET) X/Twitter digest delivered to Telegram via a Claude Code skill + `browser-use` CLI + launchd. Requires: `browser-use` CLI + the Claude Code `browser-use` skill at `~/.claude/skills/browser-use/`, logged-in X cookies at `~/.claude/skills/twitter-digest/state/x-cookies.json` (not committed — export via `browser-use cookies export` after a manual `--headed` login), and a Telegram bot token at `~/.claude/channels/telegram/.env`. Operational runbook lives inside the package at `.claude/skills/twitter-digest/references/runbook.md`.
- **`whatsapp-digest/`** — Standalone WhatsApp digest MCP spike. Provides a read-only `whatsapp-digest-mcp` stdio server backed by `whatsapp-web.js`, plus a Claude Code skill shell for daily Telegram digests. Requires QR login via WhatsApp Linked Devices and dependency install under `~/.local/share/whatsapp-digest`. Operational runbook lives at `.claude/skills/whatsapp-digest/references/runbook.md`.

## Not in the repo

- `**/state/` — runtime state (cookies, last-success markers). Committing cookies would leak authenticated X sessions to anyone who reads the repo. `.gitignore` enforces this.
- `~/.claude/channels/telegram/.env` — Telegram bot token. Managed by the Telegram plugin.
- Log files under `~/Library/Logs/`.

## Adding a new package

1. `mkdir -p dotfiles/<pkg>/<same path structure as $HOME>`
2. Move (don't copy) the files you want tracked into that tree
3. `stow -t ~ <pkg>` — symlinks back to `$HOME`
4. `git add <pkg> && git commit`
