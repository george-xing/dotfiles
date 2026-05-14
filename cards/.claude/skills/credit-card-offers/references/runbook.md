# credit-card-offers — runbook

Operational reference. Read SKILL.md for the workflow + invariants; this file is for "how do I do X right now".

## One-time bootstrap (required before first fire)

The skill cannot run until the bot Chrome's persistent profile has Chase + Amex sessions established. This is a manual step on the Mac mini — by design, we never automate banking logins.

1. **Stow the package**:
   ```bash
   cd ~/dotfiles && stow -t ~ -R cards
   ```

2. **Run the setup script** (verifies port, profile dir, symlink):
   ```bash
   ~/dotfiles/cards/bin/cards-bot-chrome-setup.sh
   ```

3. **Load the daemon**:
   ```bash
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
   sleep 3
   curl -fsS http://127.0.0.1:19223/json/version
   ```
   Expected: a JSON blob with `"Browser":"Chrome/<version>"`. A new Chrome window will appear (the cards bot's profile).

4. **VNC / Screen-Share into the Mac mini** and use that Chrome window:

   **Chase:**
   - Open `https://secure.chase.com/web/auth/dashboard`
   - Sign in with your Chase credentials
   - Complete any MFA (SMS code, app push)
   - **Check "Remember this device"** if offered
   - Confirm you land on the dashboard

   **Amex:**
   - New tab → `https://global.americanexpress.com/`
   - Sign in with your Amex credentials
   - Complete any MFA
   - **Check "Remember this device"** if offered
   - Confirm you land on the account summary

5. **Leave both tabs open.** The daemon Chrome is `KeepAlive=true` — it stays running forever. The session cookies live in `~/Library/Application Support/cards-bot-chrome/` and persist across daemon restarts.

6. **Smoke-test the prefire** (validates daemon + activation, doesn't run the skill):
   ```bash
   ~/dotfiles/cards/bin/cards-prefire.sh
   ```
   Last stdout line should be `SAVED_FRONTMOST_PID=<some-pid>`. If you see `ERROR: daemon Chrome at ... not responding after 12s`, the daemon failed to start — check `~/Library/Logs/cards-bot-chrome.err.log`.

## Re-authentication (when a session expires)

Chase typically holds sessions for ~2-4 weeks; Amex for ~1-3 months. When they expire, the skill hard-fails with `kind: "auth"` and writes `state/last-failure.json` pointing to a screenshot. To recover:

1. Read the failure file:
   ```bash
   cat ~/.claude/skills/credit-card-offers/state/last-failure.json
   ```
2. VNC into the Mac mini, focus the cards bot Chrome window (the one on port 19223 — should still be there since the daemon's `KeepAlive=true`).
3. Navigate to the bank that failed, sign in again. Cookies will refresh in the persistent profile.
4. Re-fire manually to confirm:
   ```bash
   ~/dotfiles/cards/bin/cards-fire.sh credit-card-offers --dry-run
   tail -50 ~/Library/Logs/cards-fire.log
   ```

If the failure kind is `mfa` or `challenge` (CAPTCHA / "is this you?"), follow the same steps — sign back in manually, the trust-this-device cookie should re-establish.

## TCC / Automation permissions

The wrapper uses AppleScript via `osascript` to drive System Events for foreground activation. On first run, macOS will prompt for Automation permissions:

- **From Terminal**: easy — accept the dialog the first time `cards-fire.sh` runs from Terminal.
- **From launchd**: launchd-spawned processes can't show GUI prompts. You must pre-authorize by running `cards-fire.sh` interactively from Terminal at least once OR by adding the permission manually in System Settings → Privacy & Security → Automation.

If you see `osascript activation exit=1 stderr=...not allowed assistive access`, the Automation permission is missing. Open System Settings → Privacy & Security → Automation → check the relevant entries under Terminal (or whichever app you fired from).

## Failure kinds (full table once SKILL.md is in place)

| `kind` | Cause | Operator action |
|---|---|---|
| `auth` | Login wall present in Chase or Amex tab | Re-login in the bot Chrome window |
| `mfa` | MFA challenge mid-run | Re-login in the bot Chrome window |
| `challenge` | CAPTCHA / device-verification screen | Re-login; if recurring, consider a longer pause between runs |
| `dom` | Selectors broke (offers grid missing) | Update selectors in `references/selectors.md` and the activator helper |
| `visibility` | Bot Chrome window backgrounded | Foreground the cards bot Chrome window manually, re-fire |
| `partial` | One issuer succeeded, the other failed | Re-fire later; partial summary already shipped |
| `telegram` | Delivery failed even after plain-text retry | Check `~/.claude/channels/telegram/.env`; manual retry once stable |
| `empty` | No new offers (rare, treated as success) | None — `Nothing new today` message shipped |
| `busy` | Another `cards-fire` already running | None — wait for the in-progress fire |
| `prefire` | Daemon not responding or activation failed | Check daemon logs + launchctl state |
| `config` | Missing binary or skill file | Reinstall paths or re-stow |

## Logs

- `~/Library/Logs/cards-fire.log` — main per-fire log
- `~/Library/Logs/cards-bot-chrome.{out,err}.log` — daemon Chrome stdout/stderr
- `~/Library/Logs/credit-card-offers.launchd.{out,err}.log` — launchd-level errors for the daily cron job (phase 4+)

State (gitignored, on disk only):
- `~/.claude/skills/credit-card-offers/state/last-success.json` — `{runAt, chaseActivated, amexActivated, telegramOk}`
- `~/.claude/skills/credit-card-offers/state/last-failure.json` — `{kind, at, message, screenshot}`
- `~/.claude/skills/credit-card-offers/state/pending.json` — pre-Telegram-send forensic crumb
- `~/.claude/skills/credit-card-offers/state/{chase,amex}-activated.json` — dedup files, kept forever as audit log
- `~/.claude/skills/credit-card-offers/state/screenshots/` — failure-time PNGs (last 14d)

## Session-died recovery (keepalive Telegram path)

When you receive a Telegram from `cards-keepalive` saying "State: authed → auth-wall" (or "→ tab-missing", "→ daemon-down"), the bot Chrome's session for that issuer has died and the next 03:00 fire will hit a login wall. Recovery:

### auth-wall

1. VNC into the Mac mini.
2. Open the cards-bot Chrome window (port 19223; if you have multiple Chromes running, the cards one is the one with the Amex/Chase tabs).
3. Sign back in on the affected issuer (or both). Complete any MFA challenge presented.
4. **Do nothing else.** Don't navigate, don't close tabs, don't open new ones.
5. The next keepalive iteration (within 5 minutes) will probe and record a `auth-wall → authed` event in `keepalive-events.jsonl`. **No code action needed.** The next 03:00 fire will succeed.

### tab-missing

Same recovery as auth-wall, plus: open a new tab to the issuer's offers URL:
- Amex: `https://global.americanexpress.com/offers/eligible`
- Chase: `https://secure.chase.com/web/auth/dashboard#/dashboard/offers/offerHub`

### daemon-down

The cards-bot Chrome itself is unreachable. Steps:

```bash
launchctl print gui/$(id -u)/com.pattybot.cards-bot-chrome
# Look for last_exit_status, runs, state
```

If the daemon Chrome crashed, `KeepAlive=true` should respawn it. If respawn loop is broken:

```bash
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
```

Then sign in on both issuers (the persistent profile means cookies survive, but a fresh Chrome respawn may need to re-establish session in some cases).

## Keepalive event-log forensics

Useful one-liners for triaging keepalive state:

```bash
# Most-recent state per issuer
tail -50 ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl | \
  python3 -c "
import sys, json
last = {}
for line in sys.stdin:
    e = json.loads(line)
    last[e['issuer']] = e
for k, e in last.items():
    print(f\"{k}: {e['new']} (since {e['ts']}, note: {e.get('note', '')})\")
"

# All auth-wall events in the last day
grep auth-wall ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl | \
  python3 -c "
import sys, json
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(days=1)
for line in sys.stdin:
    e = json.loads(line)
    if datetime.fromisoformat(e['ts'].replace('Z', '+00:00')) >= cutoff:
        print(line.strip())
"

# Median session lifetime (auth-wall - prior authed timestamp)
# Useful for tracking against the spec's 7-day soak metric.
python3 <<'PY'
import json
from datetime import datetime
events = []
with open(__import__('os').path.expanduser('~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl')) as f:
    for line in f:
        events.append(json.loads(line))
durations = {}
for issuer in ("amex", "chase"):
    issuer_events = [e for e in events if e['issuer'] == issuer]
    spans = []
    last_authed = None
    for e in issuer_events:
        if e['new'] == 'authed':
            last_authed = datetime.fromisoformat(e['ts'].replace('Z', '+00:00'))
        elif e['new'] == 'auth-wall' and last_authed:
            spans.append((datetime.fromisoformat(e['ts'].replace('Z', '+00:00')) - last_authed).total_seconds())
            last_authed = None
    if spans:
        spans.sort()
        print(f"{issuer}: n={len(spans)}, median={spans[len(spans)//2]/3600:.1f}h, p95={spans[int(len(spans)*0.95)]/3600:.1f}h")
PY
```
