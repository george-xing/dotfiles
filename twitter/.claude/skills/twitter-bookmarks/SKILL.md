---
name: twitter-bookmarks
description: Generate an X bookmark digest — attaches via CDP to the long-running bot Chrome daemon (launchctl-managed, persistent profile, debug port 9222), navigates to x.com/i/bookmarks, scrolls until ~150 substantive bookmarks accumulated OR a ~2-month tweet-age heuristic trips OR plateau, summarizes new bookmarks since last fire (with persistent URL dedup — no TTL), separately summarizes any long-form X Articles, and delivers to Telegram. Use when the user asks for "bookmarks digest", "summarize my bookmarks", "/bookmarks", "read my bookmarks", or when fired by the paired-session dispatch skill.
---

# Twitter Bookmarks Digest

On-demand job: attach to the persistent bot Chrome on `127.0.0.1:9222`, navigate to `x.com/i/bookmarks`, scrape new bookmarks since the last fire, summarize them + any X Articles, deliver to Telegram. Persistent dedup means each bookmark is summarized exactly once, forever. The first fire uses a ~2-month tweet-age heuristic to bound the initial backlog; subsequent fires only surface newly-saved bookmarks via URL dedup.

**Important: the bookmarks page DOM exposes the tweet's authored date (`time[datetime]`), NOT the bookmark save date.** The heuristic uses tweet age as an approximation of save age — it works because the bookmarks page is sorted reverse-chronologically by save date, AND because most bookmarks are saved within a short window of the tweet's posting. Edge case: someone who recently bookmarks a very old tweet (e.g., a 2-year-old essay) will see that bookmark trip the heuristic prematurely. Accepted tradeoff — the 150-item count cap is the primary stop, tweet-age is a backup.

## Inputs (from environment / state)

- **Browser**: same daemon Chrome as the twitter-digest skill, listening on `http://127.0.0.1:9222` for CDP. Persistent user-data-dir at `$HOME/Library/Application Support/twitter-bot-chrome`. Auth state (X cookies) lives in that profile. **Never spawn a new browser-use Chrome — always attach via `--cdp-url`.**
- **URL dedup**: `~/.claude/skills/twitter-bookmarks/state/digested-urls.json` — array of `{url, digestedAt}` entries. At extract time, drop any bookmark whose `statusUrl` is in this set. After a successful run, append summarized URLs via the shared `dedup-append.sh` helper. **No TTL** — bookmarks are persistent and a human reading a bookmark queue does not re-read items already processed.
- **Telegram bot token**: parse from `~/.claude/channels/telegram/.env` (key `TELEGRAM_BOT_TOKEN`). Delivery uses `~/dotfiles/twitter/bin/lib/telegram-send.sh`.
- **Telegram chat_id**: `7953915703`.

## Workflow

### 1. Load digested-URL dedup set

```bash
DIGESTED_URLS=~/.claude/skills/twitter-bookmarks/state/digested-urls.json
mkdir -p "$(dirname "$DIGESTED_URLS")"
DIGESTED_COUNT=$(python3 -c "
import json, os
p = '$DIGESTED_URLS'
n = len(json.load(open(p))) if os.path.exists(p) and os.path.getsize(p) else 0
print(n)
")
echo "digested-urls in dedup set: $DIGESTED_COUNT"
```

If `DIGESTED_COUNT == 0` this is the first (seed) fire — apply the 2-month tweet-age heuristic to bound the initial backlog. (See top-of-file note on why tweet-age is an approximation of save-age, not a precise mapping.)

### 2. Attach to daemon Chrome, navigate to bookmarks, verify

```bash
browser-use --cdp-url http://127.0.0.1:9222 open https://x.com/i/bookmarks
sleep 4
browser-use --cdp-url http://127.0.0.1:9222 eval "
  JSON.stringify({
    title: document.title,
    vis: document.visibilityState,
    iw: innerWidth,
    ih: innerHeight,
    hasBookmarkList: !!document.querySelector('[aria-label*=\"Bookmark\"], [data-testid=\"primaryColumn\"]'),
    hasLoginWall: !!document.querySelector('a[href=\"/login\"]') || !!document.querySelector('a[href=\"/i/flow/login\"]')
  })
"
```

Expected: `vis === "visible"`, `iw > 0`, `ih > 0`, `title` includes "Bookmark", `hasBookmarkList === true`, `hasLoginWall === false`.

