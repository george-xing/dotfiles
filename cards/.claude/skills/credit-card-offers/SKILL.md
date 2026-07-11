---
name: credit-card-offers
description: Activate available Chase Offers and Amex Offers on a daily fire. Attaches via CDP to a long-running cards-bot Chrome daemon (launchctl-managed, persistent profile, debug port 19223), agentically inspects the offers pages, clicks the activate button on every unactivated offer, deduplicates against per-issuer state files, and delivers a Telegram summary. Fires once daily at 03:00 local time via launchd. Use when the user asks for "activate my credit card offers", "Chase offers", "Amex offers", "card offer roundup", or when fired by launchd.
---

# Credit Card Offers

Once-daily job: attach to the persistent cards-bot Chrome on `127.0.0.1:19223`, activate every available Chase + Amex offer, deliver a roundup to Telegram. Designed to run headlessly via `codex exec` from launchd, but works fine interactively.

**Key design principle:** this skill is *agentic*, not scripted. You inspect the page at runtime, identify offers, click them, and verify the outcome — using JavaScript expressions you write yourself and send via the `cdp-eval.sh` primitive. The bank UI changes frequently; do NOT bake selectors into helper scripts. Adapt to what you see. When this SKILL.md gives example selectors below, those are *current observations as of 2026-05-14* — not contracts. If a selector returns 0 elements, probe to find the new one rather than failing.

The fire is daily-not-bidaily and at 03:00 local time specifically because banks pattern-match high-frequency identical sessions; off-peak + low-cadence keeps the access profile boring.

## Primitives available to you

These tiny helpers handle CDP plumbing only — no DOM logic, no decisions:

- **`/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh`** — evaluate a JS expression against a tab matched by URL substring. Returns `{ok, value}` or `{ok:false, kind, message}`. Calls `Page.bringToFront` first (legit OS-level activation, NOT `Page.setWebLifecycleState`).
  - Env: `TARGET_URL_SUBSTRING` (required), `EXPRESSION` (required), `AWAIT_PROMISE` (default true), `BRING_TO_FRONT` (default yes).
- **`/Users/pattybot/dotfiles/cards/bin/lib/cdp-screenshot.sh`** — Page.captureScreenshot for forensics on failures.
  - Env: `TARGET_URL_SUBSTRING` (required), `LABEL` (filename tag), writes to `state/screenshots/`.
- **`/Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh`** — hardened Telegram delivery with HTML body + plain fallback + one-retry-on-`ok:false`.
- **`/Users/pattybot/dotfiles/twitter/bin/lib/dedup-append.sh`** — atomic dedup-file appends (tmp + rename).

You will mostly use `cdp-eval.sh`. Wrap complex JS return values in `JSON.stringify(...)` so the value comes back as a parseable string.

## Hard rules — DO NOT VIOLATE

These exist because banks aggressively pattern-match automated behavior and account lockout is non-recoverable from a script:

- **This skill never performs login.** `cards-fire.sh` runs the reviewed `cards-auth.py` boundary first, using 1Password references. If a login wall appears here, hard-fail with `kind:"auth"`; never improvise a second credential submission.
- **The agent runs inside `config/cards-agent.sb`.** It is technically denied
  access to the cards secret-reference config, 1Password CLI/state, Login
  Keychain, the trusted Keychain helper, authentication code, and persistence
  controls. Do not attempt to bypass or modify this sandbox. Use only the CDP,
  state, dedup, screenshot, and Telegram primitives documented here.
- **Do not invoke `cards-offers.py`.** That deterministic fallback is obsolete
  and does not understand the current Chase UI. Inspect and operate the live
  pages through the CDP primitives in this skill.
