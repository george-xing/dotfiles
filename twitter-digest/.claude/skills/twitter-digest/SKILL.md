---
name: twitter-digest
description: Generate the X (Twitter) digest — scrolls the user's authenticated home timeline (via the browser-use skill, headed Chrome with imported X cookies), themes content since the last run (AI / Startups / NYC / Random), separately flags + summarizes any long-form X Articles, and delivers to Telegram. Fires twice daily via launchd — morning at 08:00 ET (overnight recap) and evening at 22:00 ET (daytime recap). Use when the user asks for "twitter digest", "morning digest", "evening recap", "X digest", "what's new on twitter", or when fired by launchd.
---

# Twitter Digest

Twice-daily job on x.com/home: scroll, summarize content since the previous run into themes, push to Telegram. The two scheduled fires are 08:00 ET (covers overnight, ~10h window since the prior 22:00 fire) and 22:00 ET (covers daytime, ~14h window since the prior 08:00 fire). Each run reads the cutoff from `state/last-success.json` so the windows automatically hand off to each other without overlap. Designed to be fired headlessly via `claude -p` from launchd, but works fine when invoked interactively.

## Inputs (from environment / state)

- **Browser:** `browser-use --headed --profile "Patty"`. Always headed — X serves a logged-out landing to headless. The Mac mini fires this at 8am unattended; a visible Chrome window is fine.
- **Cookies:** `~/.claude/skills/twitter-digest/state/x-cookies.json`. Exported once via `browser-use cookies export` after a manual login. Imported every fire to authenticate the session.
- **Lookback window:** read `state/last-success.json` if present and use its `runAt` as the cutoff. Else 12h ago. Cap at 24h regardless — never scroll back further than that.
- **Telegram bot token:** parse from `~/.claude/channels/telegram/.env` (key `TELEGRAM_BOT_TOKEN`).
- **Telegram chat_id:** `7953915703`.
- **Themes:** read `references/themes.md` before composing — edits to that file flow into the next digest with no other change.

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

### 2. Open the timeline (authenticated)

```bash
browser-use close --all
sleep 2
browser-use --headed --profile "Patty" open https://x.com
sleep 2
browser-use cookies import ~/.claude/skills/twitter-digest/state/x-cookies.json
browser-use open https://x.com/home
sleep 4
```

**Viewport & focus fix** (required — without it, scrapes silently return empty):

`browser-use --headed` sometimes hands back a tab where `visibilityState === "hidden"` and `innerWidth/innerHeight === 0`, even though the OS-level window is 1920×1080. In that state X's virtualized timeline renders nothing, every `eval` returns empty, and you get a zero-tweet digest. Force the page to a real viewport via CDP before doing any scraping.

Grab the CDP URL from browser-use and poke the page directly:

```bash
CDP_URL=$("$BROWSER_USE_BIN" --json sessions 2>/dev/null | python3 -c "import sys,json; s=json.load(sys.stdin); print(s.get('default',{}).get('cdp_url') or s[0].get('cdp_url',''))" 2>/dev/null || true)
# If the above doesn't yield a URL, fall back: browser-use's daemon exposes
# the CDP URL in `browser-use doctor` output under 'daemon' or 'browser'.
```

