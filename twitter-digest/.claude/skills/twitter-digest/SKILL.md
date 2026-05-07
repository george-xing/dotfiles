---
name: twitter-digest
description: Generate the X (Twitter) digest — attaches via CDP to a long-running bot Chrome daemon (launchctl-managed, persistent profile, debug port 9222), scrolls x.com/home, themes content since the last run (AI / Startups / NYC / Random), separately flags + summarizes any long-form X Articles, and delivers to Telegram. Fires twice daily via launchd — morning at 08:00 ET (overnight recap) and evening at 22:00 ET (daytime recap). Use when the user asks for "twitter digest", "morning digest", "evening recap", "X digest", "what's new on twitter", or when fired by launchd.
---

# Twitter Digest

Twice-daily job: attach to the persistent bot Chrome on `127.0.0.1:9222`, scroll x.com/home, summarize content since the previous run into themes, push to Telegram. The two scheduled fires are 08:00 ET (covers overnight, ~10h window since the prior 22:00 fire) and 22:00 ET (covers daytime, ~14h window since the prior 08:00 fire). Each run reads the cutoff from `state/last-success.json` so the windows automatically hand off to each other without overlap. Designed to be fired headlessly via `claude -p` from launchd, but works fine when invoked interactively.

## Inputs (from environment / state)

- **Browser**: long-running daemon Chrome managed by the `com.pattybot.twitter-bot-chrome` LaunchAgent, listening on `http://127.0.0.1:9222` for CDP. Persistent user-data-dir at `$HOME/Library/Application Support/twitter-bot-chrome`. Auth state (X cookies) lives in that profile and is set by manual sign-in via the bot Chrome window — NOT by cookie import. **Never spawn a new browser-use Chrome with `--profile` or `--headed` — always attach via `--cdp-url`.**
- **Lookback window**: read `state/last-success.json#runAt` if present and use as cutoff. Else 12h ago. Cap at 24h regardless.
- **Telegram bot token**: parse from `~/.claude/channels/telegram/.env` (key `TELEGRAM_BOT_TOKEN`).
- **Telegram chat_id**: `7953915703`.
- **Themes**: read `references/themes.md` before composing — edits to that file flow into the next digest with no other change.

## Workflow

### 1. Read prior state to compute cutoff

```bash
LAST_SUCCESS=~/.claude/skills/twitter-digest/state/last-success.json
if [ -s "$LAST_SUCCESS" ]; then
  CUTOFF_ISO=$(python3 -c "import json; print(json.load(open('$LAST_SUCCESS'))['runAt'])")
else
  CUTOFF_ISO=$(python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) - timedelta(hours=12)).isoformat())")
fi
# Cap at 24h
MIN_CUTOFF=$(python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) - timedelta(hours=24)).isoformat())")
CUTOFF_ISO=$(python3 -c "print(max('$CUTOFF_ISO', '$MIN_CUTOFF'))")
echo "cutoff: $CUTOFF_ISO"
```

You'll use `CUTOFF_ISO` to recognize when scrolled tweets pass the boundary (X's UI shows relative timestamps like "3h", "1d" — convert mentally).

### 2. Attach to daemon Chrome and verify

The daemon is launchctl-managed; the wrapper has already verified `127.0.0.1:9222` responded before invoking you. Don't re-launch Chrome, don't `browser-use close --all`. Just attach and navigate:

```bash
browser-use --cdp-url http://127.0.0.1:9222 open https://x.com/home
sleep 4
```

Verify both auth state AND visibility in one probe:

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "
  JSON.stringify({
    title: document.title,
    vis: document.visibilityState,
    iw: innerWidth,
    ih: innerHeight,
    hasPrimaryColumn: !!document.querySelector('[data-testid=\\"primaryColumn\\"]'),
    hasLoginWall: !!document.querySelector('a[href=\\"/login\\"]') || !!document.querySelector('a[href=\\"/i/flow/login\\"]')
  })
