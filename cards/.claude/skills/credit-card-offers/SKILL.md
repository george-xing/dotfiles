---
name: credit-card-offers
description: Activate available Chase Offers and Amex Offers on a daily fire. Attaches via CDP to a long-running cards-bot Chrome daemon (launchctl-managed, persistent profile, debug port 19223), enumerates eligible offer tiles on each issuer's offers hub, clicks the "Add to card" button on every unactivated offer, deduplicates against per-issuer offer-ID files, and delivers a Telegram summary of merchants added, skipped, and any failures. Fires once daily at 03:00 PT via launchd. Use when the user asks for "activate my credit card offers", "Chase offers", "Amex offers", "card offer roundup", or when fired by launchd.
---

# Credit Card Offers

Once-daily job: attach to the persistent cards-bot Chrome on `127.0.0.1:19223`, activate every available Chase + Amex offer, deliver a roundup to Telegram. Designed to be fired headlessly via `claude -p` from launchd, but works fine when invoked interactively. **No time cutoff** — the dedup is per-offer-ID and kept forever; once an offer is activated it stays in the dedup until the issuer's offer system rolls it off. This mirrors how a human uses Chase Offers / Amex Offers: open the hub, click "Add" on every offer that isn't already added, close.

The fire is daily-not-bidaily and at 03:00 PT specifically because banks pattern-match high-frequency identical sessions; off-peak + low-cadence keeps the access profile boring.

## Inputs (from environment / state)

- **Browser**: long-running daemon Chrome managed by the `com.pattybot.cards-bot-chrome` LaunchAgent, listening on `http://127.0.0.1:19223` for CDP. Persistent user-data-dir at `$HOME/Library/Application Support/cards-bot-chrome`. Auth state (Chase + Amex cookies) lives in that profile and is set by manual sign-in via the bot Chrome window during bootstrap — NOT by cookie import. **Never spawn a new browser-use Chrome with `--profile` or `--headed` — always attach via `--cdp-url`.**
- **Dedup files**:
  - `state/chase-activated.json` — array of `{offer_id, merchant, deal, activatedAt}` for every Chase offer ever activated. **No TTL** — offers eventually expire on the issuer's side, and the dedup file doubles as audit log. Skip activation for any offer whose `offer_id` is already in this set.
  - `state/amex-activated.json` — same shape, keyed `{card_id, offer_id}` since the same Amex offer can appear independently across multiple cards on the same account.
- **Telegram bot token**: parse from `~/.claude/channels/telegram/.env` (key `TELEGRAM_BOT_TOKEN`).
- **Telegram chat_id**: `7953915703`.

## What this skill does NOT do

- **Does not log in.** If either bank shows a login wall, hard-fail `kind:auth` and stop. The operator signs in manually via the bot Chrome window. Programmatic login on banking sites risks account lockout and is non-negotiable.
- **Does not type into ANY input field, ever.** No search boxes, no card-rename fields, no credential fields. Typing on banking sites is a behavioral signature.
- **Does not click anything except the activate-offer buttons.** No "Got it" modals, no "Continue" prompts, no card switchers beyond the documented Amex card-switching pattern. The mid-run action set is the strictest in any skill in this repo.
- **Does not retry clicks.** If an activate button doesn't transition to "Added" after one click + wait, record the failure and move on. Banks count failed activations as a fraud signal.

## Workflow

### 1. Load dedup sets

```bash
CHASE_ACTIVATED=~/.claude/skills/credit-card-offers/state/chase-activated.json
AMEX_ACTIVATED=~/.claude/skills/credit-card-offers/state/amex-activated.json

# Counts only — actual dedup is offer-ID-keyed in the helper scripts.
CHASE_COUNT=$(python3 -c "
import json, os
p = '$CHASE_ACTIVATED'
n = len(json.load(open(p))) if os.path.exists(p) and os.path.getsize(p) else 0
print(n)
")
AMEX_COUNT=$(python3 -c "
import json, os
p = '$AMEX_ACTIVATED'
n = len(json.load(open(p))) if os.path.exists(p) and os.path.getsize(p) else 0
print(n)
")
echo "dedup state: chase=$CHASE_COUNT amex=$AMEX_COUNT"
```

