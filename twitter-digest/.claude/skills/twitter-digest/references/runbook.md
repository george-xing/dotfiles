# twitter-digest runbook

## Architecture (read this first)

There are TWO launchctl jobs that work together:

- `com.pattybot.twitter-bot-chrome` — long-running daemon Chrome with persistent profile at `~/Library/Application Support/twitter-bot-chrome/` and CDP debug port 9222. `KeepAlive: true`. **Always running.**
- `com.pattybot.twitter-digest` — the twice-daily timer (08:00 and 22:00 ET) that fires the wrapper, which attaches to the daemon and runs the skill.

The bot Chrome window MUST be foreground in your GUI session at fire time — `document.visibilityState` must be `"visible"`. The skill hard-fails if it isn't (no fake-active state masking). Operator's responsibility to keep the bot Chrome window unobscured around 8am and 10pm.

## Manual fire (any time)

Fire via launchd (same code path as the scheduled triggers):
```bash
launchctl kickstart -p gui/$(id -u)/com.pattybot.twitter-digest
```

Or fire the wrapper directly (skips launchd, still uses the same code path):
```bash
~/bin/twitter-digest-fire.sh            # live — sends to Telegram
~/bin/twitter-digest-fire.sh --dry-run  # composes digest, prints to log only
```

Or fire the skill straight from a `claude -p` prompt:
```bash
claude -p "run the twitter-digest skill"            # live
claude -p "run the twitter-digest skill in dry-run" # dry
```

The wrapper does a 12s health check on `http://127.0.0.1:9222/json/version` before invoking `claude -p`. If the daemon Chrome isn't responding, the wrapper exits 2 immediately rather than burning a Claude turn.

## Logs

- `~/Library/Logs/twitter-digest.log` — main per-fire log. Each fire appends a `===== fire <iso> =====` / `----- exit <N> -----` block.
- `~/Library/Logs/twitter-digest.launchd.{out,err}.log` — launchd-level errors for the fire job (PATH / permissions / plist).
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

Edit `~/Library/LaunchAgents/com.pattybot.twitter-digest.plist` (`StartCalendarInterval` is an array of `{Hour, Minute}` dicts, one per daily trigger), then reload:
```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl print gui/$(id -u)/com.pattybot.twitter-digest | grep -E "Hour|Minute"
```

## Re-auth (when X eventually invalidates the bot's session)

The skill hard-fails with `last-failure.json {"kind":"auth"}` when the timeline serves a login wall. To recover:

1. Click into the bot Chrome window (it's running 24/7; look for the window with the `twitter-bot-chrome` profile — the URL bar is the easy tell).
2. Navigate to `https://x.com/i/flow/login` and sign in with your X account.
3. The cookies persist in `~/Library/Application Support/twitter-bot-chrome/` and survive Chrome restarts.
4. Manually fire `~/bin/twitter-digest-fire.sh --dry-run` to validate the auth is back.

No reseed script is needed — the daemon Chrome is the source of truth for cookies, and signing in interactively is the most stealth-correct path (cookies have real `Set-Cookie` provenance, not CDP-imported / dir-copied weirdness).

## Tune the themes / filters

Edit `~/.claude/skills/twitter-digest/references/themes.md`. Changes apply on the next fire — no reload, no restart. The skill re-reads the file every run.

The promoted-posts filter is in SKILL.md (the `isPromoted` check in the extraction eval). Influencer/marketing triage is in `themes.md` under "Triage rules."

## Common failures and the failure-kind taxonomy

| `kind` in last-failure.json | What happened | Fix |
|---|---|---|
| `visibility` | Bot Chrome window not foreground when scrape ran. `vis !== "visible"` after navigation. | Bring bot Chrome window to front (Mission Control → click). Re-fire manually. Long-term: don't put another full-screen app in front of the bot Chrome around 08:00 / 22:00. |
| `auth` | Login wall — X invalidated the bot's session. | Sign in again interactively in the bot Chrome window (see "Re-auth" above). |
| `dom` | Visibility OK, no login wall, but `[data-testid="primaryColumn"]` not found. | X UI changed — update the selectors in SKILL.md step 2/3. |
| `telegram` | Telegram delivery failed even after the plain-text retry. | Check `state/last-failure.json#message` for Telegram's response. Often "message is too long" or "can't parse entities" — fix the compose step. |
| `empty` | Feed served zero tweets in the cutoff window. | Treated as success (cutoff advances). If recurring, sanity-check feed in your daily Chrome. |

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
~/bin/twitter-digest-fire.sh --dry-run
tail -50 ~/Library/Logs/twitter-digest.log
```

## State files

- `state/last-success.json` — written after a successful Telegram send. Next run reads its `runAt` as the cutoff.
- `state/pending.json` — written just before the Telegram send; removed on success. If present at the start of a new run, it means the previous fire crashed after scroll but before Telegram confirmed — forensic crumb, not consumed.
- `state/last-failure.json` — written when the skill fails unrecoverably. Contains `{kind, at, message}`.
- `state/x-cookies.json` — **deprecated.** Was used by the old `browser-use cookies import` flow before the persistent-daemon migration. No longer consumed. Safe to delete; gitignored anyway.
