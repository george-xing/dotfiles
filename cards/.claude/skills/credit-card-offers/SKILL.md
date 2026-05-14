---
name: credit-card-offers
description: Activate available Chase Offers and Amex Offers on a daily fire. Attaches via CDP to a long-running cards-bot Chrome daemon (launchctl-managed, persistent profile, debug port 19223), agentically inspects the offers pages, clicks the activate button on every unactivated offer, deduplicates against per-issuer state files, and delivers a Telegram summary. Fires once daily at 03:00 PT via launchd. Use when the user asks for "activate my credit card offers", "Chase offers", "Amex offers", "card offer roundup", or when fired by launchd.
---

# Credit Card Offers

Once-daily job: attach to the persistent cards-bot Chrome on `127.0.0.1:19223`, activate every available Chase + Amex offer, deliver a roundup to Telegram. Designed to run headlessly via `claude -p` from launchd, but works fine interactively.

**Key design principle:** this skill is *agentic*, not scripted. You inspect the page at runtime, identify offers, click them, and verify the outcome — using JavaScript expressions you write yourself and send via the `cdp-eval.sh` primitive. The bank UI changes frequently; do NOT bake selectors into helper scripts. Adapt to what you see. When this SKILL.md gives example selectors below, those are *current observations as of 2026-05-14* — not contracts. If a selector returns 0 elements, probe to find the new one rather than failing.

The fire is daily-not-bidaily and at 03:00 PT specifically because banks pattern-match high-frequency identical sessions; off-peak + low-cadence keeps the access profile boring.

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

- **NEVER programmatically log in.** No typing credentials, ever. If a login wall appears, hard-fail with `kind:"auth"` and stop. The operator signs in manually via the bot Chrome window.
- **NEVER type into ANY input field.** No search boxes, no card-rename fields. Typing is a behavioral signature.
- **ONLY click activate-offer buttons (Amex) or offer tiles / Add-to-card buttons on detail pages (Chase).** No "Got it" modal dismissal. No "Continue" prompts. No "Skip" / "Accept" / "Agree". If a modal blocks the page, the right answer is to bail with a screenshot, not to click your way out — those modals can commit the operator to TOS terms or are detection canaries.
- **NEVER retry a failed click.** If a click doesn't transition the offer to "Added" within a reasonable wait, record the failure and move on. Banks count failed activations as fraud signal.
- **NEVER fake foreground state.** `Page.setWebLifecycleState("active")` is detectable. `Page.bringToFront` IS allowed (it's a real OS-level activation, and `cdp-eval.sh` already calls it).
- **NEVER call `browser-use close --all`.** Daemon Chrome lifetime is launchd's responsibility.
- **Cadence:** between clicks, sleep a *random* 3–6 seconds. No metronome timing. Run `sleep $(awk 'BEGIN{srand(); print 3+rand()*3}')` between clicks.

If you encounter something this list doesn't cover and you're tempted to click it, the answer is to bail with `kind:"challenge"` + a screenshot, not to improvise.

## Inputs

- **Browser**: daemon Chrome on `http://127.0.0.1:19223` (CDP). Persistent profile holds Chase + Amex cookies. Both issuers each have ONE tab open.
- **Dedup files** under `~/.claude/skills/credit-card-offers/state/`:
  - `chase-activated.json` — array of `{url, merchant, deal, ...}`. `url` is the dedup KEY — `"chase::<offer_id_from_url>"` is the recommended shape.
  - `amex-activated.json` — same shape; key is `"<card_label>::<merchant>::<deal>"` composite.
- **Telegram bot token**: parse from `~/.claude/channels/telegram/.env` (key `TELEGRAM_BOT_TOKEN`).
- **Telegram chat_id**: `7953915703`.
- **Caps:** `AMEX_MAX_CLICKS` (default 25 — start conservative; raise after a week of clean fires), `CHASE_MAX_CLICKS` (default 25).

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

**Step 2.2 — The click loop.** Up to `AMEX_MAX_CLICKS` (default 25):

The Add button has `[data-testid="merchantOfferListAddButton"]` with empty innerText (icon button). To identify *which* offer the next button corresponds to, walk up the parent chain from the button to the per-offer container (the div with `border` in its class). Lines of that container's innerText: line 0 = merchant, line 1 = deal description.

**Each iteration** does three things — extract, dedup-check, click+verify:

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
  return { merchant: lines[0] || "<unknown>", deal: lines[1] || "" };
})())' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
```

If `value` is the JSON string `"null"` (i.e. no more Add buttons remain): exit the loop normally — you've processed everything.

b. **Dedup check.** Build key `"<cardLabel>::<merchant>::<deal>"`. If it's in `$AMEX_ACTIVATED`, mark this button so the next iteration doesn't pick it up, then continue:
```bash
TARGET_URL_SUBSTRING=americanexpress.com \
EXPRESSION='document.querySelector("[data-testid=merchantOfferListAddButton]:not([data-cards-skip])")?.setAttribute("data-cards-skip", "1"); "marked"' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
```

c. **Click + verify.** Read the BEFORE count, click, jittered wait, read AFTER count:
```bash
BEFORE=$(TARGET_URL_SUBSTRING=americanexpress.com \
  EXPRESSION='document.querySelectorAll("[data-testid=merchantOfferListAddButton]").length' \
  /Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh | /usr/bin/python3 -c "import sys,json; print(json.loads(sys.stdin.read())['value'])")