### 2. Activate Chase Offers

Chase has a single offers hub regardless of card count (offers are pooled across all Chase cards on the account).

The activator helper handles everything end-to-end on the Chase tab:
1. Finds the Chase tab by URL substring via CDP `/json` listing.
2. Navigates to the offers hub URL if it isn't already there.
3. Probes the page for visibility, login wall, and offer tiles.
4. (When `MODE=activate`, post-selector-verification) clicks each unactivated offer's "Add to card" button with jittered human-cadence delays, verifies each click landed, dedups against `chase-activated.json`.
5. Returns a single-line JSON to stdout.

Call it:

```bash
CHASE_RESULT_JSON=$(
  DAEMON_PORT=19223 \
  DEDUP_FILE="$CHASE_ACTIVATED" \
  MODE="activate" \
  /Users/pattybot/dotfiles/cards/bin/lib/activate-chase.sh
)
CHASE_EXIT=$?
```

Result shape (when `ok: true`):
```json
{
  "ok": true,
  "issuer": "chase",
  "tiles_seen": 12,
  "activated": [
    {"offer_id": "abc123", "merchant": "Costco", "deal": "10% off, max $20"},
    ...
  ],
  "skipped_dedup": [{"offer_id": "xyz789", "merchant": "Apple"}],
  "skipped_already_added": [],
  "failures": []
}
```

On `ok: false` (auth/dom/challenge): record the failure-kind from the helper's output, screenshot has been written by the helper, halt the Chase phase and move to the Amex phase with Chase recorded as a partial failure. **Do not retry Chase.**

**The activator helper enforces these invariants** — see `/Users/pattybot/dotfiles/cards/bin/lib/activate-chase.sh`:
- Click loop uses 3-6s jittered delays between activations (human-cadence).
- Each click is followed by a verification probe: re-read the tile's state class; only count as `activated` if the post-click state shows "Added" / "Activated" / equivalent.
- If the verification fails on a tile, record to `failures` (with the merchant name + a screenshot pointer) and move on — never retry the same click.
- Stops immediately if the page DOM changes shape mid-loop (e.g., redirect to login → suggests session expired).

### 3. Activate Amex Offers per card

Amex shows offers per-card. The activator iterates each card account on the page; each card has its own set of offers. Same end-to-end pattern as the Chase activator — finds the Amex tab, navigates to `/offers/eligible`, probes, activates per-card.

```bash
AMEX_RESULT_JSON=$(
  DAEMON_PORT=19223 \
  DEDUP_FILE="$AMEX_ACTIVATED" \
  MODE="activate" \
  /Users/pattybot/dotfiles/cards/bin/lib/activate-amex.sh
)
AMEX_EXIT=$?
```

Result shape (multi-card):
```json
{
  "ok": true,
  "issuer": "amex",
  "cards": [
    {
      "card_id": "platinum-1234",
      "card_label": "Platinum 1234",
      "tiles_seen": 8,
      "activated": [{"offer_id": "...", "merchant": "...", "deal": "..."}],
      "skipped_dedup": [],
      "skipped_already_added": [],
      "failures": []
    },
    {
      "card_id": "gold-5678",
      ...
    }
  ]
}
```

Same invariants as Chase: per-tile jittered delays, post-click verification, no retries, hard-stop on shape change.

### 4. Determine overall run outcome

The wrapper has already verified `127.0.0.1:19223` responded before invoking you, and prefire foreground-activated the bot Chrome window. The activator helpers handle their own visibility / login-wall / DOM probes and emit `{ok:false, kind, message, screenshot}` JSON on failure — there's no separate "step 2 probe" any more.

Each helper returns one of:
- `{ok:true, ...}` — proceed
- `{ok:false, kind:"auth"|"mfa"|"challenge"|"visibility"|"dom", ...}` — hard fail for that issuer



