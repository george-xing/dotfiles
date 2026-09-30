# twitter-digest runbook

## Architecture (read this first)

Hermes cron and one launchctl job work together:

- `com.pattybot.twitter-bot-chrome` — long-running daemon Chrome with persistent profile at `~/Library/Application Support/twitter-bot-chrome/` and CDP debug port 9222. `KeepAlive: true`. **Always running.**
- Hermes cron job `Twitter digest production schedule` — the twice-daily timer (08:00 and 22:00 ET) that runs `~/.hermes/scripts/twitter_digest_cron.sh`, which execs the wrapper. The legacy digest LaunchAgent is not active.

The shared production path supports both scheduled and Telegram-triggered runs:

- `twitter-browser.sh` uses an isolated Browser Use 0.12.6 runtime and the explicit `twitter-production` session. Hermes's managed CLI3 and the global default session cannot displace it. All production helpers and skills use this client.
- `twitter-prefire.sh` checks the dedicated Chrome and calls `twitter-window.py` for best-effort AppKit/CDP activation. It does not use System Events or desktop clicks. While the Mac is locked, it leaves the lock screen alone.
- Hidden pages require exact route, authenticated profile navigation, non-zero viewport, no login wall, primary-column presence, and real post extraction. A failed proof remains a hard failure. No visibility spoofing is used.
- Prior foreground restoration uses AppKit only when the bot browser is still frontmost; it never restores over the lock screen or another app chosen during the run.
- **Hard process-group deadline** — 10 minutes for digest/search and 15 minutes for bookmarks. A timeout terminates Hermes and its descendants, writes `kind: timeout`, returns 124, and releases the shared lock.
- **Delivery proof** — Hermes exit 0 is not sufficient because one-shot mode also exits 0 for apology/error text. Live runs only return 0 when `last-success.json#runAt` is fresh and `telegramOk` is true. A nominal Hermes success without that proof writes `kind: agent` and returns 70.

Feed collection itself is deterministic: `bin/lib/collect-digest.py` owns the
five-minute scroll/extract/recovery loop (target: 150 unique eligible tweets) and returns JSON candidates to Hermes
for editorial triage. Stall screenshots are retained only for operator
forensics and are never attached to the scheduled model context. This prevents
a routine feed plateau from becoming a hanging multimodal provider call.

**Locked desktop:** supported for authenticated read-only collection. No System Events Automation grant or manual unlock is required. If the content proof fails, inspect the categorized error; do not try to click or unlock the desktop.

**Thin digests after a locked run:** compare `collection.json` and collector
output in the Hermes session record. Repeated `new=0` from the first scroll can
mean the initial DOM is readable but X's virtualized timeline is not rendering.
The collector requests a screenshot frame after each hidden-page scroll and
records `backgroundFrames`; it overwrites one `background-frame.png` in the run
directory without model/vision calls or visibility spoofing. Also check for
Snooze Topics: clicking an already-selected For You tab opens that dialog.
The collector skips that click and verifies native Escape clears any blocking
dialog. A persistent obstruction is a stall failure, not a clean plateau.

**Pinned browser runtime:** maintained separately from Hermes and global tools. To reinstall the compatible client:

```bash
UV_TOOL_DIR=/Users/pattybot/.local/share/twitter-browser-tools UV_TOOL_BIN_DIR=/Users/pattybot/.local/lib/twitter-browser/bin UV_NO_CONFIG=1 /opt/homebrew/bin/uv tool install --python 3.11 'browser-use==0.12.6'
```

General Hermes browsing uses its own managed browser client; do not change that client to accommodate this legacy production workflow.

## Manual fire (any time)

Fire the wrapper directly (the scheduled Hermes script uses the same code path):
```bash
~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest            # live — sends to Telegram
~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest --dry-run  # composes digest, prints to log only
```

Or fire it on demand from the owner Telegram chat:
```bash
/twitter_digest
/bookmarks
/twitter_search QUERY
```

The wrapper does a 12s health check on `http://127.0.0.1:9222/json/version` before invoking Hermes one-shot. If the daemon Chrome isn't responding, the wrapper exits immediately rather than burning an agent turn.

## Logs

- `~/Library/Logs/twitter-fire.log` — main per-fire log for all production Twitter skills. Each fire appends a `===== fire <iso> skill=<name> =====` / `----- exit <N> -----` block.
- `~/.hermes/cron/output/fbfcdfbabe54/` — scheduled Hermes execution records.
- `~/Library/Logs/twitter-bot-chrome.{out,err}.log` — the daemon Chrome's stdout/stderr. Useful when debugging why `127.0.0.1:9222` isn't responding.

## Daemon control (bot Chrome)

```bash
# Pause the daemon (Chrome will quit, won't auto-respawn)
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist

# Resume
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist

# Restart (no-op if not running)
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist

# Status
launchctl print gui/$(id -u)/com.pattybot.twitter-bot-chrome | head -20
```

**Never** quit Chrome via the dock menu / Cmd-Q / `osascript -e 'tell app "Google Chrome" to quit'`. Two reasons:
1. AppleScript can't disambiguate the bot Chrome from your daily Chrome (same app bundle, different `--user-data-dir`); it might quit the wrong one.
2. Even if you targeted the right one, `KeepAlive: true` would respawn it immediately — the right way to stop the bot Chrome is `launchctl bootout`.