TARGET_URL_SUBSTRING=americanexpress.com \
EXPRESSION='(() => {
  const btn = document.querySelector("[data-testid=merchantOfferListAddButton]:not([data-cards-skip])");
  if (!btn) return "no-button";
  btn.scrollIntoView({block:"center", behavior:"instant"});
  btn.click();
  return "clicked";
})()' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh

sleep $(awk 'BEGIN{srand(); print 3+rand()*3}')

AFTER=$(TARGET_URL_SUBSTRING=americanexpress.com \
  EXPRESSION='document.querySelectorAll("[data-testid=merchantOfferListAddButton]").length' \
  /Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh | /usr/bin/python3 -c "import sys,json; print(json.loads(sys.stdin.read())['value'])")
```

Expected: `AFTER == BEFORE - 1`. If yes, record `{merchant, deal, card_id: cardLabel}` to your in-memory activated list. If no, the click didn't take — screenshot via `cdp-screenshot.sh` (LABEL=amex-verify-fail) + record the failure and **bail the Amex section entirely** (don't keep clicking blind).

Stop conditions: hit `AMEX_MAX_CLICKS`, ran out of buttons, OR encountered a verification failure.

### 3. Activate Chase offers

Chase is a 2-step flow (hub → detail → Add → back). And critically: Chase aggressively logs you out of the offers area. `/dashboard/overview` being logged in doesn't mean `/offers/offerHub` is — Chase requires step-up auth for offers specifically.

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

Otherwise navigate to the offers hub:
```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='location.href = "https://secure.chase.com/web/auth/dashboard#/dashboard/offers/offerHub"; "navigating"' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
sleep 8  # Chase SPA hash-routing resolves to /merchantOffers/offer-hub; slow.
```

Re-probe. Expected end state: URL contains `offer-hub`, `bodyLen > 500`, and at least one element matching `[data-testid*="offerHub-tile" i]` exists.

**Step 3.2 — Click loop.** Up to `CHASE_MAX_CLICKS` (default 25):

a. **Enumerate hub tiles**:
```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='JSON.stringify(Array.from(document.querySelectorAll("[data-testid*=offerHub-tile]")).map((t, i) => ({
  index: i,
  testid: t.getAttribute("data-testid"),
  text: (t.innerText || "").trim().slice(0, 200),
})))' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
```

If the array is empty, no more tiles — exit Chase section.

b. **Click the first tile**, which navigates to the detail page:
```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='(() => {
  const tile = document.querySelector("[data-testid*=offerHub-tile]");
  if (!tile) return "no-tile";
  tile.scrollIntoView({block:"center"});
  tile.click();
  return "clicked";
})()' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
sleep 3  # detail page navigation
```

c. **On the detail page, inspect:**
```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='JSON.stringify((() => {
  const merchant = (document.querySelector("h1, h2")?.innerText || "").trim().slice(0, 100);
  const offerAmount = (document.querySelector("[data-testid*=offerAmount]")?.innerText || "").trim();
  const alreadyAdded = !!document.querySelector("[data-testid=added-to-card-alert]");
  const addBtn = Array.from(document.querySelectorAll("button, [role=button]")).find(b => /^add to card$|enroll|^activate offer$/i.test((b.innerText || "").trim()));
  return {
    url: location.href,
    merchant, offerAmount, alreadyAdded,
    addBtnText: addBtn ? (addBtn.innerText || "").trim() : null,
    addBtnTestid: addBtn ? addBtn.getAttribute("data-testid") : null,
  };
})())' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
```

Branch:
- `alreadyAdded=true`: record `skipped_already_added` and skip to step (g) [navigate back].
- `addBtnText` is null: this offer's detail page doesn't have a recognizable Add button. Screenshot, record `kind:"dom"`, bail Chase.
- Otherwise continue.

d. **Dedup check.** The URL contains the offer ID (e.g., `offer-activated/CDLX:1000290073:1000290073-c`). Use it as the dedup key prefixed with `chase::`. If in `$CHASE_ACTIVATED`, record `skipped_dedup` and skip to step (g).

e. **Click the Add button:**
```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='(() => {
  const btn = Array.from(document.querySelectorAll("button, [role=button]")).find(b => /^add to card$|enroll|^activate offer$/i.test((b.innerText || "").trim()));
  if (!btn) return "no-button";
  btn.scrollIntoView({block:"center"});
  btn.click();
  return "clicked";
})()' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
sleep $(awk 'BEGIN{srand(); print 3+rand()*3}')
```

f. **Verify** — expect the `added-to-card-alert` to appear:
```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='!!document.querySelector("[data-testid=added-to-card-alert]")' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
```

If `value=true`: record `{merchant, deal: offerAmount, offer_id: <from url>}` to your chase activated list. If `false`: screenshot, record failure, bail Chase.

g. **Navigate back to hub** (direct URL — don't trust history.back on Chase's hash router):
```bash
TARGET_URL_SUBSTRING=chase.com \
EXPRESSION='location.href = "https://secure.chase.com/web/auth/dashboard#/dashboard/offers/offerHub"; "navigating"' \
/Users/pattybot/dotfiles/cards/bin/lib/cdp-eval.sh
sleep 5
```

After activation, the tile may have moved or been removed. Re-enumerate (step a) and pick the FIRST tile each iteration — don't trust prior indices.

### 4. Determine overall outcome

After both issuers run:
- **Both succeeded**: standard digest, Telegram, advance state.
- **Partial** (one auth-walled/errored, other succeeded): digest with a "couldn't reach <issuer>" section; advance `last-success.json` with the succeeded counts; ALSO write `last-failure.json` with `kind:"partial"` and the failing issuer's sub-kind.
- **Both failed**: do NOT Telegram. Write `last-failure.json` and exit.
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
- `kind: "both_failed"` — no Telegram. Operator finds it in logs.
- `kind: "telegram"` — Telegram failure even after the plain-text retry.
- `kind: "empty"` — zero new across both issuers, no failures. Treated as success.
- `kind: "visibility"` — `document.visibilityState !== "visible"` on the issuer's tab. Bot Chrome backgrounded.

Hard-fail cases (auth/mfa/challenge/dom/both_failed): do NOT advance `last-success.json`. Partial DOES advance (with the successful counts) AND writes `last-failure.json`.

## What NOT to do

Restating the hard rules and adding observed-mistake patterns:

- **Do not spawn a fresh `browser-use` Chrome.** Always attach via direct CDP to port 19223.
- **Do not call `browser-use close --all`.**
- **Do not log in programmatically.**
- **Do not type into any input field.**
- **Do not click anything outside activate-offer buttons** (Amex) or **offer tiles / Add buttons on detail pages** (Chase). No modal-dismiss clicks. No "Continue" / "Got it" / "Skip".
- **Do not retry a failed click.** One click, one verify, move on.
- **Do not run more often than daily.** The plist is 03:00 PT daily for a reason.
- **Do not fake foreground state via `Page.setWebLifecycleState`.** `Page.bringToFront` is allowed and `cdp-eval.sh` already calls it.
- **Do not advance `last-success.json` on Telegram failure.**
- **Do not send a Telegram error message when Telegram itself is the failure.**
- **Do not send a Telegram message on `both_failed`.**
- **Do not write to `state/keepalive-events.jsonl`, `state/auth-notify-cooldown.json`, or `state/fire-in-progress.lock`.** Those are owned by `cards-keepalive.sh` and `cards-fire.sh` respectively. Your writes go to `last-success.json`, `last-failure.json`, `pending.json`, and the dedup files only.
- **Do not bake DOM selectors into bash files.** The selectors in this SKILL.md (e.g. `merchantOfferListAddButton`, `offerHub-tile`, `added-to-card-alert`) are *observations*, not contracts. When a selector returns 0 unexpectedly, probe to find the new pattern at runtime; if a fundamental shift, update this SKILL.md guidance.
- **Do not run the keepalive inline.** Session-keepalive is a separate launchd job (`com.pattybot.cards-keepalive`); your only interaction is `state/fire-in-progress.lock` (the fire wrapper writes it at start and removes via trap).
