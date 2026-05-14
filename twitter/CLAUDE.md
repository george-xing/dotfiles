# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single GNU Stow package (`twitter/`) inside `~/dotfiles`. Running `stow -t ~ -R twitter` symlinks every file back to its mirrored path under `$HOME`:

| In repo | Symlinked to |
|---|---|
| `bin/twitter-fire.sh` | `~/bin/twitter-fire.sh` |
| `bin/twitter-prefire.sh` | `~/bin/twitter-prefire.sh` |
| `bin/twitter-digest-fire.legacy.sh` | `~/bin/twitter-digest-fire.legacy.sh` (rollback only) |
| `bin/twitter-bot-chrome-setup.sh` | `~/bin/twitter-bot-chrome-setup.sh` |
| `Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist` | `~/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist` |
| `Library/LaunchAgents/com.pattybot.twitter-digest.plist` | `~/Library/LaunchAgents/com.pattybot.twitter-digest.plist` |
| `.claude/skills/twitter-digest/{SKILL,references/*}.md` | `~/.claude/skills/twitter-digest/...` |

Editing the symlinked path and editing the file inside this repo are the same operation — both write through to the repo. After altering the directory layout (adding/moving files), rerun `stow -t ~ -R twitter` to refresh links.

There is no build, lint, or test step. The codebase is bash + macOS launchd plists + Markdown skill files.

## Two-job architecture

Two launchd jobs cooperate. Reading just one in isolation will mislead you.

1. **`com.pattybot.twitter-bot-chrome`** — `KeepAlive: true`, runs `Google Chrome.app` with `--user-data-dir=~/Library/Application Support/twitter-bot-chrome --remote-debugging-port=9222`. **Always running.** This is the *only* Chrome that the digest ever talks to — its persistent profile holds the X session cookies. A second user's-daily Chrome typically also runs at the same time; the two coexist because Chromium's process singleton is keyed on `--user-data-dir`.
2. **`com.pattybot.twitter-digest`** — `StartCalendarInterval` at 08:00 and 22:00 local time, fires `bin/twitter-fire.sh twitter-digest`.

The fire wrapper is split into two pieces:

- **`bin/twitter-prefire.sh`** — OS plumbing only. Health-checks `http://127.0.0.1:9222/json/version` for up to 12s; disambiguates the bot Chrome from the user's daily Chrome via `lsof -iTCP:9222 -sTCP:LISTEN -t`; CDP-unminimizes bot Chrome windows; pre-warms System Events (eliminates AppleEvent timeout race on cold-launchd starts); activates the bot Chrome PID through System Events with a 30s timeout + diagnostic stderr capture; bounded-polls activation settlement. Emits `SAVED_FRONTMOST_PID=<pid>` as its final stdout line. Does NOT invoke claude or touch Telegram.
- **`bin/twitter-fire.sh <skill-name>`** — orchestrator. Acquires shared flock at `~/.claude/skills/.twitter-fire.lock` (exits 3 with `kind:busy` on conflict); calls prefire; runs `claude -p` against the named skill's SKILL.md; restores prior frontmost only if bot Chrome is still frontmost at restore time (so a manual app switch during the scrape isn't clobbered). One wrapper, two skills: both `twitter-digest` and `twitter-bookmarks` invoke it as `twitter-fire.sh <name>`.

The skill (`.claude/skills/twitter-digest/SKILL.md`) is the actual work: CDP-attach, scroll `x.com/home` ~3 minutes, theme tweets, summarize any X Articles, send to Telegram. The lookback cutoff is read from `state/last-success.json#runAt` (under `~/.claude/skills/twitter-digest/`, gitignored), capped at 24h, so the morning and evening windows hand off without overlap.

## Operational source of truth

Two reference files document operational behavior — read them before changing operational behavior:

- `.claude/skills/twitter-digest/SKILL.md` — full step-by-step skill workflow, failure-kind taxonomy, "what NOT to do" list. The operative invariants (no spawned browsers, no `close --all`, no fake foreground state, bounded action set during stall recovery) are spelled out here with their reasoning. **Don't re-decide them.**
- `.claude/skills/twitter-digest/references/runbook.md` — manual-fire commands, daemon control (`launchctl bootout|bootstrap`), TCC permission setup, log paths, re-auth procedure, failure-kind table.

If you find yourself debating an operational decision (clicking a stall modal, retrying on a curl error, calling `browser-use close`), check those files first — odds are the answer is already there with reasoning.

## Common commands

