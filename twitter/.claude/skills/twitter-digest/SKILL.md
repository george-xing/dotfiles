---
name: twitter-digest
description: Generate the X (Twitter) digest — attaches via CDP to a long-running bot Chrome daemon (launchctl-managed, persistent profile, debug port 9222), scrolls x.com/home, themes content since the last run (AI / Startups / NYC / Random), separately flags + summarizes any long-form X Articles, and delivers to Telegram. Fires twice daily via launchd — morning at 08:00 ET (overnight recap) and evening at 22:00 ET (daytime recap). Use when the user asks for "twitter digest", "morning digest", "evening recap", "X digest", "what's new on twitter", or when fired by launchd.
---

# Twitter Digest

Twice-daily job: attach to the persistent bot Chrome on `127.0.0.1:9222`, scroll x.com/home, summarize themed content into Telegram. The two scheduled fires are 08:00 ET (overnight recap) and 22:00 ET (daytime recap). **No time cutoff** — the natural stop signal is URL dedup against `state/digested-urls.json` (we don't repeat anything we've already summarized) + the 3-min wall budget + feed plateau. This mirrors how a human reads X: scroll until you recognize stuff you've already seen, then stop. Designed to be fired headlessly via `claude -p` from launchd, but works fine when invoked interactively.

## Inputs (from environment / state)

- **Browser**: long-running daemon Chrome managed by the `com.pattybot.twitter-bot-chrome` LaunchAgent, listening on `http://127.0.0.1:9222` for CDP. Persistent user-data-dir at `$HOME/Library/Application Support/twitter-bot-chrome`. Auth state (X cookies) lives in that profile and is set by manual sign-in via the bot Chrome window — NOT by cookie import. **Never spawn a new browser-use Chrome with `--profile` or `--headed` — always attach via `--cdp-url`.**
- **Lookback**: no time cutoff. URL dedup is the natural stop signal — a human reads until they recognize already-seen content.
- **URL dedup**: `state/digested-urls.json` is an array of `{url, digestedAt}` entries listing every `statusUrl` actually summarized in a prior run. At extract time, drop any tweet whose `statusUrl` is in this set. After a successful run, append the URLs of summarized bullets and prune entries older than 7 days. (7d TTL is enough — X's For You almost never re-surfaces anything older than ~3 days, so URLs falling out of the dedup set won't realistically come back.)
- **Telegram bot token**: parse from `~/.claude/channels/telegram/.env` (key `TELEGRAM_BOT_TOKEN`).
- **Telegram chat_id**: `7953915703`.
- **Themes**: read `references/themes.md` before composing — edits to that file flow into the next digest with no other change.

## Workflow

### 1. Load digested-URL dedup set

```bash
DIGESTED_URLS=~/.claude/skills/twitter-digest/state/digested-urls.json
DIGESTED_COUNT=$(python3 -c "
import json, os
p = '$DIGESTED_URLS'
n = len(json.load(open(p))) if os.path.exists(p) and os.path.getsize(p) else 0
print(n)
")
echo "digested-urls in dedup set: $DIGESTED_COUNT"
```

There's no time cutoff. Any tweet whose `statusUrl` is in `digested-urls.json` was already summarized in a prior run and gets dropped at extract time; everything else is a candidate. The natural stop signals are: wall budget exhausted, feed plateau, or a stretch of consecutive already-digested URLs (the latter is the human cue "I'm reading stuff I've already read, time to stop").

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