"
```

Expected: `vis === "visible"`, `iw > 0`, `ih > 0`, `title === "Home / X"`, `hasPrimaryColumn === true`, `hasLoginWall === false`.

**Failure semantics — hard fail with the matching `kind`, do NOT paper over:**

- `vis !== "visible"` or `iw === 0` → daemon Chrome window is backgrounded behind another app. Write `state/last-failure.json` with `{ "kind": "visibility", "at": "<iso>", "message": "bot Chrome window not foreground; vis=<state>, iw=<n>, ih=<n>" }` and exit non-zero. Do **NOT** apply `Page.setWebLifecycleState("active")` or `Page.bringToFront` to fake foreground — the resulting state-mismatch (page lifecycle says active, OS still says backgrounded) is itself a detection signal we're trying to remove. Operator action: bring the bot Chrome window to the front (Mission Control, click the window, etc.) and re-fire.
- `hasLoginWall === true` or `title` matches the public landing → cookies expired. Write `state/last-failure.json` with `{ "kind": "auth", "at": "<iso>", "message": "bot Chrome session logged out; sign in via the bot window" }` and exit. Do NOT attempt to log in. Operator action: focus the bot Chrome window, navigate to `https://x.com/i/flow/login`, sign in. The cookies persist in the daemon's profile across restarts.
- `hasPrimaryColumn === false` despite `vis === "visible"` and no login wall → DOM rendered but timeline container missing. Likely an X UI change; write `kind: "dom"` failure and exit. Operator updates selectors in this skill.

### 2b. Ensure For You tab is active

x.com/home usually lands on "For You" by default — what this digest consumes (matches what the user reads). Defensive click (no-op if already active):

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "
  const tabs = document.querySelectorAll('[role=\\"tablist\\"] [role=\\"tab\\"]');
  const fyt = Array.from(tabs).find(t => /for you/i.test(t.innerText));
  fyt?.click();
  ({clicked: !!fyt})
"
sleep 2
```

### 3. Scroll loop

Stop conditions, whichever first:
- **3 minutes wall-clock elapsed** (recall target — empirically yields ~140-160 fresh tweets on For You)
- **3 consecutive scrolls produce zero new unique tweets** (stall — invoke step 3a screenshot-then-judge before treating as exhaustion)
- 150 scroll iterations (safety net)

**Do NOT use stale-percentage-based early termination.** Empirical per-scroll tracing on For You shows `stale%` oscillates wildly between 30% and 100% even while meaningful fresh content is still being surfaced — the algorithm interleaves pockets of old and new. A "3 consecutive scrolls > N% stale" rule fires on the stale pockets and misses the fresh ones right after.

Treat tweets with **no `timeISO`** as promoted/structurally-anomalous and drop them.

Individual tweets older than the cutoff are still extracted but **filtered at triage time**, not at scroll time.

**Scrolling on x.com**: `browser-use scroll` is a no-op (X's virtualized timeline ignores synthetic wheel events). Use `eval` with `window.scrollBy`:

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "window.scrollBy(0, 1500)"
```

If `window.scrollBy` stops yielding new tweets after several attempts, kick the observer with `scrollIntoView` on the last visible tweet:

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "
  const tweets=document.querySelectorAll('article[data-testid=\\"tweet\\"]');
  tweets[tweets.length-1]?.scrollIntoView({block:'end'});
"
```

If after 3 scroll attempts no new tweets appear, **do not immediately ship** — invoke step 3a (screenshot-then-judge). The underlying cause may be a dismissable modal, a transient render issue, an auth-wall flip mid-run, or genuine feed exhaustion / rate limit, and the correct action differs by case.

After each scroll, pause 1-2s for content to load, then grab a batch via `eval`:

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "
  Array.from(document.querySelectorAll('article[data-testid=\\"tweet\\"]')).slice(0, 60).map(a => {
    const author = a.querySelector('[data-testid=\\"User-Name\\"]')?.innerText || '';
    const text = a.querySelector('[data-testid=\\"tweetText\\"]')?.innerText || '';
    const timeEl = a.querySelector('time');
    const timeISO = timeEl?.getAttribute('datetime') || null;
    const statusHref = timeEl?.closest('a')?.getAttribute('href')
      || a.querySelector('a[href*=\\"/status/\\"]')?.getAttribute('href')
      || null;
    const statusUrl = statusHref ? ('https://x.com' + statusHref) : null;
    const articleAnchor = a.querySelector('a[href*=\\"/article/\\"], a[href*=\\"/i/article/\\"]');
    const articleLink = articleAnchor ? ('https://x.com' + articleAnchor.getAttribute('href')) : null;
    const containerText = a.innerText || '';
    const isPromoted = /\\bPromoted\\b|\\bAd\\b(?=$|\\n)/.test(containerText) || !!a.querySelector('[data-testid=\\"placementTracking\\"]');
    return {author, text: text.slice(0, 800), timeISO, statusUrl, articleLink, isPromoted};
  })
"
```

