# twitter-digest runbook

## Manual fire (any time)

Fire via launchd (same code path as the 7am trigger):
```bash
launchctl kickstart -p gui/$(id -u)/com.pattybot.twitter-digest
```

Or fire the wrapper directly (skips launchd, still hits the skill):
```bash
~/bin/twitter-digest-fire.sh            # live — sends to Telegram
~/bin/twitter-digest-fire.sh --dry-run  # composes digest, prints to log only
```

Or fire the skill straight from a `claude -p` prompt:
```bash
claude -p "run the twitter-digest skill"            # live
claude -p "run the twitter-digest skill in dry-run" # dry
```

## Logs

- `~/Library/Logs/twitter-digest.log` — the meaningful one. Each fire appends a `===== fire <iso> =====` / `----- exit <N> -----` block with everything the wrapper and `claude -p` emitted.
- `~/Library/Logs/twitter-digest.launchd.out.log` — launchd stdout (usually empty; the wrapper redirects everything into the main log).
- `~/Library/Logs/twitter-digest.launchd.err.log` — launchd-level errors (PATH / permissions / plist). If the digest never fires, check here first.

## Pause / resume the schedule

```bash
# Pause
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist

# Resume
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
```

Check whether it's loaded:
```bash
launchctl print gui/$(id -u)/com.pattybot.twitter-digest | head -20
```

## Schedule

Two fires per day, both local time:
- **08:00 ET** — morning digest (covers ~10h since prior 22:00 fire → overnight)
- **22:00 ET** — evening recap (covers ~14h since prior 08:00 fire → daytime)

The cutoff for each run is read from `state/last-success.json#runAt`, so the windows hand off automatically — no overlap, no gaps.

## Change the fire times (or add/remove one)

Edit `~/Library/LaunchAgents/com.pattybot.twitter-digest.plist` (`StartCalendarInterval` is an array of `{Hour, Minute}` dicts — one per daily trigger), then reload:
```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl print gui/$(id -u)/com.pattybot.twitter-digest | grep -E "Hour|Minute"   # verify
```

## Refresh X cookies (when they expire)

X session cookies are long-lived but not permanent. When the skill starts producing `Nothing notable 🥱` every morning or the log shows "cookies appear expired," re-export:

```bash
browser-use close --all
browser-use --headed --profile "Patty" open https://x.com/i/flow/login
# Sign in via the Chrome window that appears.
browser-use cookies export ~/.claude/skills/twitter-digest/state/x-cookies.json
chmod 600 ~/.claude/skills/twitter-digest/state/x-cookies.json
browser-use close --all
```

Then re-fire the digest to confirm it's back.

## Tune the themes / filters

Edit `~/.claude/skills/twitter-digest/references/themes.md`. Changes apply on next fire — no reload, no restart. The skill re-reads the file every run.

The promoted-posts filter is in SKILL.md (the `isPromoted` check in the extraction eval). Influencer/marketing triage is in `themes.md` under "Triage rules."

## Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| Digest never arrives | launchd didn't fire | Check `~/Library/Logs/twitter-digest.launchd.err.log` and `launchctl print gui/$(id -u)/com.pattybot.twitter-digest`. If `state = not running` and no trigger fired, the plist may be unloaded. Re-bootstrap. |
| "Cookies appear expired" in log | X session aged out | Re-export cookies (section above). |
| Empty digest every morning | Viewport bug / DOM changes | Check log for the viewport-verify output — if `iw: 0, vis: hidden`, the CDP fix didn't take. If the viewport is fine but zero tweets extracted, X's `data-testid` hooks may have changed; update selectors in SKILL.md. |
| `browser-use` lock error / profile busy | A prior Chrome wasn't cleaned up | Wrapper already calls `browser-use close --all` before and after, but zombie real-Chrome windows can still hold the Patty profile. Run `osascript -e 'tell application "Google Chrome" to quit'` or `pkill -u pattybot -f "Google Chrome.app/Contents/MacOS"`. |
| Telegram returns `ok: false` | HTML escape miss or message >4096 chars | Skill retries once as plain text. If still failing, `~/.claude/skills/twitter-digest/state/last-failure.json` will have the response body. |

## State files

- `state/x-cookies.json` — X cookies (mode 0600). Required. Re-export when expired.
- `state/last-success.json` — written after a successful Telegram send. Next run reads its `runAt` as the cutoff.
- `state/pending.json` — written just before the Telegram send; removed on success. If present at the start of a new run, it means the previous fire crashed after scroll but before Telegram confirmed — forensic crumb, not consumed.
- `state/last-failure.json` — written when the skill fails unrecoverably. Contains `{kind, at, message}`.