- **NEVER type into ANY input field.** No search boxes, no card-rename fields. Typing is a behavioral signature.
- **ONLY click activate-offer buttons (Amex) or offer tiles / Add-to-card buttons on detail pages (Chase).** No "Got it" modal dismissal. No "Continue" prompts. No "Skip" / "Accept" / "Agree". If a modal blocks the page, the right answer is to bail with a screenshot, not to click your way out — those modals can commit the operator to TOS terms or are detection canaries.
- **NEVER retry a failed click.** If a click doesn't transition the offer to "Added" within a reasonable wait, record the failure and move on. Banks count failed activations as fraud signal.
- **NEVER fake foreground state.** `Page.setWebLifecycleState("active")` is detectable. `Page.bringToFront` IS allowed (it's a real OS-level activation, and `cdp-eval.sh` already calls it).
- Only the selected Chrome tab can report `document.visibilityState="visible"`.
  If an issuer tab initially reports `hidden`, bring that tab to front, wait one
  second, and re-probe. Visibility is advisory, not an authentication gate: if
  the tab remains `hidden` but the authenticated page and expected offer DOM
  are fully rendered, continue normally. Never fake lifecycle state.
- **NEVER call `browser-use close --all`.** Daemon Chrome lifetime is launchd's responsibility.
- **Persist each verified activation immediately in memory and preserve that
  list even if a later offer fails or a runaway cap is reached.** A partial
  failure must never erase already-completed activations from the report or
  dedup state.
- **Cadence:** between clicks, sleep a *random* 3–6 seconds. No metronome timing. Run `sleep $(awk 'BEGIN{srand(); print 3+rand()*3}')` between clicks.

If you encounter something this list doesn't cover and you're tempted to click it, the answer is to bail with `kind:"challenge"` + a screenshot, not to improvise.

## Inputs

- **Browser**: daemon Chrome on `http://127.0.0.1:19223` (CDP). Persistent profile holds Chase + Amex cookies. Both issuers each have ONE tab open.
- **Dedup files** under `~/.claude/skills/credit-card-offers/state/`:
  - `chase-activated.json` — array of `{url, merchant, deal, ...}`. `url` is the dedup KEY — `"chase::<offer_id_from_url>"` is the recommended shape.
  - `amex-activated.json` — same shape; key is `"<card_label>::<merchant>::<deal>"` composite.
- **Telegram bot token**: parse from `~/.claude/channels/telegram/.env` (key `TELEGRAM_BOT_TOKEN`).
- **Telegram chat_id**: `7953915703`.
- **Caps:** `AMEX_MAX_CLICKS` (default 500), `CHASE_MAX_CLICKS` (default 500). The goal is to activate every available offer in one daily fire; the cap is only a runaway guard.

## Workflow

### 1. Load dedup state

```bash
CHASE_ACTIVATED=~/.claude/skills/credit-card-offers/state/chase-activated.json
AMEX_ACTIVATED=~/.claude/skills/credit-card-offers/state/amex-activated.json
CHASE_COUNT=$(/usr/bin/python3 -c "import json, os; p='$CHASE_ACTIVATED'; print(len(json.load(open(p))) if os.path.exists(p) and os.path.getsize(p) else 0)")
AMEX_COUNT=$(/usr/bin/python3 -c "import json, os; p='$AMEX_ACTIVATED'; print(len(json.load(open(p))) if os.path.exists(p) and os.path.getsize(p) else 0)")
echo "dedup state: chase=$CHASE_COUNT amex=$AMEX_COUNT"
```

### 2. Activate Amex offers

Amex offers UI (observed 2026-05-14): a single scrolling list of offer "tiles" on `https://global.americanexpress.com/offers/eligible`. Each unactivated tile has an inline `+` icon button. After click, the button disappears from the DOM. Multi-card support is OUT OF SCOPE for v1 — process only the currently-selected card.

**Step 2.1 — Pre-flight.** Use `cdp-eval` to inspect Amex state:

```bash
TARGET_URL_SUBSTRING=americanexpress.com \
EXPRESSION='JSON.stringify({
  url: location.href,
  title: document.title,
  hasPwInput: !!document.querySelector("input[type=password]"),
  cardLabel: (document.querySelector("[data-testid=simple_switcher_display_label]")?.innerText || "").trim().split(/\s+/).join(" "),
  addBtnCount: document.querySelectorAll("[data-testid=merchantOfferListAddButton]").length
})' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
```

Parse the response value (a JSON string). Branch:
- `hasPwInput=true` or `title` contains "Log In": Amex is logged out → screenshot + `kind:"auth"` + skip the Amex section.
- `url` doesn't include `/offers/eligible`: navigate, wait 5s, re-probe:
  ```bash
  TARGET_URL_SUBSTRING=americanexpress.com EXPRESSION='location.href = "https://global.americanexpress.com/offers/eligible"; "navigating"' /Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
  sleep 5
  ```
- `addBtnCount=0` but session looks valid: page hasn't fully rendered, or the user has activated all offers. Sleep 3s and re-probe once. If still 0, treat as empty (success with 0 activated).

**Step 2.2 — The click loop.** Up to `AMEX_MAX_CLICKS` (default 500):

The Add button has `[data-testid="merchantOfferListAddButton"]` with empty innerText (icon button). To identify *which* offer the next button corresponds to, walk up the parent chain from the button to the per-offer container (the div with `border` in its class). Lines of that container's innerText: line 0 = merchant, line 1 = deal description.

**Each iteration** extracts the live offer, clicks once, and verifies the
visible state transition:

a. **Extract the next offer's identity:**
```bash
TARGET_URL_SUBSTRING=americanexpress.com \
EXPRESSION='JSON.stringify((() => {
  const btn = document.querySelector("[data-testid=merchantOfferListAddButton]:not([data-cards-skip])");
  if (!btn) return null;
  let p = btn;
  for (let i = 0; i < 6 && p; i++) {
    const cls = (p.className && p.className.toString) ? p.className.toString() : "";
    if (cls.includes("border")) break;
    p = p.parentElement;
  }
  const text = (p?.innerText || "").trim();
  const lines = text.split("\n").map(s => s.trim()).filter(Boolean);
  if (lines[0]?.toUpperCase() === "NEW") lines.shift();
  return { merchant: lines[0] || "<unknown>", deal: lines[1] || "" };
})())' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
```

If `value` is the JSON string `"null"` (i.e. no more Add buttons remain): exit the loop normally — you've processed everything.

b. **Do not use dedup state to skip a visible Add button.** The live Amex
control is authoritative: if `[data-testid=merchantOfferListAddButton]` is
visible, that offer is not attached to the selected card and must be clicked.
Historical dedup can be stale after an interrupted run or an earlier verifier
bug. Use dedup only to avoid duplicate persisted records; it must never decide
whether to activate a live visible offer.

c. **Click + verify using the Added-to-Card counter.** Amex backfills the
visible list immediately, so the number of Add buttons may stay constant or
even increase after a successful click. Button count is not authoritative.

Before clicking, parse the integer in visible body text matching
`Added to Card (N)`. Give the chosen button a unique temporary marker, scroll
it into view, click it exactly once, then wait the randomized 3–6 seconds.
Poll for up to 15 seconds. Treat the click as verified when any of these occurs:

- `Added to Card (N)` increases;
- the uniquely marked button is disconnected from the DOM; or
- the original offer container visibly changes to an added/success state.

The counter increase is the preferred proof. A stable/increased total Add
button count does **not** mean failure because the list backfills. Once
verified, immediately record `{merchant, deal, card_id: cardLabel}` in memory.
If none of the valid transitions occurs within 15 seconds, screenshot with
`LABEL=amex-verify-fail`, record the partial progress already completed, and
stop the Amex section without retrying that click.

Stop conditions: hit `AMEX_MAX_CLICKS`, ran out of buttons, OR encountered a verification failure.

### 3. Activate Chase offers

Chase's current flow is hub tile → automatic activation page → hub. Chase can
also log you out of the offers area even when `/dashboard/overview` remains
authenticated, so always validate the offers page itself.

**Step 3.1 — Pre-flight:**

```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='JSON.stringify({
  url: location.href,
  title: document.title,
  hasPwInput: !!document.querySelector("input[type=password]"),
  bodyLen: (document.body && document.body.innerText || "").length
})' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
```

If `hasPwInput=true`, `title` matches `/sign in/i`, or `bodyLen < 200` while title indicates login: auth wall. Screenshot + `kind:"auth"` + skip Chase.

Otherwise navigate to the offers hub using Chase's current official nav key:
```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='location.href = "https://secure.chase.com/web/auth/dashboard?navKey=reviewMerchantOffers"; "navigating"' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
sleep 8  # Chase SPA hash-routing resolves to /merchantOffers/offer-hub; slow.
```

Re-probe. Expected end state: the title indicates Chase Offers and either at least one visible `[data-testid="commerce-tile"]` exists or the page clearly states that no offers are available. The current UI may duplicate an offer across a featured carousel and the full list, so deduplicate by detail URL/offer ID rather than tile index.

If the page is authenticated but has zero visible tiles, the read-only service below may be used as secondary evidence only:

```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='fetch("/svc/wr/accounts/l4/dso/v2/offers/list", {credentials:"include"}).then(r => r.json()).then(d => JSON.stringify({code:d.code || null, count:Array.isArray(d.offers) ? d.offers.length : null}))' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
```

- If visible `commerce-tile` elements exist, process them regardless of the service result. Chase currently sometimes returns `ACCOUNTS:UnexpectedException` while the page is fully populated.
- `code="SUCCESS"` and `count=0`, with zero visible tiles and an authenticated page: valid empty success.
- Any other zero-tile result: categorize from the visible page (`auth`, `mfa`, `challenge`, or `dom`) and do not guess.

**Step 3.2 — Current direct-activation loop.** Up to
`CHASE_MAX_CLICKS` (default 500):

The July 2026 Chase UI activates an offer when its hub tile is clicked. It
then routes directly to `/merchantOffers/offer-activated/<offer-id>`. There is
no second Add button. Older instructions that inferred "already added" merely
because a hidden alert existed on the detail page are invalid.

On each iteration, inspect the hub and select the first unique tile that:

- has `[data-testid="commerce-tile"]`;
- has a stable `id` beginning with `CDLX:` or `FIGG:`;
- does not have a *visible* descendant
  `[data-testid="offer-tile-alert-container-success"]`;
- does not contain `Success Added` in its `aria-label`; and
- has not already been visited during this run.

The page contains a featured carousel plus the full list, so the same offer
can appear twice. Track visited IDs in memory. Never use tile index as identity.

Before clicking, capture:

- `offer_id = tile.id`;
- merchant and deal from the tile's nonempty text lines, stripping badge lines
  such as `New`, `Exclusive`, `Expiring soon`, and time-remaining lines; and
- the numeric `Added offers` counter from the page text.

Mark the ID visited in memory **before** clicking. Scroll the tile into view,
click exactly once, and wait the randomized 3–6 second cadence.

Verify activation using visible/current state, not mere DOM existence. Success
requires the URL to contain `/offer-activated/<offer_id>` and at least one of:

- a visible success/added marker on the activated page;
- accessible visible text indicating the offer was added; or
- after returning to the hub, the matching tile's `aria-label` contains
  `Success Added`, it has a visible success descendant, or the numeric Added
  counter increased.

If verified, record `{merchant, deal, offer_id}` immediately in the in-memory
activated list. If not verified, screenshot, record one failure, and stop the
Chase section without retrying the click.

Return to the hub with the official URL below, wait for visible
`commerce-tile` elements, and repeat:

```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='location.href = "https://secure.chase.com/web/auth/dashboard?navKey=reviewMerchantOffers"; "navigating"' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
sleep 5
```

When no unvisited, non-success tile remains, Chase is exhausted successfully.

### 4. Determine overall outcome

After both issuers run:
- **Both succeeded**: standard digest, Telegram, advance state.
- **Partial** (one auth-walled/errored, other succeeded): digest with a "couldn't reach <issuer>" section; advance `last-success.json` with the succeeded counts; ALSO write `last-failure.json` with `kind:"partial"` and the failing issuer's sub-kind.
- **Both failed**: send a concise Telegram failure report, write
  `last-failure.json`, and exit nonzero. The daily job must always report its
  outcome unless Telegram itself is unavailable.
- **Empty success** (zero new across both, no failures): ship `Nothing new today 🥱` and advance state.

### 5. Compose Telegram digest (HTML)

Apply the escape pipeline LAST so `<b>` tags survive: `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`. Allowed HTML tags: `<b>`, `<i>`, `<u>`, `<s>`, `<a href>`, `<code>`, `<pre>`. Nothing else (legacy Telegram HTML mode).

Format:

```
💳 <b>Offer Roundup — <date></b>

🏦 <b>Chase</b> (<N> new)
• <merchant> — <deal>
...

💎 <b>Amex <card_label></b> (<N> new)
• <merchant> — <deal>
...

—
<total> activated • <skipped_dedup> previously added • <failures> failures
```

Zero new in a section → `• <i>no new offers</i>`. For `partial` runs, append:

```
⚠️ <b>Couldn't reach</b>
• <Issuer> — kind:<failure_kind> (action: re-login on Mac mini)
```

Before sending, measure the final HTML as Telegram UTF-16 code units. Keep it under 3,800 units (headroom below Telegram's 4,096 limit). If a large activation batch would exceed that budget, keep the header, per-issuer counts, totals, and as many offer lines as fit, then append `• <i>…and N more activated offers</i>`. Never split or retry as multiple messages.

### 6. Pre-send: write pending state

```bash
PENDING=~/.claude/skills/credit-card-offers/state/pending.json
NOW=$(/usr/bin/python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
echo '{"runAt": "'"$NOW"'", "chaseActivated": '"$CHASE_NEW"', "amexActivated": '"$AMEX_NEW"', "telegramOk": null}' > "$PENDING"
```

### 7. Deliver Telegram

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

`TG_EXIT`: 0=ok, 1=`ok:false` even after the helper's plain-text retry, 2=network/parse. The helper does ONE internal retry on parseable `ok:false`; do not add additional retries.

### 8. On success: persist dedup FIRST, then atomic finalize

Order matters. Append activated offers to dedup files BEFORE advancing `last-success.json`. If dedup append fails between Telegram-success and state-advance, the operator has `pending.json` as a forensic marker, and a re-fire correctly re-records the offers. Reversing the order would mark the run successful while losing the offer IDs → next fire attempts re-activate → bank's dupe-add behavior is undefined.

```bash
# The dedup-append helper takes a JSON array of URL STRINGS (not dicts).
# It writes entries as {url, digestedAt}; only the URL is persisted, so the
# composite key must encode everything we'd want to dedup against.
AMEX_URLS=$(/usr/bin/python3 <<'PY'
import json
activated = [
  # ...populated from your loop, each: {"merchant", "deal", "card_id"}...
]
print(json.dumps([f"{a['card_id']}::{a['merchant']}::{a['deal']}" for a in activated]))
PY
)
DEDUP_FILE="$AMEX_ACTIVATED" DEDUP_URLS_JSON="$AMEX_URLS" /Users/pattybot/dotfiles/twitter/bin/lib/dedup-append.sh

# Chase: key shape `"chase::<offer_id>"` where offer_id is the CDLX:NNN
# segment from the /offer-activated/<offer_id>?accountId=... URL.
# CHASE_URLS=... DEDUP_FILE="$CHASE_ACTIVATED" /Users/pattybot/dotfiles/twitter/bin/lib/dedup-append.sh

LAST_SUCCESS=~/.claude/skills/credit-card-offers/state/last-success.json
/usr/bin/python3 -c "
import json
d = json.load(open('$PENDING'))
d['telegramOk'] = True
json.dump(d, open('$PENDING.tmp', 'w'))
" && mv "$PENDING.tmp" "$LAST_SUCCESS" && rm -f "$PENDING"
```

On a full success or empty success, remove any stale `last-failure.json` from
an older run. On a partial or failed run, retain/write the current failure
record as described below. This keeps operational status unambiguous.

**Do NOT call `browser-use close --all`** — daemon Chrome lifetime is launchd's.

## Dry-run mode

Invoked with `"dry-run"` or `"--dry-run"` in the prompt: do all probes via `cdp-eval`, compose the digest HTML, print it to stdout. **Skip clicks, skip pending.json, skip Telegram, skip dedup**. Use this to validate page state without side effects.

To skip clicks while still walking the loop logic: short-circuit the click step (replace each click eval with a no-op echo). To skip Telegram: don't invoke `telegram-send.sh`.

## Failure handling

Categorize and write `state/last-failure.json` with `{kind, at, message, screenshot}`:

- `kind: "auth"` — login wall on an issuer. Operator action: re-login via the bot Chrome window.
- `kind: "mfa"` — MFA challenge mid-run. Operator completes manually.
- `kind: "challenge"` — CAPTCHA / "is this you?" / device-verify. Operator handles. Recurrence suggests bumping the inter-run gap or revisiting cadence.
- `kind: "dom"` — selectors didn't match what SKILL.md guidance suggested. Operator inspects the screenshot; may update SKILL.md if bank UI changed.
- `kind: "partial"` — one issuer succeeded, the other failed. Telegram IS sent (with the partial warning).
- `kind: "both_failed"` — send a concise Telegram failure report and exit nonzero.
- `kind: "telegram"` — Telegram failure even after the plain-text retry.
- `kind: "empty"` — zero new across both issuers, no failures. Treated as success.
- `kind: "visibility"` — use only when backgrounding actually prevents the
  expected page DOM from rendering or transitioning, not merely because
  `document.visibilityState` reports `hidden`.

Hard-fail cases (auth/mfa/challenge/dom/both_failed): do NOT advance `last-success.json`. Partial DOES advance (with the successful counts) AND writes `last-failure.json`. Any activations verified before a failure must still be included in Telegram and appended to dedup before exit.

## What NOT to do

Restating the hard rules and adding observed-mistake patterns:

- **Do not spawn a fresh `browser-use` Chrome.** Always attach via direct CDP to port 19223.
- **Do not call `browser-use close --all`.**
- **Do not log in from this skill.** Authentication is exclusively owned by `cards-auth.py` and happens before the skill starts.
- **Do not type into any input field.**
- **Do not click anything outside activate-offer buttons** (Amex) or **offer tiles / Add buttons on detail pages** (Chase). No modal-dismiss clicks. No "Continue" / "Got it" / "Skip".
- **Do not retry a failed click.** One click, one verify, move on.
- **Do not run more often than daily.** The plist is 03:00 local time daily for a reason.
- **Do not fake foreground state via `Page.setWebLifecycleState`.** `Page.bringToFront` is allowed and `cdp-eval.sh` already calls it.
- **Do not advance `last-success.json` on Telegram failure.**
- **Do not send a Telegram error message when Telegram itself is the failure.**
- **Do send a Telegram outcome on `both_failed`.** Only a Telegram transport
  failure can prevent the daily report.
- **Do not write to `state/keepalive-events.jsonl`, `state/auth-notify-cooldown.json`, or `state/fire-in-progress.lock`.** Those are owned by `cards-keepalive.sh` and `cards-fire.sh` respectively. Your writes go to `last-success.json`, `last-failure.json`, `pending.json`, and the dedup files only.
- **Do not bake DOM selectors into bash files.** The selectors in this SKILL.md (e.g. `merchantOfferListAddButton`, `commerce-tile`, `added-to-card-alert`) are *observations*, not contracts. When a selector returns 0 unexpectedly, probe to find the new pattern at runtime; if a fundamental shift, update this SKILL.md guidance.
- **Do not run the keepalive inline.** Session-keepalive is a separate launchd job (`com.pattybot.cards-keepalive`); your only interaction is `state/fire-in-progress.lock` (the fire wrapper writes it at start and removes via trap).