**Hard filter: drop every tweet where `isPromoted === true` before triage.** Promoted posts are ads.

**Soft filter (during theming): drop marketing / influencer-shill content** even when not formally promoted. See `references/themes.md` → "Triage rules".

Selector notes:
- `article[data-testid="tweet"]` — canonical tweet container
- `[data-testid="tweetText"]` — body text
- `[data-testid="User-Name"]` — author block
- `time[datetime]` — exact ISO timestamp
- `/article/` URL pattern — long-form X Articles (may evolve; adapt if you spot a different pattern)

Accumulate batches; dedupe by `(author, text)` since later scrolls re-emit earlier tweets.

### 3a. Stall recovery (screenshot-then-judge)

When the scroll loop stalls — `window.scrollBy` followed by the `scrollIntoView` fallback both produced 3 consecutive zero-new-tweet iterations — capture a screenshot and inspect it visually before deciding to ship, recover, or hard-fail. Predetermined DOM checks ("is there a `[role=dialog]`?") fail every time X re-skins a modal; visual judgment generalizes.

```bash
SCREENSHOT="/tmp/twitter-digest-stall-$(date +%Y%m%dT%H%M%S).png"
browser-use --cdp-url http://127.0.0.1:9222 screenshot "$SCREENSHOT"
```

Then *read the image yourself* and map what you see to one row in this table:

| What you see | Action |
|---|---|
| Empty timeline / repeated tweets / "you're all caught up" / "see new posts" pill / no obvious obstruction | **Ship.** Treat as normal end-of-loop (feed exhaustion or rate-limit). Proceed to step 4 with the tweets accumulated so far. |
| Modal, dialog, banner, snooze prompt, "verified is here" promo, birthday card, year-in-review, or any other interstitial obstructing the timeline | **Press Escape once**, sleep 1-2s, reset the consecutive-stall counter, retry the scroll loop. If stall recurs after Esc, escalate via this same table on the next stall — but never press Esc twice in a row at one stall event. |
| Login wall / "Sign up to continue" / OAuth flow / "Log in to X" copy | **Hard-fail `kind: "auth"`** with the screenshot path. Cookies expired mid-run; operator re-signs-in via the bot Chrome window. |
| Page chrome looks fundamentally different from a normal X home (no `primaryColumn`, completely different layout, error page, "this site can't be reached") | **Hard-fail `kind: "dom"`** with the screenshot path. Operator updates selectors. |
| Black render, blank page, or screenshot is mostly empty pixels | **Hard-fail `kind: "visibility"`** with the screenshot path. Window dropped foreground or display surface mid-scrape (rare with the dummy plug). |
| Genuinely uncertain — the screen shows something but you can't classify it confidently | **Hard-fail `kind: "stall"`** with the screenshot path. Operator inspects manually. |

**Bounded action set during stall recovery — only these mutating actions are sanctioned:**

1. `Escape` keystroke (at most once per stall event, only on the modal-class row above).
2. Continue scrolling via the existing `window.scrollBy` / `scrollIntoView` mechanics.
3. Hard-fail with a categorized kind (writes `state/last-failure.json` and exits).

**Specifically forbidden:**

- Clicking any button, link, or interactive element by selector — even ones that look obviously dismiss-y like "Got it", "Skip", "Maybe later", "Continue". Deterministic-button-click on every fire is a behavioral signature; auto-clicking "Accept" on a TOS modal commits the operator to terms unread; auto-clicking "Continue" on consent flows may grant data sharing.
- Typing into any input.
- Submitting any form.
- Calling `location.reload()` or otherwise reloading the page.
- Navigating away from `x.com/home` (article URL navigation in step 4 is the only sanctioned exception).

