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
| `.claude/skills/twitter-{digest,bookmarks,search}/...` | `~/.claude/skills/twitter-{digest,bookmarks,search}/...` |
| `.hermes/skills/twitter-search/...` | `~/.hermes/skills/twitter-search/...` |

Editing the symlinked path and editing the file inside this repo are the same operation — both write through to the repo. After altering the directory layout (adding/moving files), rerun `stow -t ~ -R twitter` to refresh links.

The codebase is shell, Python, macOS launchd plists and Markdown skills. Run `/usr/bin/python3 -m unittest discover -s twitter/tests -v` from `~/dotfiles`, plus `bash -n` for edited shell scripts.

## Hermes scheduler + Chrome architecture

Hermes cron and one launchd job cooperate. Reading just one in isolation will mislead you.

1. **`com.pattybot.twitter-bot-chrome`** — `KeepAlive: true`, runs `Google Chrome.app` with `--user-data-dir=~/Library/Application Support/twitter-bot-chrome --remote-debugging-port=9222`. **Always running.** This is the *only* Chrome that the digest ever talks to — its persistent profile holds the X session cookies. A second user's-daily Chrome typically also runs at the same time; the two coexist because Chromium's process singleton is keyed on `--user-data-dir`.
2. **Hermes cron job `Twitter digest production schedule`** — cron expression `0 8,22 * * *` in America/New_York, runs `~/.hermes/scripts/twitter_digest_cron.sh`, which execs `bin/twitter-fire.sh twitter-digest`. The former `com.pattybot.twitter-digest` LaunchAgent is disabled and retained only as a migration backup.

The fire wrapper is split into two pieces:

- **`bin/twitter-browser.sh`** — shared client selecting the isolated, pinned Browser Use 0.12.6 installation, `twitter-production` session and dedicated CDP endpoint. Every production browser command uses it, including model-driven bookmarks/search commands. General Hermes requests retain their own managed browser/session.
- **`bin/twitter-prefire.sh`** — health-checks the dedicated daemon and invokes `bin/lib/twitter-window.py` for best-effort AppKit/CDP preparation. No System Events Apple Events or desktop clicks. A locked desktop is supported through exact-route/auth/content verification in each workflow.
- **`bin/lib/collect-digest.py`** — deterministic production implementation of digest steps 1–3. It owns attach/verify, setup refresh, the five-minute scroll/extract loop, persistent URL filtering, bounded stall recovery, categorized browser failures, and forensic screenshots. On verified hidden pages it requests a screenshot frame after scrolling so X's virtualized timeline renders. It writes candidates/metadata under `/tmp/twitter-digest-run`; screenshots are not fed back into the scheduled model.
- **`bin/twitter-fire.sh <skill-name>`** — orchestrator. Acquires the shared PID lock at `~/.claude/skills/.twitter-fire.lock` (exits 3 with `kind:busy` on conflict); calls prefire; clears a pre-existing X dialog with native Escape; runs the Hermes one-shot in its own process group behind a hard wall deadline (10 minutes for digest/search, 15 for bookmarks); and requires a fresh `last-success.json` with `telegramOk: true` before accepting exit 0. It restores prior frontmost only if bot Chrome is still frontmost at restore time. All three workflows go through this wrapper.
- **`bin/lib/run-with-timeout.py`** — process-group watchdog used by the wrapper. On timeout it sends TERM to the whole Hermes group, waits a bounded grace period, then KILLs survivors and returns 124. This is intentionally independent of provider stream-idle detection because periodic SSE keepalives are not workflow progress.
- **`bin/twitter-search-fire.sh <request-file>`** — safe bridge for arbitrary search text. It validates a UTF-8 query file under `~/.hermes/tmp/twitter-search-requests/`, exports only its path to the production skill, invokes `twitter-fire.sh twitter-search`, and deletes the ephemeral request file when the fire exits.

The production skills contain the actual browser and delivery work. `twitter-digest` scrolls `x.com/home`; `twitter-bookmarks` scrolls saved bookmarks; `twitter-search` opens X's Top results for an owner-supplied query. Hermes gateway skills are thin asynchronous dispatchers only—the production wrapper remains the single owner of locking, browser preparation, delivery, state, and recovery.

## Operational source of truth

Two reference files document operational behavior — read them before changing operational behavior:

- `.claude/skills/twitter-digest/SKILL.md` — full step-by-step digest workflow. The hot-path operational invariants are inline; explanatory detail lives under `.claude/skills/twitter-digest/references/`.
- `.claude/skills/twitter-digest/references/runbook.md` — manual-fire commands, daemon control (`launchctl bootout|bootstrap`), locked-desktop operation, log paths, re-auth procedure, failure-kind table.

