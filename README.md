# dotfiles

Personal config for my Mac mini. Each top-level directory is a **package** — a tree of files whose layout mirrors where they belong under `$HOME`. Running `./install.sh <package>` creates symlinks from `$HOME/...` back into the repo, so edits land in `$HOME` but are version-controlled here.

## Usage

```bash
./install.sh twitter-digest    # install a single package
./install.sh --all             # install every package
./uninstall.sh twitter-digest  # remove symlinks
```

The install script uses plain `ln -sfn` and will never overwrite an existing real file — it errors out and tells you which path is in conflict. To force-replace an existing file, move it aside first.

Layout is stow-compatible: if you install GNU `stow` you can also run `stow -t ~ twitter-digest` and get the same symlinks.

## Packages

- **`twitter-digest/`** — Morning (08:00 ET) and evening (22:00 ET) X/Twitter digest delivered to Telegram via a Claude Code skill + `browser-use` CLI + launchd. Requires: `browser-use` CLI + the Claude Code `browser-use` skill at `~/.claude/skills/browser-use/`, logged-in X cookies at `~/.claude/skills/twitter-digest/state/x-cookies.json` (not committed — export via `browser-use cookies export` after a manual `--headed` login), and a Telegram bot token at `~/.claude/channels/telegram/.env`. Operational runbook lives inside the package at `.claude/skills/twitter-digest/references/runbook.md`.

## Not in the repo

- `**/state/` — runtime state (cookies, last-success markers). Committing cookies would leak authenticated X sessions to anyone who reads the repo. `.gitignore` enforces this.
- `~/.claude/channels/telegram/.env` — bot token. Managed by the Telegram plugin.
- Log files under `~/Library/Logs/`.

## Adding a new package

1. `mkdir -p dotfiles/<pkg>/<same path structure as $HOME>`
2. Move (don't copy) the files you want tracked into that tree
3. `./install.sh <pkg>` — symlinks back to `$HOME`
4. `git add dotfiles/<pkg> && git commit`