Esc is the only sanctioned UI mutation because (a) it's the universal human modal-close keystroke that's used by every keyboard-fluent person, (b) it doesn't depend on brittle close-button selectors that drift with each X redesign, (c) it no-ops harmlessly on non-modal pages, and (d) capping at one Esc per stall event prevents any repeated-keystroke pattern.

CDP key dispatch for Escape (use `eval` for consistency with the rest of the skill):

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "
  document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', code:'Escape', keyCode:27, which:27, bubbles:true, cancelable:true}));
  document.dispatchEvent(new KeyboardEvent('keyup',   {key:'Escape', code:'Escape', keyCode:27, which:27, bubbles:true, cancelable:true}));
"
sleep 2
```

X's modal close handlers listen for `keydown:Escape` on document or window — synthetic `KeyboardEvent` dispatch satisfies them. After Esc, sleep 1-2s for the modal close animation, then resume the scroll loop with a fresh stall counter.

### 4. Pull long-form articles (after scroll loop ends)

X Articles are uncommon. When one appears, the article-page DOM may differ; be defensive.

For each unique `articleLink`:

```bash
browser-use --cdp-url http://127.0.0.1:9222 open "$ARTICLE_URL"
sleep 3
browser-use --cdp-url http://127.0.0.1:9222 eval "
  const bodyEl = document.querySelector('[data-testid=\\"longformText\\"]')
              || document.querySelector('[data-testid=\\"article-body\\"]')
              || document.querySelector('article')
              || document.body;
  ({
    title: document.querySelector('h1')?.innerText
        || document.querySelector('[data-testid=\\"article-title\\"]')?.innerText
        || document.title,
    author: document.querySelector('[data-testid=\\"User-Name\\"]')?.innerText
         || document.querySelector('[data-testid=\\"article-author\\"]')?.innerText
         || '',
    body: bodyEl.innerText.slice(0, 12000),
    bodyLen: bodyEl.innerText.length
  })
"
```

Sanity check: if `bodyLen < 500` and the URL still resolves to the article, selectors missed the body container. Don't summarize from a tiny body — instead screenshot for the operator (`browser-use --cdp-url http://127.0.0.1:9222 screenshot /tmp/twitter-digest-article-debug.png`) and emit a one-line "📰 extraction failed" entry, then continue. Operator updates selectors next iteration.

Otherwise summarize each article in 2-3 sentences. Capture `{ title, author, url, summary }`.

### 5. Theme and compose