If `CDP_URL` is resolvable, open a WebSocket (or use `curl http://127.0.0.1:<port>/json` to list targets and pick the x.com tab's `webSocketDebuggerUrl`), then send these commands on that target:

```
{"id":1, "method":"Page.bringToFront"}
{"id":2, "method":"Emulation.setDeviceMetricsOverride",
  "params":{"width":1400, "height":1000, "deviceScaleFactor":1, "mobile":false}}
{"id":3, "method":"Emulation.setVisibleSize", "params":{"width":1400, "height":1000}}
```

A tiny Python helper (stdlib + `websocket-client`) handles this. Two important quirks discovered in practice:

1. **`websocket.create_connection` must pass `suppress_origin=True`.** The default `Origin: http://127.0.0.1:<port>` header gets a 403 from Chrome DevTools Protocol.
2. **`Page.setWebLifecycleState → "active"` is the step that actually makes tweets render.** `setVisibleSize` / `setDeviceMetricsOverride` alone fix the dimensions but the page stays frozen until the lifecycle state flips.

```python
import json, urllib.request, websocket
targets = json.loads(urllib.request.urlopen("http://127.0.0.1:<PORT>/json").read())
tgt = next(t for t in targets if "x.com" in t.get("url", ""))
ws = websocket.create_connection(tgt["webSocketDebuggerUrl"], suppress_origin=True)
cmds = [
    ("Page.bringToFront", {}),
    ("Emulation.setDeviceMetricsOverride", {"width":1400,"height":1000,"deviceScaleFactor":1,"mobile":False}),
    ("Emulation.setVisibleSize", {"width":1400,"height":1000}),
    ("Page.setWebLifecycleState", {"state":"active"}),  # <- the critical one
]
for i, (method, params) in enumerate(cmds, 1):
    ws.send(json.dumps({"id": i, "method": method, "params": params}))
    ws.recv()
ws.close()
```

After the viewport fix, verify:

```bash
browser-use eval "JSON.stringify({iw: innerWidth, ih: innerHeight, vis: document.visibilityState, title: document.title, hasPrimaryColumn: !!document.querySelector('[data-testid=\\"primaryColumn\\"]'), hasLoginWall: !!document.querySelector('a[href=\\"/login\\"]')})"
```

Expected: `iw: 1400`, `ih: 1000`, `vis: "visible"`, `title: "Home / X"`, `hasPrimaryColumn: true`, `hasLoginWall: false`.

Failure modes:
- `title: "X. It's what's happening / X"` or `hasLoginWall: true` → cookies expired. Fail fast (see Failure handling below). Do NOT attempt to log in.
- `iw/ih still 0` or `vis: "hidden"` → CDP fix didn't take. Retry once; if still failing, fail fast with `kind: "viewport"` in last-failure.json.

### 2b. Ensure For You tab is active

x.com/home usually lands on "For You" by default, which is what this digest consumes — it matches what the user reads in their own feed. For You is **algorithmic**: it interleaves fresh overnight posts with algorithmic re-injections of older content (1-3 days back). That's fine; the per-tweet `timeISO` check at triage time filters out anything outside the cutoff. **Do not switch to Following** — Following is chronologically cleaner but doesn't reflect what this user actually reads.

Defensive click (no-op if already active):

```bash
browser-use eval "
  const tabs = document.querySelectorAll('[role=\\"tablist\\"] [role=\\"tab\\"]');
  const fyt = Array.from(tabs).find(t => /for you/i.test(t.innerText));
  fyt?.click();
  ({clicked: !!fyt})
"
sleep 2
```

### 3. Scroll loop

Stop conditions, whichever first:
- **3 minutes wall-clock elapsed** (the recall target — empirically yields ~140-160 fresh tweets on For You)
- **3 consecutive scrolls produce zero new unique tweets** (feed cache is genuinely exhausted — keep scrolling further just wastes time)
- 150 scroll iterations (safety net; ~80 scrolls covers a fresh For You in 3 min, 150 gives 2x headroom)

**Do NOT use stale-percentage-based early termination.** This was the original stop rule and it looked sensible on paper, but empirical per-scroll tracing on For You shows `stale%` oscillates wildly between 30% and 100% even while meaningful fresh content is still being surfaced — the algorithm interleaves pockets of old and new. A "3 consecutive scrolls > N% stale" rule fires on the stale pockets and misses the fresh ones right after. The Apr 21 run kept only 19 of ~130 overnight tweets before this rule was removed. If the algorithm changes and this stops being true, reintroduce a softer threshold (e.g. 8-scroll rolling average of fresh-new-per-scroll < 0.3), but don't do a short-window stale% check.

Treat tweets with **no `timeISO`** as promoted/structurally-anomalous and drop them from the collected set (consistent with the `isPromoted` check below).

Individual tweets older than the cutoff are still extracted but **filtered at triage time**, not at scroll time. A stale tweet seen at scroll 10 doesn't imply anything about what's at scroll 11.

**Scrolling on x.com: `browser-use scroll` is a no-op here.** X's virtualized timeline doesn't respond to the synthetic wheel events that `scroll down` dispatches. Use `browser-use eval` with `window.scrollBy` instead:

```bash
browser-use eval "window.scrollBy(0, 1500); document.documentElement.scrollTop = document.documentElement.scrollHeight;"
```

If `window.scrollBy` also fails to pull more tweets after several iterations (infinite-scroll observer not firing — happens intermittently), try dispatching real wheel events through CDP: open the same WebSocket used for the viewport fix and send `Input.dispatchMouseEvent` with `type: "mouseWheel"` at the timeline's center point. As a last resort, `scrollIntoView` on the last visible tweet often kicks the observer:

```bash
browser-use eval "const tweets=document.querySelectorAll('article[data-testid=\\"tweet\\"]'); tweets[tweets.length-1]?.scrollIntoView({block:'end'});"
```

If after 3 scroll attempts no new tweets appear, stop — likely rate-limit or session signal. Summarize what you have and ship; don't hammer.

After each scroll, pause 1-2s for content to load, then use `browser-use eval` to grab a batch of tweets — faster than per-element calls:

```bash
browser-use eval "
  Array.from(document.querySelectorAll('article[data-testid=\\"tweet\\"]')).slice(0, 60).map(a => {
    const author = a.querySelector('[data-testid=\\"User-Name\\"]')?.innerText || '';
    const text = a.querySelector('[data-testid=\\"tweetText\\"]')?.innerText || '';
    const timeEl = a.querySelector('time');
    const timeISO = timeEl?.getAttribute('datetime') || null;
    // Tweet permalink: the <time> element is wrapped in an <a> whose href is
    // /<user>/status/<id>. Fallback: any descendant 'a[href*=\"/status/\"]'.
    const statusHref = timeEl?.closest('a')?.getAttribute('href')
      || a.querySelector('a[href*=\\"/status/\\"]')?.getAttribute('href')
      || null;
    const statusUrl = statusHref ? ('https://x.com' + statusHref) : null;
    // Long-form X Articles: tweet cards that link to an article page. URL
    // patterns seen in the wild: '/i/article/<id>', '/<user>/article/<id>',
    // sometimes surfaced via a 'card.wrapper' testid. Keep the net wide.
    const articleAnchor = a.querySelector('a[href*=\\"/article/\\"], a[href*=\\"/i/article/\\"]');
    const articleLink = articleAnchor ? ('https://x.com' + articleAnchor.getAttribute('href')) : null;
    // X marks ads with a 'Promoted' label inside the tweet container. Also check
    // data-testid='placementTracking' (internal ad-attribution marker that
    // sometimes appears on ad tweets) as a backstop.
    const containerText = a.innerText || '';
    const isPromoted = /\\bPromoted\\b|\\bAd\\b(?=$|\\n)/.test(containerText) || !!a.querySelector('[data-testid=\\"placementTracking\\"]');
    return {author, text: text.slice(0, 800), timeISO, statusUrl, articleLink, isPromoted};
  })
"
```

**Hard filter: drop every tweet where `isPromoted === true` before it enters the themed triage.** Promoted posts are ads; they never belong in the digest. This is a pre-theming filter, not a triage judgement call.

**Soft filter (applied during theming, not extraction): drop marketing / influencer-shill content** even when not formally promoted. See `references/themes.md` → "Triage rules" for the signal list (affiliate codes, sponsorship disclosures, testimonial threads dressed as stories, hype-pivot-to-product posts). Apply judgement — a founder discussing their product's engineering is legit; a thread that's really an ad in disguise is not.

Selector notes:
- `article[data-testid="tweet"]` — the canonical tweet container.
- `[data-testid="tweetText"]` — the tweet body text.
- `[data-testid="User-Name"]` — the author block (display name + @handle on multiple lines, `innerText` covers both).
- `time[datetime="..."]` — exact ISO timestamp, more reliable than parsing the relative-time text.
- `/article/` URL pattern — long-form X Articles. May change as X evolves; if you spot a different article-card hook (e.g. `data-testid="card.wrapper"` with article semantics), adapt.

Accumulate the per-iteration batches into one collection. Dedupe by `(author, text)` since later scrolls re-emit earlier tweets.

When a tweet's `timeISO` is older than `CUTOFF_ISO`, stop the loop.

### 4. Pull long-form articles (after scroll loop ends)

X Articles are uncommon in most feeds. When one DOES appear, X's article-page DOM may differ from a regular tweet status page, and the URL pattern can change. Be defensive about selectors and prepared to adapt.

For each unique `articleLink` collected:

```bash
browser-use open "$ARTICLE_URL"
sleep 3
# Re-apply the viewport / lifecycle CDP fix (same Python helper used in step 2)
# — article pages need it just like /home does, otherwise the body won't render.
browser-use eval "
  // Try multiple body containers in priority order. X has shipped at least three
  // article-page DOM shapes; '[data-testid=\\"longformText\\"]' has been the most
  // stable, '[data-testid=\\"article-body\\"]' appears on newer pages, and a
  // generic 'article' element is the catch-all.
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

Sanity check: if `bodyLen < 500` and the page URL still resolves to the article, the selectors above missed the body container. **Don't summarize from a tiny extracted body** — it'll produce a misleading 2-sentence "article" that's actually nav chrome. Instead, take a screenshot for the operator (`browser-use screenshot /tmp/twitter-digest-article-debug.png`), include the article in the digest as a one-line "📰 Long-form article from @author — [<title>](<url>) (extraction failed; see /tmp/twitter-digest-article-debug.png)", and continue. The operator updates the selectors in this skill on next iteration.

Otherwise summarize each article in 2-3 sentences. Capture `{ title, author, url, summary }`.

### 5. Theme and compose

Read `references/themes.md` and apply its triage rules. Compose HTML (NOT Markdown — Telegram's legacy Markdown breaks on `_*[` in tweet text; HTML mode is more predictable):

Pick the header based on local clock hour at compose time:
- `4 ≤ hour < 16` (morning/early-afternoon fires, primarily the 08:00 run): `🌅 <b>Morning digest — <date></b>`
- Otherwise (evening/late fires, primarily the 22:00 run): `🌆 <b>Evening recap — <date></b>`

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

**Per-bullet link rule**: wrap the `@author tweeted/posted` attribution in an `<a href="<statusUrl>">` so a single tap on the attribution deep-links into the tweet. Don't add a separate link/arrow at the end — the attribution itself is the tappable target. For long-form articles, wrap the `@author` in the article link rather than adding a raw URL line. Telegram will still render these as clickable even with `disable_web_page_preview=true`, which is what we want (otherwise 20 embed cards render below the digest).

If a tweet has no `statusUrl` (rare — usually an anomalous DOM state or a deleted tweet), drop the tweet from the digest entirely rather than emitting an unattributed line.

**HTML escaping rules** (apply to every dynamic string before insertion): `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`. Do this LAST, after composition, so your `<b>` tags survive.

Telegram HTML supports a small whitelist: `<b>`, `<i>`, `<u>`, `<s>`, `<a href="...">`, `<code>`, `<pre>`. Don't use anything else.

**Framing note for every bullet.** Always attribute — "@author tweeted..." / "@author posted..." / "per @account" — rather than writing the summary as a first-person fact claim ("Anthropic closes $25B round..."). Tweets are positions and claims by specific people; the digest is a pointer to what they said, not independent confirmation. Also include a one-line italic disclaimer at the bottom of the digest:

```
<i>Summaries of tweets surfaced overnight; positions are the posters', not verified.</i>
```

This framing keeps the digest honest and avoids content-integrity blocks on the `claude -p` side (the safety layer treats declarative news claims differently from quoted/attributed positions).

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

**Critical**: route the digest payload from a file and save Telegram's response to a file too. Do NOT capture the response via shell `$(...)` — the digest contains emoji and non-ASCII text, Telegram echoes it back in the JSON response, and shell interpolation of a response containing multi-byte UTF-8 can mangle bytes, causing a local parse error that looks like a send failure and triggers a spurious retry. **This is the known duplicate-message bug**: if you introduce a shell-var retry path you'll double-send every morning.

```bash
RUN_DIR=/tmp/twitter-digest-run
mkdir -p "$RUN_DIR"

# The composed HTML digest should already be in $RUN_DIR/digest.html.
# If you've been composing in a shell var, write it to the file now.

TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' ~/.claude/channels/telegram/.env | cut -d= -f2-)

curl -sS "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d chat_id=7953915703 \
  --data-urlencode "text@${RUN_DIR}/digest.html" \
  -d parse_mode=HTML \
  -d disable_web_page_preview=true \
  -o "${RUN_DIR}/tg_response.json"
CURL_EXIT=$?

# Parse response from the file, not from a shell var.
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

**Retry ONLY on `OK=False` with a well-formed JSON response (Telegram said "ok: false").** Do NOT retry on:
- curl non-zero exit (network error — retry is useless if the network is down; let launchd surface tomorrow)
- Local Python parse errors (shell-encoding artifacts, not send failures)
- Empty response file (likely transport issue, not a payload problem)

If `OK=False` with a real Telegram error (`"ok": false, "description": "..."`):
- Inspect the description. Common: "can't parse entities" (HTML tag slipped through unescaped), "message is too long" (>4096 chars).
- One retry, plain-text fallback: strip HTML tags from `digest.html` to produce `digest.txt`, drop `parse_mode`, re-send with `--data-urlencode "text@${RUN_DIR}/digest.txt"`.
- If the plain-text retry also returns `ok: false`: write the failure to `state/last-failure.json` (include Telegram's description) and STOP. Do not send another Telegram alert about the failure — Telegram explicitly rejected your payload, sending more payload won't help. The operator sees it in the log next time they look.

### 8. On success: atomic finalize + cleanup

```bash
PENDING=~/.claude/skills/twitter-digest/state/pending.json
LAST_SUCCESS=~/.claude/skills/twitter-digest/state/last-success.json
# Update telegramOk in pending, then atomic rename to last-success
python3 -c "
import json
d = json.load(open('$PENDING'))
d['telegramOk'] = True
json.dump(d, open('$PENDING.tmp', 'w'))
" && mv "$PENDING.tmp" "$LAST_SUCCESS" && rm -f "$PENDING"
browser-use close --all
```

Note: cutoff for the next run derives from `last-success.json`. `pending.json` is ignored by step 1 — it's only a forensic crumb.

## Dry-run mode

If invoked with "dry-run" or "--dry-run" in the prompt, do everything *except* steps 6-8 — print the composed digest HTML to stdout, skip pending.json, skip Telegram, skip last-success update. Useful for iterating on themes/format without spamming the chat. Still call `browser-use close --all` at the end.

## Failure handling

Categorize failures:

- **Cookies expired / login wall** → write `state/last-failure.json` with `{ kind: "auth", at: <iso>, message: "cookies appear expired; re-export via headed login" }`. Don't try to log in. Don't send a Telegram alert (you'd need a working session and this isn't worth waking the user at 8am for — the log catches it).
- **browser-use crash / timeout** → close any leftover sessions (`browser-use close --all`), write last-failure.json with the error message, exit non-zero.
- **Empty scroll** (cookies fine, but timeline served zero tweets) → still write last-success.json with `tweetCount: 0` so the cutoff advances. Send the `Nothing notable 🥱` message.
- **Telegram down** → as covered in step 7, write last-failure.json and stop. Do not loop.

## What NOT to do

- **Do not try to log in** if cookies are expired. X aggressively flags automated logins; the only recovery is the user manually re-doing the export step.
- **Do not run headless.** X serves a logged-out landing page to `--headless` regardless of cookies. Always `--headed`.
- **Do not hammer X.** If you hit a rate-limit indicator, stop scrolling immediately, summarize what you have, deliver, and exit.
- **Do include tweet URLs in the themed sections, but wrapped in the `@author tweeted/posted` attribution link only.** Don't emit a separate URL line or an external-link icon at the end of each bullet — both make the digest noisy. The attribution-as-link pattern keeps the composition clean and still gives the reader a one-tap path into the source.
- **Do not advance state on Telegram failure.** A failed send must NOT update `last-success.json`, or the next run silently skips this window.
- **Do not send a Telegram error message when Telegram itself is the failure.** Log locally and exit.