```bash
# Refresh stow symlinks (after adding/moving/renaming files in the repo)
cd ~/dotfiles && stow -t ~ -R twitter

# Smoke-test end-to-end without sending to Telegram (also: triggers the
# first-run TCC Automation prompt for System Events when run from Terminal)
~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest --dry-run
tail -50 ~/Library/Logs/twitter-fire.log

# Manual live fire (sends to Telegram)
~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest
~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks   # on-demand bookmark digest

# Trigger via launchd (same code path as the 08:00 / 22:00 fires)
launchctl kickstart -p gui/$(id -u)/com.pattybot.twitter-digest

# Daemon Chrome control (NEVER use Cmd-Q or `osascript ... quit` — those can
# hit the wrong Chrome instance, and KeepAlive would respawn anyway)
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist

# Edit themes / triage rules — applies to next fire, no reload
$EDITOR .claude/skills/twitter-digest/references/themes.md

# Edit fire schedule (StartCalendarInterval array of {Hour, Minute} dicts),
# then reload the digest job:
$EDITOR Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
```

Logs:
- `~/Library/Logs/twitter-fire.log` — main per-fire log for both skills (`===== fire <iso> skill=<name> =====` blocks).
- `~/Library/Logs/twitter-digest.launchd.{out,err}.log` — launchd-level errors for the digest cron job (PATH / permissions / plist).
- `~/Library/Logs/twitter-bot-chrome.{out,err}.log` — daemon Chrome stdout/stderr.

## Editing rules specific to this package

- **State directory is gitignored.** `**/state/` (matches `~/.claude/skills/twitter-digest/state/`) holds `last-success.json`, `last-failure.json`, `pending.json`, and historically cookies. Don't move it inside a tracked path — committing X cookies leaks an authenticated session.
- **Wrapper paths are absolute on purpose.** `bin/twitter-fire.sh` and `bin/twitter-prefire.sh` hardcode `/Users/pattybot/.local/bin/claude`, `/Users/pattybot/.local/bin/browser-use`, `/opt/homebrew/bin/node`. launchd's PATH is minimal; relying on `PATH` lookup will silently break under launchd. If you change a binary location, update the variables at the top of the wrappers. Same goes for `HOME` — both wrappers `export HOME=/Users/pattybot` before referencing `$HOME`, because launchd's default env doesn't set it.
- **macOS python3 vs Homebrew python3.** The pre-fire CDP un-minimize block in the wrapper pins `/usr/bin/python3` explicitly because it has `websocket-client` available via the system user-site (`~/Library/Python/3.9/site-packages`) while `/opt/homebrew/bin/python3` does not. Don't "simplify" that to bare `python3`.
- **Plist `ProcessType: Interactive`** on both jobs is required so the daemon Chrome is allowed to render and the wrapper is allowed to script System Events. Don't downgrade it to `Background`.
- **`KeepAlive: true` on the bot-chrome plist implies an initial speculative launch**, which is why `RunAtLoad` is intentionally absent — adding it would be redundant and could mask startup-ordering bugs.
- **Themes and triage rules live in `references/themes.md`** (not in SKILL.md). Adding/removing/renaming a theme there flows into the next fire with zero other changes — that separation is intentional, preserve it.
- **HTML, not Markdown, when delivering to Telegram.** Tweet text routinely contains `_*[`, which legacy Telegram Markdown breaks on. The escape pipeline (`& → &amp;`, `< → &lt;`, `> → &gt;`, applied last) is critical — don't reorder it.

## What "fixing it" usually does NOT mean

Operational failures here have a small, well-categorized set of root causes (`visibility`, `auth`, `dom`, `telegram`, `empty`, `stall` — see SKILL.md and runbook.md). Before writing code in response to a failure:

1. Read `~/.claude/skills/twitter-digest/state/last-failure.json` and the screenshot it points at.
2. Match `kind` against the runbook table — most cases need an operator action (re-foreground the window, re-sign-in, update a selector), not a code change.
3. **Avoid these "fixes" — they were considered and rejected, with reasoning in SKILL.md:**
   - Faking foreground via CDP `Page.setWebLifecycleState("active")` (mutates page lifecycle only; OS leaves the window backgrounded → page-state and OS-state disagree, which is itself a detectable mismatch). Note: `Page.bringToFront` is **not** rejected — it is the skill's first recovery step on `vis !== "visible"` because it routes through Chromium's `WebContentsImpl::Activate()` → `[NSWindow makeKeyAndOrderFront:]`, the same OS activation path a real user click takes; page and OS state stay in sync. See SKILL.md §"Failure semantics" for the full distinction.
   - Auto-clicking dismiss-y modal buttons by selector ("Got it", "Continue", "Skip", "Accept").
   - Programmatic X login.
   - Calling `browser-use close --all` anywhere in the flow.
   - Spawning a fresh `browser-use` Chrome instead of attaching via `--cdp-url`.
   - Retrying Telegram on curl-non-zero or local parse errors (only retry on `ok: false` with a well-formed JSON body — anything else risks duplicate sends).