Three possibilities feed into the Telegram message:

- **Both succeeded** (`CHASE_EXIT == 0 && AMEX_EXIT == 0`): standard summary. `last-success.json` will reflect both counts.
- **One succeeded, one failed** (`partial`): ship a summary that includes the successful issuer's results + a clear "couldn't reach $issuer — kind:$failure_kind" note. Mark the failed issuer's dedup state untouched (helper has already not appended). `last-failure.json` gets written with `kind: "partial"` and a list of the failed issuer + its sub-kind. **Telegram is still sent** in this case — partial is more useful than silence.
- **Both failed** (`CHASE_EXIT != 0 && AMEX_EXIT != 0`): write `last-failure.json` with `kind: "both_failed"` and the sub-kinds. **Do NOT send Telegram** in this case — there's nothing positive to report, and the operator finds it in the log. (This mirrors twitter-digest's "no Telegram on hard-fail" rule.)

### 5. Compose Telegram summary

Compose HTML (NOT Markdown — bank merchant names routinely contain `_*[` characters that legacy Telegram Markdown breaks on).

**HTML escaping rules** (apply LAST, after composition, so `<b>` tags survive): `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`. Telegram HTML supports a small whitelist: `<b>`, `<i>`, `<u>`, `<s>`, `<a href="...">`, `<code>`, `<pre>`. Don't use anything else.

Header uses local clock date:

```
💳 <b>Offer Roundup — &lt;date&gt;</b>

🏦 <b>Chase</b> (&lt;N&gt; new)
• Costco — 10% off, max $20
• DoorDash — $15 off ($40+)
• Whole Foods — 5% back

💎 <b>Amex Gold</b> (&lt;N&gt; new)
• Uber Eats — 5x ($50+)
• Resy — $25 off ($75+)

💎 <b>Amex Platinum</b> (&lt;N&gt; new)
• Equinox — $50 off
• Marriott — 10x (next stay)

—
&lt;total_activated&gt; activated • &lt;skipped_dedup&gt; previously added • &lt;failures&gt; failures
```

If a card / issuer has zero new offers, render: `• <i>no new offers</i>` under its section rather than hiding the section entirely — explicit "we checked, found nothing" is more reassuring than missing rows that could be a bug.

If literally zero new offers across all issuers AND no failures: send a single line `Nothing new on offers today 🥱` instead of an empty multi-section template.

For `partial` runs, append a section:
```
⚠️ <b>Couldn't reach</b>
• Chase — kind:auth (re-login on Mac mini)
```

### 6. Pre-send: write pending state

Before calling Telegram, write `state/pending.json` so a crash mid-send leaves a recoverable trace:

```bash
PENDING=~/.claude/skills/credit-card-offers/state/pending.json
NOW=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
cat > "$PENDING" <<EOF
{"runAt": "$NOW", "chaseActivated": $CHASE_ACTIVATED_COUNT, "amexActivated": $AMEX_ACTIVATED_COUNT, "telegramOk": null}
EOF
```

### 7. Deliver to Telegram

Reuse twitter's hardened helper (path-references the twitter package by absolute path — structural debt noted in cards CLAUDE.md):

```bash
RUN_DIR=/tmp/credit-card-offers-run
mkdir -p "$RUN_DIR"
printf '%s' "$DIGEST_HTML"  > "$RUN_DIR/digest.html"
printf '%s' "$DIGEST_PLAIN" > "$RUN_DIR/digest.txt"

TELEGRAM_CHAT_ID=7953915703 \
TELEGRAM_MESSAGE_FILE="$RUN_DIR/digest.html" \
TELEGRAM_MESSAGE_PLAIN_FILE="$RUN_DIR/digest.txt" \
RUN_DIR="$RUN_DIR" \
  /Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh
TG_EXIT=$?
```