**Failure semantics**: identical to twitter-digest step 2 — same `visibility` / `auth` / `dom` kinds, same `Page.bringToFront` self-recovery for visibility failures. See `~/.claude/skills/twitter-digest/SKILL.md` step 2 for the full failure-handling reference; this skill inherits the same patterns.

### 3. Gather bookmarks

**Goal**: accumulate substantive bookmarks via scroll-extract loop. **Stop on whichever first**:

1. **~150 substantive bookmarks** in `seen` accumulator (primary stop).
2. **~10 consecutive bookmarks whose tweet authored date is older than 2 months ago** (tweet-age heuristic on first fire only — when `DIGESTED_COUNT == 0`; backup stop).
3. **URL dedup**: 5+ consecutive already-summarized URLs (you've scrolled past everything new since last fire).
4. **Wall budget**: 5 minutes elapsed.
5. **Plateau**: 3 consecutive zero-new scroll iterations.
6. **Hard-fail kind**: `auth`, `dom`, `visibility`, `stall`.

#### Sanctioned tactic toolkit

Identical to twitter-digest's toolkit MINUS the Home-tab refresh click (no equivalent on bookmarks) and the For-You tab ensure (no such tab on bookmarks):

| Tactic | When | Cap |
|---|---|---|
| `window.scrollBy(0, 1500)` | Default scroll | unlimited |
| `tweets[last].scrollIntoView({block:'end'})` | After scrollBy plateaus | unlimited |
| `window.scrollTo(0, 0)` | Refresh / feed feels frozen | 3 |
| `Escape` keystroke (native via `browser-use keys "Escape"`) | Modal/dialog interstitials | 3 |
| Hard-fail with categorized `kind` | On auth/dom/visibility/stall | 1 (run terminates) |

**Forbidden**: button clicks beyond visibility recovery, typing, form submission, `location.reload()`, navigation away from `x.com/i/bookmarks` (article URLs in step 4 are the only sanctioned exception).

#### Scroll-extract loop

Alternate a scroll and a call to the shared extraction helper. Pause 1-2s after each scroll for hydration.

```bash
# Scroll the bookmarks list.
browser-use --cdp-url http://127.0.0.1:9222 eval "window.scrollBy(0, 1500); 'ok'"
sleep 1.5

# Extract currently-rendered tiles via the shared helper. Returns clean JSON.
TILES_JSON=$(MAX=80 /Users/pattybot/dotfiles/twitter/bin/lib/extract-tweets.sh)
```

`TILES_JSON` is a JSON array of `{author, text, timeISO, statusUrl, articleLink, isPromoted}`. Inspect `/Users/pattybot/dotfiles/twitter/bin/lib/extract-tweets.sh` for the canonical DOM selectors and the article-detection heuristic (article-cover-image testid AND empty tweetText — combining both eliminates the ~3x false-positive rate that cover-image alone produces on regular tweets with Twitter Card link previews).

Dedupe by `(author, text)`. Drop entries already in `digested-urls.json` and entries with no `timeISO`.

#### 2-month tweet-age heuristic (first fire only)

After each extraction, check the trailing 10 substantive bookmarks. If 10 consecutive have `timeISO` (the tweet's authored date) older than 60 days ago, stop scrolling — we've likely scrolled into older save-date territory. The "10 consecutive" check makes a single bookmarked-old-tweet not trip this; only a sustained run does.

This is intentionally approximate. The DOM doesn't expose bookmark save date directly; we use tweet age as a proxy because (a) the page is reverse-chronological by save date, and (b) most bookmarks are saved soon after the tweet's posting. The 150-item count cap is the primary defense — this heuristic just keeps a low-volume bookmarker's first fire from running forever.

### 3a. Stall handling

Identical to twitter-digest step 3a — screenshot, classify visually, recover or hard-fail. Screenshots persist to `state/stalls/` (last 10 kept):

```bash
STALLS_DIR=~/.claude/skills/twitter-bookmarks/state/stalls
mkdir -p "$STALLS_DIR"
SCREENSHOT="$STALLS_DIR/$(date -u +%Y%m%dT%H%M%SZ).png"
browser-use --cdp-url http://127.0.0.1:9222 screenshot "$SCREENSHOT"
ls -t "$STALLS_DIR"/*.png 2>/dev/null | tail -n +11 | xargs -I {} rm -f {}
```

See twitter-digest's SKILL.md 3a for the full classification table (modal/feed-exhausted/auth-wall/dom-changed/etc.) — bookmarks inherits the same recovery decisions.

### 4. Pull long-form X Articles

For each unique `articleLink` extracted (typically a handful per fire):

```bash
ARTICLE_JSON=$(/Users/pattybot/dotfiles/twitter/bin/lib/extract-article.sh "$ARTICLE_URL")
# ARTICLE_JSON is {title, author, body, bodyLen}.
```

The helper navigates the bot Chrome to `$ARTICLE_URL`, sleeps 3s for hydration, then extracts via the dedicated `[data-testid="twitterArticleRichTextView"]` (body) and `[data-testid="twitter-article-title"]` (title) selectors with legacy fallbacks. Returns clean JSON. Inspect `/Users/pattybot/dotfiles/twitter/bin/lib/extract-article.sh` for the full selector fallback chain.

Sanity check: if `bodyLen < 500` and the URL resolves to the article, the selectors missed the body. Don't summarize from a tiny body — screenshot to `state/stalls/` and emit a one-line "📰 extraction failed" entry, then continue.

After each article, navigate back: `browser-use --cdp-url http://127.0.0.1:9222 open https://x.com/i/bookmarks` (don't try browser history — CDP-detached browsing can get desynced).

Summarize each article in 2-3 sentences. Capture `{ title, author, url, summary }`.

### 5. Theme and compose

Organize bookmarks into:
- **🔖 Posts** — substantive tweet bookmarks (one bullet each, attribution-linked)
- **📰 Saved articles** — X Articles, one bold title + 2-3 sentence summary each

If a section is empty, omit it. If literally no bookmarks shipped after dedup, send a single line `Nothing new in bookmarks 🥱` instead of an empty digest.

Header: `🔖 <b>Bookmark recap — <date></b>` (no AM/PM variants — bookmarks fire on-demand, not on a clock).

```
🔖 <b>Bookmark recap — <date></b>

🔖 <b>Posts</b>
• <a href="<statusUrl>">@author posted</a>: <one-line summary>
• <a href="<statusUrl>">@author tweeted</a>: <one-line summary>

📰 <b>Saved articles</b>
• <b>&lt;title&gt;</b> — <a href="<articleLink>">@author</a>
  &lt;2-3 sentence summary&gt;

—
<N> bookmarks scanned · <M> minutes scrolled · <K> articles read

<i>Summaries of items you saved on X; positions are the posters', not verified.</i>
```

**HTML escaping rules** (apply to every dynamic string before insertion): `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`. Apply LAST, after composition, so your `<b>` tags survive. Telegram HTML whitelist: `<b>`, `<i>`, `<u>`, `<s>`, `<a href="...">`, `<code>`, `<pre>`. Nothing else.

**Framing note**: always attribute — "@author posted..." / "per @account" — never first-person fact claims. Bookmarks are positions you saved; the digest is a pointer. Italic disclaimer at the bottom reinforces this.

### 6. Pre-send: write pending state

```bash
PENDING=~/.claude/skills/twitter-bookmarks/state/pending.json
mkdir -p "$(dirname "$PENDING")"
NOW=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
cat > "$PENDING" <<EOF
{"runAt": "$NOW", "scrolledFor": $SCROLL_SECONDS, "bookmarkCount": $BOOKMARK_COUNT, "articleCount": $ARTICLE_COUNT, "telegramOk": null}
EOF
```

### 7. Deliver to Telegram

```bash
RUN_DIR=/tmp/twitter-bookmarks-run
mkdir -p "$RUN_DIR"

# $DIGEST_HTML and $DIGEST_PLAIN composed in step 5.
printf '%s' "$DIGEST_HTML"  > "$RUN_DIR/bookmarks.html"
printf '%s' "$DIGEST_PLAIN" > "$RUN_DIR/bookmarks.txt"

TELEGRAM_CHAT_ID=7953915703 \
TELEGRAM_MESSAGE_FILE="$RUN_DIR/bookmarks.html" \
TELEGRAM_MESSAGE_PLAIN_FILE="$RUN_DIR/bookmarks.txt" \
RUN_DIR="$RUN_DIR" \
  /Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh
TG_EXIT=$?
```

`$TG_EXIT` handling identical to twitter-digest section 7:
- `0` — sent. Proceed to step 8.
- `1` — Telegram returned ok:false even after plain-text retry. Write `state/last-failure.json` with `kind: telegram`, STOP.
- `2` — curl/network/local-parse failure. Same handling but with network-error message.

### 8. On success: persist digested URLs FIRST, then atomic finalize

**Order matters.** Append URLs to `digested-urls.json` BEFORE advancing `last-success.json`. If dedup-append fails after Telegram succeeded, leaving `pending.json` in place gives the operator a forensic marker; a re-fire correctly handles the URLs (URL dedup will dedupe properly when re-shipped). Reversing the order risks duplicate-digest delivery on the next fire.

```bash
PENDING=~/.claude/skills/twitter-bookmarks/state/pending.json
LAST_SUCCESS=~/.claude/skills/twitter-bookmarks/state/last-success.json
DIGESTED_URLS=~/.claude/skills/twitter-bookmarks/state/digested-urls.json

# Step 8a: persist dedup FIRST.
# Persistent dedup — DEDUP_TTL_DAYS deliberately omitted (no TTL).
# $SUMMARIZED_URLS_JSON includes statusUrls AND articleLinks that shipped.
DEDUP_FILE="$DIGESTED_URLS" \
DEDUP_URLS_JSON="$SUMMARIZED_URLS_JSON" \
  /Users/pattybot/dotfiles/twitter/bin/lib/dedup-append.sh
DEDUP_EXIT=$?

if [ "$DEDUP_EXIT" -ne 0 ]; then
  # Telegram already shipped; dedup failed. Write last-failure for forensics,
  # leave pending.json. Do NOT advance last-success.json.
  echo "{\"kind\":\"dedup\",\"at\":\"$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')\",\"message\":\"dedup-append.sh exited $DEDUP_EXIT after successful Telegram send; URLs not persisted\"}" \
    > ~/.claude/skills/twitter-bookmarks/state/last-failure.json
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

**Do NOT** call `browser-use close --all` — daemon Chrome is launchd-managed.

## Dry-run mode

If invoked with "dry-run" in the prompt, do everything *except* steps 6-8: print the composed digest HTML to stdout, skip pending.json, skip Telegram, skip state writes.

## Failure handling

Identical `kind`-taxonomy as twitter-digest: `visibility`, `auth`, `dom`, `telegram`, `empty`, `stall`. Each writes `state/last-failure.json` with `{kind, at, message, screenshot?}` on hard fail. Operator response per `references/runbook.md`.

**Bookmark-specific**:

- `kind: "empty"` (no new bookmarks since last fire) is treated as **success** — send `Nothing new in bookmarks 🥱` and advance `last-success.json`. **This is the COMMON case on second-and-later fires** (you may not save bookmarks every day). The dispatch skill does NOT treat it as a problem to relay.
- `kind: "busy"` — emitted by `twitter-fire.sh` (not by this skill directly) when the shared flock is held. Caller should retry in ~5 min.

In all non-empty hard-fail cases, do NOT advance `last-success.json` and do NOT append to `digested-urls.json` — a failed run shouldn't mark its un-shipped content as already-summarized.

In all hard-fail cases, do NOT send a Telegram alert about the failure. Operator finds it in the log; the dispatch skill (when triggered) handles the user-facing relay via MCP `reply`.

## What NOT to do

- **Don't spawn a fresh browser-use Chrome.** Always `--cdp-url http://127.0.0.1:9222`.
- **Don't call `browser-use close --all`.** Daemon Chrome's lifetime is launchd's responsibility.
- **Don't try to log in programmatically.** X flags automated logins; operator must sign in manually via the bot Chrome window when `kind: auth` fires.
- **Don't fake foreground state via `setWebLifecycleState`.** The CDP `Page.bringToFront` retry is the only sanctioned self-recovery; `setWebLifecycleState` produces a detectable page-vs-OS state mismatch.
- **Stay inside the tactic toolkit.** Scroll variants, native Escape, hard-fail. No arbitrary button clicks, no typing, no form submissions, no `location.reload()`.
- **Don't navigate elsewhere on x.com** except article URLs from step 4. The bookmarks page is the only source.
- **Don't try to handle non-X external links from bookmarks.** If a bookmark's tweet contains an external link (Twitter t.co or full https URL), summarize the tweet itself; do NOT follow the external link in the bot Chrome. Out of scope.
- **Don't advance state on Telegram failure.** Failed sends must NOT update `last-success.json` or append to `digested-urls.json`.