## Schedule

Two fires per day, both local time (ET):
- **08:00 ET** — morning digest (covers ~10h since prior 22:00 → overnight)
- **22:00 ET** — evening recap (covers ~14h since prior 08:00 → daytime)

The cutoff for each run is read from `state/last-success.json#runAt`, so the windows hand off automatically — no overlap, no gaps.

## Change the fire times

Use `hermes cron list` to inspect the live schedule and Hermes cron management commands to change it. Do not reload the legacy digest plist.

## Re-auth (when X eventually invalidates the bot's session)

The skill hard-fails with `last-failure.json {"kind":"auth"}` when the timeline serves a login wall. To recover:

1. Click into the bot Chrome window (it's running 24/7; look for the window with the `twitter-bot-chrome` profile — the URL bar is the easy tell).
2. Navigate to `https://x.com/i/flow/login` and sign in with your X account.
3. The cookies persist in `~/Library/Application Support/twitter-bot-chrome/` and survive Chrome restarts.
4. Manually fire `~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest --dry-run` to validate the auth is back.

No reseed script is needed — the daemon Chrome is the source of truth for cookies, and signing in interactively is the most stealth-correct path (cookies have real `Set-Cookie` provenance, not CDP-imported / dir-copied weirdness).

## Tune the themes / filters

Edit `~/.claude/skills/twitter-digest/references/themes.md`. Changes apply on the next fire — no reload, no restart. The skill re-reads the file every run.

The promoted-posts filter is in SKILL.md (the `isPromoted` check in the extraction eval). Influencer/marketing triage is in `themes.md` under "Triage rules."

## Common failures and the failure-kind taxonomy

All failure records may include a `screenshot` field — an absolute path under `/tmp/twitter-digest-*.png` capturing the visible state at failure time (always present for stall-derived and article-extraction failures; present for other kinds when useful). Inspect it before changing code; it usually disambiguates similar-looking failure modes faster than reading the message.

| `kind` in last-failure.json | What happened | Fix |
|---|---|---|
| `visibility` | The page had no usable viewport or failed authenticated background-content proof after native activation. | Inspect route, authentication, primary-column and extraction evidence. A locked desktop by itself is supported. Never spoof visibility or click the lock screen. |
| `auth` | Login wall — X invalidated the bot's session, or detected mid-run via step 3a screenshot. | Sign in again interactively in the bot Chrome window (see "Re-auth" above). The screenshot in `last-failure.json#screenshot` will show the login wall variant if you want to confirm. |
| `dom` | Visibility OK, no login wall, but `[data-testid="primaryColumn"]` not found, OR step 3a saw a fundamentally different page chrome. | X UI changed — update the selectors in SKILL.md step 2/3. The screenshot shows what X is rendering now. |
| `telegram` | Telegram delivery failed even after the plain-text retry. | Check `state/last-failure.json#message` for Telegram's response. Often "message is too long" or "can't parse entities" — fix the compose step. |
| `empty` | Feed served zero tweets in the cutoff window. | Treated as success (cutoff advances). If recurring, sanity-check feed in your daily Chrome. |
| `stall` | Scroll stalled (3 consecutive zero-new-tweet iterations) and step 3a's screenshot didn't match any of the recoverable or pre-categorized states. | Open `last-failure.json#screenshot`. If it's a new modal variant: consider extending step 3a's classification table to recognize it as Esc-recoverable. If it's a new rate-limit / blocking pattern (e.g. "you've been temporarily limited"): add it as a ship-what-we-have row. If it looks like one of the existing categorized states but the agent missed it: tighten the classification language. After diagnosing, edit SKILL.md step 3a and re-fire — the failure-kind taxonomy is intentionally evolving rather than frozen. |
| `timeout` | Hermes exceeded the wrapper's wall deadline. | Inspect the fire block for the last completed stage. The wrapper already terminated descendants and released the lock; retry after addressing a recurring slow stage. |
| `agent` | Hermes exited non-zero, or returned 0 without fresh Telegram-confirmed success. | Read the one-shot final text in `twitter-fire.log`; state was intentionally not accepted as successful. |
| `busy` | Another digest/search/bookmark fire held the shared lock. | Wait for that bounded run to finish, then retry. |

## Bootstrap (one-time, on a fresh mini)

```bash
# 1. Stow the package (creates symlinks for plist + scripts + skill)
cd ~/dotfiles && stow -t ~ -R twitter-digest

# 2. Run the bot-Chrome bootstrap helper
~/bin/twitter-bot-chrome-setup.sh

# 3. Load the bot Chrome daemon
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist

# 4. Verify it's listening
curl -fsS http://127.0.0.1:9222/json/version

# 5. Sign into X in the bot Chrome window that just opened

# 6. Load the digest fire schedule
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist

# 7. Smoke test
~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest --dry-run
tail -50 ~/Library/Logs/twitter-fire.log
```

## State files

- `state/last-success.json` — written after a successful Telegram send. Next run reads its `runAt` as the cutoff.
- `state/pending.json` — written just before the Telegram send; removed on success. If present at the start of a new run, it means the previous fire crashed after scroll but before Telegram confirmed — forensic crumb, not consumed.
- `state/last-failure.json` — written when the skill fails unrecoverably. Contains `{kind, at, message}`.