The helper enforces the load-bearing invariants from prior production incidents (file-payload `--data-urlencode "text@<file>"`, one retry with plain-text on parseable `ok:false`, never retry on curl non-zero or local parse errors — preventing the duplicate-message bug).

**On `$TG_EXIT`:**
- `0` — sent successfully. Proceed to step 8.
- `1` — Telegram returned `ok:false` even after plain-text retry. Write `last-failure.json` with `kind: "telegram"`. STOP. Do NOT send another Telegram message about this failure.
- `2` — curl/network/local-parse failure. Same handling as `kind:telegram` but with network-error message.

### 8. On success: persist dedup FIRST, then atomic finalize

**Order matters** (same reasoning as twitter-digest step 8). Append activated offers to the dedup files BEFORE advancing `last-success.json`. If dedup append fails between Telegram-succeeded and state-advance, the operator has `pending.json` as a forensic marker, and a re-fire correctly re-records the offers. Reversing the order would mark the run successful while losing the offer IDs from dedup → next fire would attempt to re-activate already-activated offers → bank's dupe-add UI behavior is undefined (best case no-op, worst case fraud flag).

The helpers already returned the per-issuer activated lists. Append them via the shared `dedup-append.sh` (using path-reference to twitter helper):

```bash
# Append Chase activated. Helper expects DEDUP_URLS_JSON env var, but our shape
# is offer objects, not URLs — wrap to compatible shape: { url: offer_id, ...extras }.
# Helper preserves additional fields on append, so the merchant/deal/activatedAt
# all stick around in the dedup file.
CHASE_DEDUP_PAYLOAD=$(echo "$CHASE_RESULT_JSON" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(json.dumps([
    {'url': a['offer_id'], 'merchant': a.get('merchant'), 'deal': a.get('deal')}
    for a in r.get('activated', [])
]))
")
DEDUP_FILE="$CHASE_ACTIVATED" \
DEDUP_URLS_JSON="$CHASE_DEDUP_PAYLOAD" \
  /Users/pattybot/dotfiles/twitter/bin/lib/dedup-append.sh

# Same for Amex (flatten across cards into a single dedup-file array keyed by
# composite "card_id::offer_id" so the same offer ID on two cards doesn't
# false-dedup).
AMEX_DEDUP_PAYLOAD=$(echo "$AMEX_RESULT_JSON" | python3 -c "
import json, sys
r = json.load(sys.stdin)
out = []
for card in r.get('cards', []):
    for a in card.get('activated', []):
        out.append({'url': f\"{card['card_id']}::{a['offer_id']}\", 'merchant': a.get('merchant'), 'deal': a.get('deal'), 'card_id': card['card_id'], 'card_label': card.get('card_label')})
print(json.dumps(out))
")
DEDUP_FILE="$AMEX_ACTIVATED" \
DEDUP_URLS_JSON="$AMEX_DEDUP_PAYLOAD" \
  /Users/pattybot/dotfiles/twitter/bin/lib/dedup-append.sh

# Atomic last-success update.
LAST_SUCCESS=~/.claude/skills/credit-card-offers/state/last-success.json
python3 -c "
import json
d = json.load(open('$PENDING'))
d['telegramOk'] = True
json.dump(d, open('$PENDING.tmp', 'w'))
" && mv "$PENDING.tmp" "$LAST_SUCCESS" && rm -f "$PENDING"
```

The dedup-append helper handles idempotent appends, no-TTL (we pass no `DEDUP_TTL_DAYS`), and atomic write via PID-suffixed tmp + os.replace.

**Do NOT** call `browser-use close --all` — the daemon Chrome is launchd-managed and must keep running.

## Dry-run mode

If invoked with "dry-run" or "--dry-run" in the prompt: do everything *except* steps 6-8 — call the activator helpers in `MODE=probe` (enumerate only, no clicks), print the composed summary HTML to stdout, skip pending.json, skip Telegram, skip dedup updates. Useful for verifying selectors against the live DOM without spamming the chat or accidentally activating things.