If you find yourself debating an operational decision (clicking a stall modal, retrying on a curl error, calling `browser-use close`), check those files first — odds are the answer is already there with reasoning.

## Common commands

```bash
# Refresh stow symlinks (after adding/moving/renaming files in the repo)
cd ~/dotfiles && stow -t ~ -R twitter

# Smoke-test end-to-end without sending to Telegram (works while locked)
~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest --dry-run
tail -50 ~/Library/Logs/twitter-fire.log

# Manual live fire (sends to Telegram)
~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest
~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks   # on-demand bookmark digest

# Telegram commands are routed through the enabled `twitter-commands` Hermes skill:
# /twitter_digest
# /bookmarks
# /twitter_search <keyword, phrase, hashtag, or X search expression>

# Inspect the Hermes schedule and its runs
hermes cron list
hermes cron runs fbfcdfbabe54

# Daemon Chrome control (NEVER use Cmd-Q or `osascript ... quit` — those can
# hit the wrong Chrome instance, and KeepAlive would respawn anyway)
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist

# Edit themes / triage rules — applies to next fire, no reload
$EDITOR .claude/skills/twitter-digest/references/themes.md
```

Logs:
- `~/Library/Logs/twitter-fire.log` — main per-fire log for all production Twitter skills (`===== fire <iso> skill=<name> =====` blocks).
- `~/.hermes/cron/output/fbfcdfbabe54/` — Hermes cron execution records for the scheduled digest.
- `~/Library/Logs/twitter-bot-chrome.{out,err}.log` — daemon Chrome stdout/stderr.

## Editing rules specific to this package

- **State directory is gitignored.** `**/state/` (matches `~/.claude/skills/twitter-digest/state/`) holds `last-success.json`, `last-failure.json`, `pending.json`, and historically cookies. Don't move it inside a tracked path — committing X cookies leaks an authenticated session.
- **Wrapper paths are absolute on purpose.** `bin/twitter-fire.sh` and `bin/twitter-prefire.sh` hardcode `/Users/pattybot/.local/bin/hermes`, `/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh`, `/opt/homebrew/bin/node`, and the macOS helper paths. Scheduled environments have minimal PATHs; relying on lookup can fail silently. If a binary moves, update the constants at the top of the wrappers.
- **Python runtimes.** The collector uses `/usr/bin/python3` with websocket-client. The native window helper uses the isolated Twitter Browser Use Python with AppKit and websockets. Keep absolute runtimes for scheduled execution.
- **Plist `ProcessType: Interactive`** on the bot-Chrome job is required so Chrome may render in the Aqua session. The scheduled fire itself is owned by Hermes cron.
- **`KeepAlive: true` on the bot-chrome plist implies an initial speculative launch**, which is why `RunAtLoad` is intentionally absent — adding it would be redundant and could mask startup-ordering bugs.
- **Themes and triage rules live in `references/themes.md`** (not in SKILL.md). Adding/removing/renaming a theme there flows into the next fire with zero other changes — that separation is intentional, preserve it.
- **HTML, not Markdown, when delivering to Telegram.** Tweet text routinely contains `_*[`, which legacy Telegram Markdown breaks on. The escape pipeline (`& → &amp;`, `< → &lt;`, `> → &gt;`, applied last) is critical — don't reorder it.

## What "fixing it" usually does NOT mean

Operational failures here have a small, well-categorized set of root causes (`visibility`, `auth`, `dom`, `telegram`, `empty`, `stall` — see SKILL.md and runbook.md). Before writing code in response to a failure:

1. Read `~/.claude/skills/twitter-digest/state/last-failure.json` and the screenshot it points at.
2. Match `kind` against the runbook table — most cases need an operator action (re-foreground the window, re-sign-in, update a selector), not a code change.
3. **Avoid these "fixes" — this is the canonical rejected-fixes list with reasoning:**
   - Faking foreground via CDP `Page.setWebLifecycleState("active")` (mutates page lifecycle only; OS leaves the window backgrounded → page-state and OS-state disagree, which is itself a detectable mismatch). Note: `Page.bringToFront` is **not** rejected — it is the skill's first recovery step on `vis !== "visible"` because it routes through Chromium's `WebContentsImpl::Activate()` → `[NSWindow makeKeyAndOrderFront:]`, the same OS activation path a real user click takes; page and OS state stay in sync.
   - Auto-clicking dismiss-y modal buttons by selector ("Got it", "Continue", "Skip", "Accept").
   - Programmatic X login.
   - Calling `browser-use close --all` anywhere in the flow.
   - Spawning a fresh `browser-use` Chrome instead of attaching via `--cdp-url`.
   - Retrying Telegram on curl-non-zero or local parse errors (only retry on `ok: false` with a well-formed JSON body — anything else risks duplicate sends).