- `vis !== "visible"` or `iw === 0` → daemon Chrome window is backgrounded. **First attempt CDP self-recovery via `Page.bringToFront`, then re-probe.** Unlike page-lifecycle hacks, `Page.bringToFront` is not fakery — Chromium's `PageHandler::BringToFront` calls `WebContentsImpl::Activate()` + `Focus()`, which on macOS dispatches the same `[NSWindow makeKeyAndOrderFront:]` path a real user click triggers (see `content/browser/devtools/protocol/page_handler.cc:1683`). If `vis` flips to `"visible"` after the call, page and OS state genuinely agree — no mismatch to detect, proceed normally. If `vis` is still `"hidden"` (macOS can resist background-process focus-steal under some conditions), hard-fail: write `state/last-failure.json` with `{ "kind": "visibility", "at": "<iso>", "message": "bot Chrome window not foreground; vis=<state> after bringToFront retry" }` and exit non-zero. Do **NOT** fall back to `Page.setWebLifecycleState("active")` — that one *is* fakery (changes only page lifecycle, OS state stays backgrounded → genuine detectable mismatch). Operator action on hard-fail: bring the bot Chrome window front manually (Mission Control, click the window) and re-fire.

  CDP call snippet (python3 + websocket-client, same pattern as the wrapper's un-minimize step):
  ```bash
  /usr/bin/python3 - <<'PY'
  import json, urllib.request, websocket
  pages = [t for t in json.loads(urllib.request.urlopen("http://127.0.0.1:9222/json").read())
           if t.get("type") == "page" and "x.com" in t.get("url", "")]
  ws = websocket.create_connection(pages[0]["webSocketDebuggerUrl"], suppress_origin=True, timeout=3)
  ws.send(json.dumps({"id": 1, "method": "Page.bringToFront"}))
  while True:
      r = json.loads(ws.recv())
      if r.get("id") == 1: print("bringToFront:", r); break
  ws.close()
  PY
  sleep 1
  # then re-run the visibility probe from above
  ```
- `hasLoginWall === true` or `title` matches the public landing → cookies expired. Write `state/last-failure.json` with `{ "kind": "auth", "at": "<iso>", "message": "bot Chrome session logged out; sign in via the bot window" }` and exit. Do NOT attempt to log in. Operator action: focus the bot Chrome window, navigate to `https://x.com/i/flow/login`, sign in. The cookies persist in the daemon's profile across restarts.
- `hasPrimaryColumn === false` despite `vis === "visible"` and no login wall → DOM rendered but timeline container missing. Likely an X UI change; write `kind: "dom"` failure and exit. Operator updates selectors in this skill.

### 2b. Refresh feed via Home-tab click

Click the left-nav Home tab while already on `/home`. This is the canonical X gesture for "give me a fresh feed" and triggers an SPA same-route handler that scrolls to top, auto-expands any pending "See new posts" pill, and **re-issues a fresh `home_timeline` API request**. Without this, a long-idle daemon Chrome session can drift into algorithmic throttle where scroll/scrollIntoView won't surface more than a tiny initial batch (the May 8 morning run hit this, plateauing at 4-5 tweets even after every other recovery tactic was exhausted).

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "
  const link = document.querySelector('a[data-testid=\\"AppTabBar_Home_Link\\"]');
  if (link) link.click();
  ({clicked: !!link})
"
sleep 4
```

This setup-time use is **uncounted** — it does not consume the recovery cap of 2 for mid-run Home-clicks (see step 3 toolkit). Different roles, different cap accounting: setup warms the feed once per run; recovery is for breaking out of a mid-loop plateau.

### 2c. Ensure For You tab is active

x.com/home usually lands on "For You" by default — what this digest consumes (matches what the user reads). The Home-tab click in 2b can occasionally land on a Trends/Following inner-tab state, so this defensive click runs after (no-op if already active):

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "
  const tabs = document.querySelectorAll('[role=\\"tablist\\"] [role=\\"tab\\"]');
  const fyt = Array.from(tabs).find(t => /for you/i.test(t.innerText));
  fyt?.click();
  ({clicked: !!fyt})
"
sleep 2
```

### 3. Gather feed content

**Goal**: accumulate **as many substantive (non-promoted) tweets as the For You feed will yield** within a **3-minute total wall budget**, using whatever sanctioned tactics the observed state demands. **For You is the only source** — the digest is a faithful read of what X's algorithm surfaced for the user, not a synthetic catch-up assembled from chronological backfill. If For You is sparse (cold-start after long idle, modal-interrupted prefetch, transient throttle), ship under-target rather than reaching elsewhere.

This step is intentionally framed as "goal + sanctioned toolkit," not a prescribed loop. The For You feed has many soft-failure modes — algorithmic cold-start, modal interstitials, mid-run prefetch hiccups, virtualization glitches, transient throttles. A rigid "scroll-stall-ship" loop ships thin digests on any of them. The runtime should iterate tactics from the toolkit until the budget is exhausted, the feed plateaus convincingly, or every sanctioned tactic has been tried without yielding new content.

A useful internal target is **~50 substantive tweets** — enough to triage 2-3 substantive bullets per theme. Don't stop early on hitting it; don't fail or escalate on missing it. It's a "is this run going well?" indicator that shapes how aggressively to recover from stalls (well below → keep trying recovery tactics; well above → let plateaus end naturally).

#### Sanctioned tactic toolkit

The only mutating actions allowed in step 3. Apply in whatever order the observed state demands. Per-run caps prevent any tactic from becoming a behavioral signature.

| Tactic | When to use | Per-run cap |
|---|---|---|
| `window.scrollBy(0, 1500)` | Default scroll; primary content-pull | unlimited |
| `tweets[last].scrollIntoView({block:'end'})` | Kick the IntersectionObserver after `scrollBy` plateaus | unlimited |
| `window.scrollTo(0, 0)` | Re-trigger top-of-feed prefetch (especially after Esc, or when the feed feels frozen) | 3 |
| `Escape` keystroke (native CDP `Input.dispatchKeyEvent` via `browser-use keys "Escape"`) | Clear interstitials — snooze prompts, year-in-review cards, "verified is here" promos, birthday confetti, any `[role=dialog]`-class overlay | 3 |
| Click `a[data-testid="AppTabBar_Home_Link"]` (the left-nav Home tab) while already on `/home` | Soft-refresh the For You algorithm — scrolls to top, auto-expands any pending "See new posts" pill, and re-issues a fresh `home_timeline` API request. **Always run once at setup time (step 2b)**, uncounted. May also be used mid-run if the feed plateaus despite scroll/scrollIntoView, capped at the count below | 2 (mid-run only; setup use uncounted) |
| Hard-fail with categorized `kind` | When `auth` / `dom` / `visibility` failure detected — see step 3a's screenshot table | 1 (run terminates) |

**Nothing else is sanctioned.** No tab-switching to Following or Lists (we want the algorithmic read, not chronological backfill). No clicking buttons by selector beyond the two narrowly-whitelisted clicks above (Home-tab `a[data-testid="AppTabBar_Home_Link"]` and the For-You inner tab) — even dismiss-y ones like "Got it" / "Skip" / "Continue" remain forbidden, those are behavioral signatures *and* may commit the operator to TOS/consent terms. No typing. No form submissions. No `location.reload()`. No navigation away from `x.com/home` (article URL navigation in step 4 is the only sanctioned exception).

#### How to drive the loop

1. **Scroll-extract loop**: alternate `window.scrollBy(0, 1500)` and `eval` extraction. Pause 1-2s after each scroll for hydration, then extract:

   ```bash
   browser-use --cdp-url http://127.0.0.1:9222 eval "
     Array.from(document.querySelectorAll('article[data-testid=\\"tweet\\"]')).slice(0, 80).map(a => {
       const author = a.querySelector('[data-testid=\\"User-Name\\"]')?.innerText || '';
       const text = a.querySelector('[data-testid=\\"tweetText\\"]')?.innerText || '';
       const timeEl = a.querySelector('time');
       const timeISO = timeEl?.getAttribute('datetime') || null;
       const statusHref = timeEl?.closest('a')?.getAttribute('href')
         || a.querySelector('a[href*=\\"/status/\\"]')?.getAttribute('href')
         || null;
       const statusUrl = statusHref ? ('https://x.com' + statusHref) : null;
       // Article detection: X Articles do NOT expose /article/ URLs anywhere in
       // For You tiles or bookmarks tiles. They are reached via the same status
       // URL as a regular tweet — X redirects that URL to the article view.
       // The distinguishing marker is the article cover-image testid inside the tile.
       const hasArticleCover = !!a.querySelector('[data-testid=\\"article-cover-image\\"]');
       const articleLink = hasArticleCover ? statusUrl : null;
       const containerText = a.innerText || '';
       const isPromoted = /\\bPromoted\\b|\\bAd\\b(?=$|\\n)/.test(containerText) || !!a.querySelector('[data-testid=\\"placementTracking\\"]');
       return {author, text: text.slice(0, 800), timeISO, statusUrl, articleLink, isPromoted};
     })
   "
   ```

   Dedupe by `(author, text)` — later scrolls re-emit earlier tweets, and the dedupe key has to be content-based since X's `data-testid` IDs aren't stable across virtualization recycles.

2. **When `scrollBy` plateaus** (no new uniques after ~2 scrolls): try `scrollIntoView` on the last article. If that also plateaus (3 consecutive zero-new across both), invoke step 3a (screenshot-then-judge) to pick the next move from the toolkit.

3. **Stop the entire run when**:
   - Wall budget elapsed (3 min total), OR
   - The For You feed is convincingly exhausted (3a screenshot shows "you're all caught up" / repeated tweets / no obstruction, AND no recovery tactic has any caps remaining), OR
   - A hard-fail `kind` is set.

   Don't stop early on hitting 50 — content quality scales with volume (more raw → better triage → more substantive bullets per theme), so always burn the full wall budget when content's flowing. Use `len(seen)` against 50 to decide how patient to be at stalls: well under → spend a recovery cap to push through; well over → let the plateau end naturally.

4. **Anti-pattern to avoid: stale-percentage-based early termination.** Per-scroll tracing on For You shows `stale%` oscillates wildly between 30% and 100% even while fresh content is still being surfaced — the algorithm interleaves pockets of old and new. A "3 consecutive scrolls > N% stale" rule fires on the stale pockets and misses the fresh ones right after.

#### Filters

- **Hard filter at extract time**:
  - Drop every tweet where `isPromoted === true`.
  - Drop entries with no `timeISO` — they're typically promoted/structurally-anomalous.
  - Drop every tweet whose `statusUrl` is in `state/digested-urls.json` — already summarized in a prior run.
- **Soft filter at triage time**: marketing / influencer-shill content (see `references/themes.md` → "Triage rules"). Also downweight obviously stale content — if a tweet's relative timestamp is "3d" or older AND the substance is time-sensitive (e.g. a "BREAKING:" tweet from days ago, a sports score), drop it. Evergreen content (essays, opinions, references) at any age is fine if it survived URL dedup.

**Note on URL dedup vs. triage**: only *summarized* URLs (the bullets that actually shipped) get added to `digested-urls.json`, NOT every URL we scrolled past. So a tweet that was scraped but dropped in triage one run can be re-evaluated cleanly the next run if the algo re-surfaces it — borderline content gets a second chance to make the cut.

#### Selector reference

- `article[data-testid="tweet"]` — canonical tweet container
- `[data-testid="tweetText"]` — body text
- `[data-testid="User-Name"]` — author block
- `time[datetime]` — exact ISO timestamp
- `[role="tablist"] [role="tab"]` — tablist tabs (For You / Following)
- `[data-testid="article-cover-image"]` — long-form X Article indicator (inside the tile). Articles do NOT have `/article/` URLs in tiles — they're reached via the same `/status/` URL as a regular tweet, which X redirects to the article view.

### 3a. Stall handling (screenshot-then-judge)

When the current source has stalled — `window.scrollBy` followed by the `scrollIntoView` kick both produced 3 consecutive zero-new-tweet iterations — capture a screenshot and inspect it visually to choose the next move from the toolkit. Predetermined DOM checks ("is there a `[role=dialog]`?") fail every time X re-skins a modal; visual judgment generalizes.

Screenshots persist into the skill's state dir (`state/stalls/`) **regardless of whether the run ultimately succeeds, ships under-target, or hard-fails** — they are the only forensic artifact a human can inspect post-hoc to disambiguate the stall's cause (subtle modal vs. scroll-container regression vs. algorithmic plateau). `/tmp` reaping otherwise destroys them between fire and inspection. Keep the last 10 screenshots across all runs:

```bash
STALLS_DIR=~/.claude/skills/twitter-digest/state/stalls
mkdir -p "$STALLS_DIR"
SCREENSHOT="$STALLS_DIR/$(date -u +%Y%m%dT%H%M%SZ).png"
browser-use --cdp-url http://127.0.0.1:9222 screenshot "$SCREENSHOT"

# Prune to last 10 by mtime
ls -t "$STALLS_DIR"/*.png 2>/dev/null | tail -n +11 | xargs -I {} rm -f {}
```

If the screenshot tool times out repeatedly (a known transient issue with the daemon Chrome under load), fall back to a DOM-text snapshot — `eval "document.body.innerText.slice(0, 4000)"` — and judge from text. Less reliable for visual-only states (e.g., a black-render visibility failure) but unblocks the run. Note the degraded-classification source in the run log so the operator knows.

Then *read the image (or text) yourself* and pick the next tactic:

| What you see | Action |
|---|---|
| Empty timeline / repeated tweets / "you're all caught up" / "see new posts" pill / no obvious obstruction | Feed is genuinely exhausted. **Ship** with what's accumulated. |
| Modal / dialog / banner / snooze prompt / "verified is here" / birthday card / year-in-review / any interstitial obstructing the timeline | **Press Escape** (if Esc cap remaining), wait 3s, `scrollTo(0, 0)`, wait 1s, resume scroll loop with fresh stall counter. If Esc cap exhausted and the same modal-class state recurs, ship — don't escalate to clicks. |
| Frozen-but-clean timeline (no obstruction, but `scrollBy` produces no movement and no new tweets after multiple attempts) | `scrollTo(0, 0)` (if cap remaining), wait 5s for prefetch, retry. If still frozen after exhausting `scrollTo` cap, ship. |
| Login wall / "Sign up to continue" / OAuth flow / "Log in to X" copy | **Hard-fail `kind: "auth"`** with the screenshot path. Cookies expired mid-run; operator re-signs-in via the bot Chrome window. |
| Page chrome looks fundamentally different from a normal X home (no `primaryColumn`, completely different layout, error page, "this site can't be reached") | **Hard-fail `kind: "dom"`** with the screenshot path. Operator updates selectors. |
| Black render, blank page, or screenshot is mostly empty pixels | **Hard-fail `kind: "visibility"`** with the screenshot path. Window dropped foreground or display surface mid-scrape (rare with the dummy plug). |
| Genuinely uncertain — the screen shows something but you can't classify it confidently | Try one cheap recovery (Esc if cap remaining; else `scrollTo(0, 0)` if cap remaining). If still unclassified after that, **hard-fail `kind: "stall"`** with the screenshot path. |

#### Tactic dispatch details

**Escape keystroke** — must be a **native** key event via CDP `Input.dispatchKeyEvent`, not a synthetic `document.dispatchEvent(new KeyboardEvent(...))`. Use `browser-use keys`, which routes through Playwright's input pipeline and produces `event.isTrusted === true`:

```bash
browser-use --cdp-url http://127.0.0.1:9222 keys "Escape"
sleep 3
browser-use --cdp-url http://127.0.0.1:9222 eval "window.scrollTo(0, 0); 'ok'"
sleep 1
```

**Why native, not synthetic** — modern X dialogs (Radix/Headless-class components, including the snooze-topics modal) bind `keydown:Escape` on the focused dialog container, not on `document` or `window`. A synthetic `dispatchEvent` on `document` flips `event.isTrusted = false` AND never reaches the dialog's listener path. The May 8 morning run failed exactly this way: synthetic Esc fired twice, the snooze-topics modal stayed up, the feed plateaued at 4 articles. Confirmed by live test that `browser-use keys "Escape"` does dismiss the same modal.

The 3s post-Esc settle is longer than the close animation alone — modals frequently interrupt X's timeline prefetch query, and the feed needs time to re-issue it. The follow-up `scrollTo(0,0)` puts top-of-feed back in viewport, since X's prefetch is gated on top-of-feed visibility. Without these two extra steps, post-Esc runs commonly observe a sparse 5-cell timeline that never rehydrates within the wall budget.

#### Why this toolkit, and only this

- **Esc** — universal human modal-close keystroke; doesn't depend on brittle close-button selectors that drift with each X redesign; no-ops harmlessly on non-modal pages. Capped at 3 per run because deterministic repeated Esc-ing IS a signature.
- **`scrollTo(0,0)`** — what a human does when a feed feels frozen ("scroll back to top to refresh"). Capped at 3 because a deterministic top-of-feed reset every fire is also a signature.
- **`scrollBy` / `scrollIntoView`** — uncapped; the digest's primary content-pull mechanism, and any human spends most of their session scrolling.

Stepping outside these — clicking arbitrary buttons (other than the sanctioned setup-time Home-tab click in step 2b and the For-You ensure-active in step 2c), typing, submitting, reloading, navigating away — re-engages the bot-detection risks the skill is engineered to avoid AND would change the digest's source from "what the algorithm surfaced" to "whatever could be backfilled," which defeats the digest's purpose.

### 4. Pull long-form articles (after scroll loop ends)

X Articles are uncommon. When one appears, the article-page DOM may differ; be defensive.

For each unique `articleLink`:

```bash
browser-use --cdp-url http://127.0.0.1:9222 open "$ARTICLE_URL"
sleep 3
browser-use --cdp-url http://127.0.0.1:9222 eval "
  const titleEl = document.querySelector('[data-testid=\\"twitter-article-title\\"]')
              || document.querySelector('h1')
              || document.querySelector('[data-testid=\\"article-title\\"]');
  const bodyEl = document.querySelector('[data-testid=\\"twitterArticleRichTextView\\"]')
              || document.querySelector('[data-testid=\\"longformText\\"]')
              || document.querySelector('[data-testid=\\"article-body\\"]')
              || document.querySelector('article')
              || document.body;
  ({
    title: titleEl?.innerText || document.title,
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

Compose the HTML digest into `$RUN_DIR/digest.html` and a plain-text fallback into `$RUN_DIR/digest.txt` (HTML tags stripped). Then send via the shared helper:

```bash
RUN_DIR=/tmp/twitter-digest-run
mkdir -p "$RUN_DIR"

# $DIGEST_HTML and $DIGEST_PLAIN are composed in earlier steps (HTML version
# uses the Telegram-HTML tags; plain-text version is the same content with
# tags stripped, used only on parse_mode retry).
printf '%s' "$DIGEST_HTML"  > "$RUN_DIR/digest.html"
printf '%s' "$DIGEST_PLAIN" > "$RUN_DIR/digest.txt"

TELEGRAM_CHAT_ID=7953915703 \
TELEGRAM_MESSAGE_FILE="$RUN_DIR/digest.html" \
TELEGRAM_MESSAGE_PLAIN_FILE="$RUN_DIR/digest.txt" \
RUN_DIR="$RUN_DIR" \
  /Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh
TG_EXIT=$?
```

The helper enforces the load-bearing invariants from prior production incidents:

- **File-payload only**: `--data-urlencode "text@<file>"`, NEVER `text="$DIGEST_HTML"` from a shell var. Multi-byte UTF-8 in emoji content can be mangled by shell interpolation, producing what looks like a send failure and triggering a spurious retry → the duplicate-message bug.
- **Retry only on parseable `ok: false`**: never on curl non-zero exit (network error), never on local Python parse errors (shell-encoding artifacts, not send failures), never on empty response.
- **One retry, plain-text fallback**: strips HTML by re-sending with `disable parse_mode` against `digest.txt`.

Inspect the helper at `/Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh` for the full implementation.

**On `$TG_EXIT`:**
- `0` — sent successfully (HTML or plain-text fallback). Proceed to step 8.
- `1` — Telegram returned `ok: false` even after plain-text retry. Write `state/last-failure.json` with `kind: telegram` (description from `$RUN_DIR/tg_response.json`). STOP. Do NOT send another Telegram message about the failure.
- `2` — curl/network/local-parse failure. Same handling as `kind: telegram` but with a network-error message in the failure JSON.

### 8. On success: persist digested URLs FIRST, then atomic finalize

**Order matters.** Append URLs to `digested-urls.json` BEFORE advancing `last-success.json`. If dedup-append fails between Telegram-succeeded and state-advance, leaving `pending.json` in place gives the operator a forensic marker; a re-fire correctly re-collects the URLs (URL dedup will then dedupe properly when re-shipped). Reversing the order would mark the run "successful" but silently lose the URLs from the dedup set → next fire re-summarizes already-shipped content → duplicate digest delivery.

```bash
PENDING=~/.claude/skills/twitter-digest/state/pending.json
LAST_SUCCESS=~/.claude/skills/twitter-digest/state/last-success.json
DIGESTED_URLS=~/.claude/skills/twitter-digest/state/digested-urls.json

# Step 8a: persist dedup FIRST.
# $SUMMARIZED_URLS_JSON is the JSON array of statusUrls that actually shipped.
DEDUP_FILE="$DIGESTED_URLS" \
DEDUP_URLS_JSON="$SUMMARIZED_URLS_JSON" \
DEDUP_TTL_DAYS=7 \
  /Users/pattybot/dotfiles/twitter/bin/lib/dedup-append.sh
DEDUP_EXIT=$?

if [ "$DEDUP_EXIT" -ne 0 ]; then
  # Telegram already shipped; dedup failed. Write last-failure for forensics,
  # leave pending.json in place. Do NOT advance last-success.json.
  echo "{\"kind\":\"dedup\",\"at\":\"$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')\",\"message\":\"dedup-append.sh exited $DEDUP_EXIT after successful Telegram send; URLs not persisted\"}" \
    > ~/.claude/skills/twitter-digest/state/last-failure.json
  exit 1
fi

# Step 8b: atomic last-success update.
python3 -c "
import json
d = json.load(open('$PENDING'))
d['telegramOk'] = True
json.dump(d, open('$PENDING.tmp', 'w'))
" && mv "$PENDING.tmp" "$LAST_SUCCESS" && rm -f "$PENDING"
```

The dedup-append helper handles idempotent appends (duplicate URLs not re-added), TTL prune (entries older than 7 days dropped), and atomic write via PID-suffixed tmp + os.replace. Inspect at `/Users/pattybot/dotfiles/twitter/bin/lib/dedup-append.sh`.

**Do NOT** call `browser-use close --all` — the daemon Chrome is launchd-managed and must keep running. Closing it would force a daemon respawn and lose the active tab state.

Note: there's no time cutoff for the next run. `last-success.json` is kept only for forensics and the digest footer; `digested-urls.json` is what prevents repeats. `pending.json` is ignored by step 1 — it's only a forensic crumb.

## Dry-run mode

If invoked with "dry-run" or "--dry-run" in the prompt, do everything *except* steps 6-8 — print the composed digest HTML to stdout, skip pending.json, skip Telegram, skip last-success update. Useful for iterating on themes/format without spamming the chat.

Do NOT call `browser-use close --all` even in dry-run — the daemon Chrome stays up always.

## Failure handling

Categorize failures and write `state/last-failure.json` with `{kind, at, message}` plus optional `screenshot` — an absolute path to a CDP-captured PNG of the visible state at failure time. Step 3a always captures screenshots for stall-derived failures; step 4 already does for article-extraction failures; step 2's hard-fails may include them when useful. Operators read the screenshot to disambiguate similar failure modes (e.g. "is this `auth` or `dom`?" — the image makes it obvious).

`kind` values:

- `kind: "visibility"` — bot Chrome window not foreground (`vis !== "visible"` after the CDP `Page.bringToFront` self-recovery attempt also failed). Operator brings the window to front manually and re-fires. Note: `Page.setWebLifecycleState("active")` is still off-limits — that one is real fakery; `Page.bringToFront` is a legitimate OS activation call (page and OS state stay in sync) and is the first thing the skill tries.
- `kind: "auth"` — login wall present in the bot Chrome (cookies expired). Operator opens the bot Chrome window, signs into X manually, no reseed script needed. Don't try to log in programmatically — X flags automated logins.
- `kind: "dom"` — visibility OK, no login wall, but `primaryColumn` missing. Likely an X UI change. Operator updates the selectors in this skill.
- `kind: "telegram"` — Telegram delivery failed even after the plain-text retry. Captures the response description.
- `kind: "empty"` — feed truly returned zero tweets after URL dedup (rare; would mean every tweet shown was already digested in the last 7 days). Treated as success: write `last-success.json` with `tweetCount: 0`; send the `Nothing notable 🥱` message.
- **Under-target shipping is NOT a failure.** A run that produces 1-49 tweets is still a successful run — it ships the digest, advances `last-success.json`, and writes nothing to `last-failure.json`. The 50-tweet target in step 3 just shapes how patiently to recover from stalls (well below → spend a recovery cap; well above → let plateaus end naturally); it does NOT gate success. Only zero-tweet runs (with all sanctioned tactics tried) advance into the `kind: "empty"` path.
- `kind: "stall"` — scroll loop stalled and the step-3a screenshot didn't match any recoverable or pre-categorized state. Operator inspects the screenshot at `last-failure.json#screenshot`. Common causes: a new modal variant worth a future Esc-class entry, a rate-limit pattern not yet seen, or an X UI variant the classifier in 3a didn't recognize. After diagnosing, operator may update 3a's classification table and re-fire — the failure-kind taxonomy is intentionally evolving rather than fixed.

In all hard-fail cases, do NOT advance `last-success.json` and do NOT append to `digested-urls.json` — a failed run shouldn't mark its un-shipped content as already-summarized.

In all hard-fail cases, do NOT send a Telegram alert about the failure. Operator finds it in the log.

## What NOT to do

- **Do not spawn a fresh browser-use Chrome.** Always attach via `--cdp-url http://127.0.0.1:9222`. Spawning would create an ephemeral profile with a different cookie store than the daemon, defeating the entire architecture.
- **Do not call `browser-use close --all`.** That kills sessions; the daemon Chrome's lifetime is launchd's responsibility, not the skill's.
- **Do not try to log in programmatically.** X aggressively flags automated logins; operator must sign in manually via the bot Chrome window.
- **Do not fake the foreground state.** The CDP `Page.setWebLifecycleState("active")` and `Emulation.setVisibleSize` hacks produce a state-mismatch (page lifecycle says active, OS says backgrounded) that's itself detectable. Hard-fail and require operator to actually bring the window foreground.
- **Stay inside the step-3 sanctioned tactic toolkit.** Only the moves listed in step 3's toolkit are allowed during content-gathering: scroll variants (`scrollBy`, `scrollIntoView`, `scrollTo(0,0)`), `Escape` keystroke, the whitelisted Home-tab click `a[data-testid="AppTabBar_Home_Link"]`, and hard-fail with a categorized kind. Esc and `scrollTo(0,0)` each capped at 3 per run; mid-run Home-tab clicks capped at 2 (the setup-time Home click in step 2b is uncounted). Do NOT switch to inner tabs other than For You (For You is the digest's only source by design). Do NOT click any other buttons by selector — even ones that look obviously dismiss-y like "Got it" / "Skip" / "Continue". Deterministic clicks are a behavioral signature, and auto-clicking "Accept" / "Continue" / "I agree" on TOS, consent, or age-verification modals commits the operator to terms they haven't reviewed. Do NOT type into inputs, submit forms, call `location.reload()`, or navigate away from `x.com/home` (article URL navigation in step 4 is the only sanctioned exception). Stepping outside the toolkit re-engages the bot-detection-and-consent risks the skill is engineered to avoid.
- **Don't backfill from outside For You.** If the For You feed is sparse, ship what's there — the digest is meant to reflect what X's algorithm surfaced for the user, not a synthetic catch-up assembled from chronological Following or Lists scraping. A thin digest from a real cold-feed day is more honest than a padded one.
- **Do not hammer X.** If you hit a rate-limit indicator (anywhere — extract response, screenshot, page title), stop scrolling immediately, summarize what you have, deliver, and exit. Don't try to push through with extra Esc/scrollTo/tab-switch; those will only confirm the rate-limit signal.
- **Do include tweet URLs in the themed sections, but wrapped in the `@author tweeted/posted` attribution link only.** Don't emit a separate URL line.
- **Do not advance state on Telegram failure.** A failed send must NOT update `last-success.json`.
- **Do not send a Telegram error message when Telegram itself is the failure.** Log locally and exit.