```bash
# Probe-only call (replace MODE=activate with MODE=probe in steps 2 + 3).
CHASE_RESULT_JSON=$(
  DAEMON_PORT=19223 \
  DEDUP_FILE="$CHASE_ACTIVATED" \
  MODE="probe" \
  /Users/pattybot/dotfiles/cards/bin/lib/activate-chase.sh
)
```

Do NOT call `browser-use close --all` even in dry-run.

## Failure handling

Categorize failures and write `state/last-failure.json` with `{kind, at, message, screenshot}` (screenshot optional — `null` if not captured). The activator helpers screenshot automatically on every failure path.

`kind` values:

- `kind: "visibility"` — bot Chrome window not foreground. Operator brings window front, re-fires.
- `kind: "auth"` — login wall on Chase or Amex tab. Operator re-logs in via the bot Chrome window. Message identifies which issuer.
- `kind: "mfa"` — MFA challenge mid-run (SMS code prompt, app push prompt). Operator completes via the bot Chrome window manually.
- `kind: "challenge"` — CAPTCHA / "is this you?" / device-verification screen. Operator handles via the bot Chrome window. If recurring, consider increasing the inter-run gap (e.g. every 2 days instead of daily) — it's a sign the bank's bot-detection is flagging the cadence.
- `kind: "dom"` — selectors no longer match. Operator updates selectors in the activator helper (`bin/lib/activate-chase.sh` or `activate-amex.sh`) using the failure screenshot as ground truth.
- `kind: "partial"` — one issuer succeeded, the other failed. Telegram digest IS sent (with the partial warning section). The successful issuer's dedup advances normally.
- `kind: "both_failed"` — both issuers failed in the same fire. NO Telegram sent. Operator finds the failure in `~/Library/Logs/cards-fire.log` and last-failure.json.
- `kind: "telegram"` — Telegram delivery failed even after the plain-text retry.
- `kind: "empty"` — no new offers across both issuers, no failures. Treated as success: `last-success.json` advances with both counts at 0, `Nothing new today 🥱` message ships.

In hard-fail cases (visibility / auth / mfa / challenge / dom / both_failed), do NOT advance `last-success.json`. Partial cases DO advance `last-success.json` (with the successful issuer's counts) AND write `last-failure.json` simultaneously — partial is a hybrid state.

## What NOT to do

- **Do not spawn a fresh browser-use Chrome.** Always attach via `--cdp-url http://127.0.0.1:19223`. Spawning would create an ephemeral profile with no cookies, hitting the login wall immediately.
- **Do not call `browser-use close --all`.** Daemon Chrome lifetime is launchd's responsibility, not the skill's.
- **Do not try to log in programmatically.** Banks flag automated logins. Operator must sign in manually via the bot Chrome window.
- **Do not type into any input field.** Bank fraud teams pattern-match keystroke timing; even non-credential typing (search, card-rename) is a signature.
- **Do not click any button outside the activate-offer button class.** No modal-dismiss clicks, no card-switcher clicks beyond the documented Amex per-card iteration. Even harmless-looking "Got it" / "Continue" prompts may bind you to TOS/consent terms.
- **Do not retry an activation click.** If the post-click verification doesn't show "Added", record as failure and move on. Banks count failed attempts.
- **Do not run more often than daily.** Hourly or sub-hourly fires would burn the trusted-device cookie within days. The plist (when added in phase 4) is daily at 03:00 PT specifically.
- **Do not fake the foreground state.** CDP `Page.setWebLifecycleState("active")` produces a detectable mismatch. Hard-fail and require operator to actually bring the window foreground. `Page.bringToFront` IS allowed as a single self-recovery attempt (same reasoning as twitter-digest step 2 — it's a legitimate OS activation call).
- **Do not advance state on Telegram failure.** A failed send must NOT update `last-success.json`.
- **Do not send a Telegram error message when Telegram itself is the failure.** Log locally and exit.
- **Do not send a Telegram message on `both_failed`.** No positive content to report; operator finds it in the log.