Read `references/themes.md` and apply triage rules. Compose HTML (NOT Markdown — Telegram's legacy Markdown breaks on `_*[` in tweet text; HTML mode is more predictable):

Pick the header based on local clock hour at compose time:
- `4 ≤ hour < 16` (morning fires, primarily 08:00 run): `🌅 <b>Morning digest — <date></b>`
- Otherwise (evening fires, primarily 22:00 run): `🌆 <b>Evening recap — <date></b>`

Everything below the header is the same regardless of which fire ran.

```
<🌅 Morning digest | 🌆 Evening recap> — <date>

🤖 <b>AI</b>
• <a href="<statusUrl>">@author tweeted</a>: <one-line summary>
• <a href="<statusUrl>">@author posted</a>: <one-line summary>

💼 <b>Startups &amp; VC</b>
• …

🗽 <b>NYC</b>
• …

✨ <b>Random Interesting</b>
• …

📰 <b>Long-form articles</b>
• <b>&lt;title&gt;</b> — <a href="<articleLink>">@author</a>
  &lt;2-3 sentence summary&gt;

—
&lt;N&gt; tweets scanned · &lt;M&gt; minutes scrolled · &lt;K&gt; articles read

<i>Summaries of tweets surfaced overnight; positions are the posters', not verified.</i>
```

**Per-bullet link rule**: wrap `@author tweeted/posted` attribution in `<a href="<statusUrl>">` so a tap on the attribution deep-links into the tweet. Don't add a separate link/arrow at the end. For long-form articles, wrap `@author` in the article link rather than adding a raw URL line. Telegram still renders these as clickable with `disable_web_page_preview=true`.

If a tweet has no `statusUrl` (rare), drop it entirely rather than emitting an unattributed line.

**HTML escaping rules** (apply to every dynamic string before insertion): `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`. Apply LAST, after composition, so your `<b>` tags survive.

Telegram HTML supports a small whitelist: `<b>`, `<i>`, `<u>`, `<s>`, `<a href="...">`, `<code>`, `<pre>`. Don't use anything else.

**Framing note**: always attribute — "@author tweeted..." / "@author posted..." / "per @account" — rather than first-person fact claims. Tweets are positions; the digest is a pointer to what they said. The italic disclaimer at the bottom of the digest reinforces this and avoids content-integrity blocks on the `claude -p` side.

If a theme has zero items, omit the section entirely. If literally no overnight content qualifies, send a single line `Nothing notable on X 🥱` instead of a multi-section empty digest.

### 6. Pre-send: write pending state

Before calling Telegram, write `state/pending.json` so a crash mid-send leaves a recoverable trace:

```bash
PENDING=~/.claude/skills/twitter-digest/state/pending.json
NOW=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
cat > "$PENDING" <<EOF
{"runAt": "$NOW", "scrolledFor": $SCROLL_SECONDS, "tweetCount": $TWEET_COUNT, "articleCount": $ARTICLE_COUNT, "telegramOk": null}
EOF
```

### 7. Deliver to Telegram

**Critical**: route the digest payload from a file and save Telegram's response to a file too. Do NOT capture the response via shell `$(...)` — the digest contains emoji and non-ASCII text, Telegram echoes it back, and shell interpolation of multi-byte UTF-8 can mangle bytes, causing a local parse error that looks like a send failure and triggers a spurious retry. **Known duplicate-message bug** — if you introduce a shell-var retry path you'll double-send.

```bash
RUN_DIR=/tmp/twitter-digest-run
mkdir -p "$RUN_DIR"

# The composed HTML digest should already be in $RUN_DIR/digest.html.

TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' ~/.claude/channels/telegram/.env | cut -d= -f2-)

curl -sS "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d chat_id=7953915703 \
  --data-urlencode "text@${RUN_DIR}/digest.html" \
  -d parse_mode=HTML \
  -d disable_web_page_preview=true \
  -o "${RUN_DIR}/tg_response.json"
CURL_EXIT=$?

OK=$(python3 -c "
import json, sys
try:
    r = json.load(open('${RUN_DIR}/tg_response.json'))
    print(r.get('ok', False))
except Exception as e:
    print('parse_error:' + str(e), file=sys.stderr)
    print(False)
")
```

**Retry ONLY on `OK=False` with a well-formed JSON response (Telegram said `ok: false`).** Do NOT retry on:
- curl non-zero exit (network error — retry useless if network is down)
- Local Python parse errors (shell-encoding artifacts, not send failures)
- Empty response file (transport issue, not payload)

If `OK=False` with a real Telegram error:
- Inspect description. Common: "can't parse entities" (HTML tag slipped through unescaped), "message is too long" (>4096 chars).
- One retry, plain-text fallback: strip HTML tags from `digest.html` to produce `digest.txt`, drop `parse_mode`, re-send with `--data-urlencode "text@${RUN_DIR}/digest.txt"`.
- If retry also returns `ok: false`: write the failure to `state/last-failure.json` and STOP. Do not send another Telegram alert.

### 8. On success: atomic finalize

```bash
PENDING=~/.claude/skills/twitter-digest/state/pending.json
LAST_SUCCESS=~/.claude/skills/twitter-digest/state/last-success.json
python3 -c "
import json
d = json.load(open('$PENDING'))
d['telegramOk'] = True
json.dump(d, open('$PENDING.tmp', 'w'))
" && mv "$PENDING.tmp" "$LAST_SUCCESS" && rm -f "$PENDING"
```

**Do NOT** call `browser-use close --all` — the daemon Chrome is launchd-managed and must keep running. Closing it would force a daemon respawn and lose the active tab state.

Note: cutoff for the next run derives from `last-success.json`. `pending.json` is ignored by step 1 — it's only a forensic crumb.

## Dry-run mode

If invoked with "dry-run" or "--dry-run" in the prompt, do everything *except* steps 6-8 — print the composed digest HTML to stdout, skip pending.json, skip Telegram, skip last-success update. Useful for iterating on themes/format without spamming the chat.

Do NOT call `browser-use close --all` even in dry-run — the daemon Chrome stays up always.

## Failure handling

Categorize failures and write `state/last-failure.json` with `{kind, at, message}` plus optional `screenshot` — an absolute path to a CDP-captured PNG of the visible state at failure time. Step 3a always captures screenshots for stall-derived failures; step 4 already does for article-extraction failures; step 2's hard-fails may include them when useful. Operators read the screenshot to disambiguate similar failure modes (e.g. "is this `auth` or `dom`?" — the image makes it obvious).

`kind` values:

- `kind: "visibility"` — bot Chrome window not foreground (`vis !== "visible"` after navigation). Operator brings the window to front and re-fires. Don't fake foreground via CDP.
- `kind: "auth"` — login wall present in the bot Chrome (cookies expired). Operator opens the bot Chrome window, signs into X manually, no reseed script needed. Don't try to log in programmatically — X flags automated logins.
- `kind: "dom"` — visibility OK, no login wall, but `primaryColumn` missing. Likely an X UI change. Operator updates the selectors in this skill.
- `kind: "telegram"` — Telegram delivery failed even after the plain-text retry. Captures the response description.
- `kind: "empty"` — feed truly returned zero tweets in the cutoff window (rare). Treated as success: write `last-success.json` with `tweetCount: 0` so the cutoff advances; send the `Nothing notable 🥱` message.
- `kind: "stall"` — scroll loop stalled and the step-3a screenshot didn't match any recoverable or pre-categorized state. Operator inspects the screenshot at `last-failure.json#screenshot`. Common causes: a new modal variant worth a future Esc-class entry, a rate-limit pattern not yet seen, or an X UI variant the classifier in 3a didn't recognize. After diagnosing, operator may update 3a's classification table and re-fire — the failure-kind taxonomy is intentionally evolving rather than fixed.

In all hard-fail cases, do NOT advance `last-success.json` — the next run must see the same cutoff so it doesn't silently skip the window.

In all hard-fail cases, do NOT send a Telegram alert about the failure. Operator finds it in the log.

## What NOT to do

- **Do not spawn a fresh browser-use Chrome.** Always attach via `--cdp-url http://127.0.0.1:9222`. Spawning would create an ephemeral profile with a different cookie store than the daemon, defeating the entire architecture.
- **Do not call `browser-use close --all`.** That kills sessions; the daemon Chrome's lifetime is launchd's responsibility, not the skill's.
- **Do not try to log in programmatically.** X aggressively flags automated logins; operator must sign in manually via the bot Chrome window.
- **Do not fake the foreground state.** The CDP `Page.setWebLifecycleState("active")` and `Emulation.setVisibleSize` hacks produce a state-mismatch (page lifecycle says active, OS says backgrounded) that's itself detectable. Hard-fail and require operator to actually bring the window foreground.
- **Stay inside the bounded action set during stall recovery.** Per step 3a, the only sanctioned mutating actions on stall are: a single Esc keystroke per stall event, continue scrolling via `window.scrollBy` / `scrollIntoView`, or hard-fail with a categorized kind. Do NOT click buttons by selector — even ones that look obviously dismiss-y. Deterministic clicks are a behavioral signature, and auto-clicking "Accept" / "Continue" / "I agree" on TOS, consent, or age-verification modals commits the operator to terms they haven't reviewed. Do NOT type into inputs, submit forms, call `location.reload()`, or navigate away from `x.com/home` (article URL navigation in step 4 is the only sanctioned exception).
- **Do not hammer X.** If you hit a rate-limit indicator, stop scrolling immediately, summarize what you have, deliver, and exit.
- **Do include tweet URLs in the themed sections, but wrapped in the `@author tweeted/posted` attribution link only.** Don't emit a separate URL line.
- **Do not advance state on Telegram failure.** A failed send must NOT update `last-success.json`.
- **Do not send a Telegram error message when Telegram itself is the failure.** Log locally and exit.
