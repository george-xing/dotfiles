---
name: twitter-digest
description: Generate the X (Twitter) digest — attaches via CDP to a long-running bot Chrome daemon (launchctl-managed, persistent profile, debug port 9222), scrolls x.com/home, themes content since the last run (AI / Startups / NYC / Random), separately flags + summarizes any long-form X Articles, and delivers to Telegram. Fires twice daily via launchd — morning at 08:00 ET (overnight recap) and evening at 22:00 ET (daytime recap). Use when the user asks for "twitter digest", "morning digest", "evening recap", "X digest", "what's new on twitter", or when fired by launchd.
---

# Twitter Digest

Twice-daily job: attach to the persistent bot Chrome on `127.0.0.1:9222`, scroll x.com/home, summarize themed content into Telegram. The two scheduled fires are 08:00 ET (overnight recap) and 22:00 ET (daytime recap). **No time cutoff** — the natural stop signal is URL dedup against `state/digested-urls.json` (we don't repeat anything we've already summarized) + the 5-min collection wall budget + feed plateau. This mirrors how a human reads X: scroll until you recognize stuff you've already seen, then stop. Designed to be executed by a Hermes one-shot through `twitter-fire.sh`, whether fired by Hermes cron or on demand.

## Inputs (from environment / state)

- **Browser**: long-running daemon Chrome managed by the `com.pattybot.twitter-bot-chrome` LaunchAgent, listening on `http://127.0.0.1:9222` for CDP. Persistent user-data-dir at `$HOME/Library/Application Support/twitter-bot-chrome`. Auth state (X cookies) lives in that profile and is set by manual sign-in via the bot Chrome window — NOT by cookie import. **Never spawn a new browser-use Chrome with `--profile` or `--headed` — always attach via `--cdp-url`.**
- **Lookback**: no time cutoff. URL dedup is the natural stop signal — a human reads until they recognize already-seen content.
- **URL dedup**: `state/digested-urls.json` is an array of `{url, digestedAt}` entries listing every `statusUrl` actually summarized in a prior run. At extract time, drop any tweet whose `statusUrl` is in this set. After a successful run, append the URLs of summarized bullets and prune entries older than 7 days. (7d TTL is enough — X's For You almost never re-surfaces anything older than ~3 days, so URLs falling out of the dedup set won't realistically come back.)
- **Telegram bot token**: parse from `~/.claude/channels/telegram/.env` (key `TELEGRAM_BOT_TOKEN`).
- **Telegram chat_id**: `7953915703`.
- **Themes**: read `references/themes.md` before composing — edits to that file flow into the next digest with no other change.

## Browser isolation and locked-desktop operation

Use `/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh` for every browser
command (for example `open`, `eval`, `keys`, `screenshot`). This helper pins the
compatible CLI and explicitly selects the dedicated `twitter-production` CDP
session. Never substitute a bare `browser-use`, `browser_exec`, or a new Chrome.
Digest, bookmarks, and search share the wrapper's existing lock; other Hermes
requests can continue in their own browsers.

A locked Mac can leave a fully usable X page `hidden`. After one native
`Page.bringToFront` attempt, permit background reading only when the exact
`https://x.com` origin and intended route are verified (`/home`, `/i/bookmarks`,
or `/search` with the requested search input). X also redirects bookmarks to
`/i/history`; accept that route only when the selected `[role="tab"]` is
`Bookmarks` (never Likes). Require a non-zero viewport,
`[data-testid="primaryColumn"]` and authenticated
`[data-testid="AppTabBar_Profile_Link"]` navigation exist, no login wall exists,
and the shared `extract-tweets.sh` returns at least one substantive post with
text or article link, timestamp and status URL. Record `visibilityDegraded: true`.
A blank document title alone does not indicate logout on a hidden page.
Apply this content proof whenever desktop visibility is unavailable.
If the proof fails, stop with the appropriate auth/dom/visibility failure;
never fake visibility, unlock the Mac, or click its desktop/lock screen.

## Workflow

**Production collector invariant:** steps 1–3 are implemented by the checked-in
`/Users/pattybot/dotfiles/twitter/bin/lib/collect-digest.py` helper. Invoke that
helper once; do not write a throwaway collector, recreate the scroll loop, or
call an image/vision tool to classify its screenshots. The helper owns the
bounded browser loop, categorized hard failures, recoveries, persistent stall
screenshots, and clean-plateau decision. Screenshots are forensic artifacts;
scheduled execution continues from the helper's JSON outputs without a
multimodal model round trip.

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

The production collector performs this step. It navigates through
`twitter-browser.sh`, requires the exact X Home route and authenticated profile
navigation, rejects login walls and zero-sized viewports, and verifies the
primary column. When the desktop is locked, it also requires actual feed
extraction before accepting background operation. A blank title on a hidden
tab does not prove logout. See the browser isolation section above.

Do not separately navigate or run a second collector; the setup steps below
are implemented by `collect-digest.py`.

### 2b. Refresh feed via Home-tab click

Click the left-nav Home tab while already on `/home`. This is the canonical X gesture for "give me a fresh feed" and triggers an SPA same-route handler that scrolls to top, auto-expands any pending "See new posts" pill, and **re-issues a fresh `home_timeline` API request**. Without this, a long-idle daemon Chrome session can drift into algorithmic throttle where scroll/scrollIntoView won't surface more than a tiny initial batch (the May 8 morning run hit this, plateauing at 4-5 tweets even after every other recovery tactic was exhausted).

```bash
/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh eval "
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
/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh eval "
  const tabs = document.querySelectorAll('[role=\\"tablist\\"] [role=\\"tab\\"]');
  const fyt = Array.from(tabs).find(t => /for you/i.test(t.innerText));
  const clicked = !!fyt && fyt.getAttribute('aria-selected') !== 'true';
  if (clicked) fyt.click();
  ({clicked})
"
sleep 2
```

Never re-click an already-selected For You tab: current X opens **Snooze Topics**
and locks feed scrolling. The collector verifies that For You is selected.

### 3. Gather feed content

**Goal**: accumulate **as many substantive (non-promoted) tweets as the For You feed will yield** within a **5-minute collection wall budget**, using whatever sanctioned tactics the observed state demands. **For You is the only source** — the digest is a faithful read of what X's algorithm surfaced for the user, not a synthetic catch-up assembled from chronological backfill. If For You is sparse (cold-start after long idle, modal-interrupted prefetch, transient throttle), ship under-target rather than reaching elsewhere.

This step is intentionally framed as "goal + sanctioned toolkit," not a prescribed loop. The For You feed has many soft-failure modes — algorithmic cold-start, modal interstitials, mid-run prefetch hiccups, virtualization glitches, transient throttles. A rigid "scroll-stall-ship" loop ships thin digests on any of them. The runtime should iterate tactics from the toolkit until the budget is exhausted, the feed plateaus convincingly, or every sanctioned tactic has been tried without yielding new content.

**George’s scan-breadth preference: aim for at least 150 unique eligible tweets per run**, after promoted/missing-timestamp filters and prior-delivery URL dedup. This is a collection target, **not 150 digest bullets**; keep editorial triage selective. Do not stop merely on reaching 150. Below target, use the existing bounded recoveries; ship an honest shortfall if the feed exhausts them or the wall budget expires, without failing or escalating solely for missing the target. Defaults are `TWITTER_DIGEST_HEALTHY_TARGET=150` and `TWITTER_DIGEST_WALL_SECONDS=300`; do not lower them unless George requests it. The unchanged 600-second wrapper deadline leaves time for setup, article extraction, triage and delivery.

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

Run the production collector exactly once:

```bash
/usr/bin/python3 /Users/pattybot/dotfiles/twitter/bin/lib/collect-digest.py
```

On exit `0`, read all three outputs before triage:

- `/tmp/twitter-digest-run/candidates.json` — filtered, URL-deduplicated tweet candidates.
- `/tmp/twitter-digest-run/articles.json` — unique article tiles found during collection.
- `/tmp/twitter-digest-run/collection.json` — actual unique eligible `scanned` count, `scanTarget`, `scanShortfall`, `wallBudgetSeconds`, elapsed time, stop reason, recovery counts, and optional forensic screenshot path.

`reason: "wall_budget"` and `reason: "clean_plateau"` are both normal success
conditions. Continue directly to article extraction and editorial triage. **Do
not call `vision_analyze`, inspect the screenshot, or restart collection.** A
nonzero exit has already written the categorized `last-failure.json`; stop the
workflow without delivery or state advancement.

The helper alternates `scrollBy` and `scrollIntoView`, calls the canonical
`extract-tweets.sh`, applies hard filters and persistent URL dedup, and spends
bounded recovery caps when the feed stalls below the healthy target. Once a
healthy feed has yielded at least 150 unique eligible candidates and run for at least two
minutes, a repeated clean plateau ships what was accumulated. This avoids
turning a routine end-of-feed screenshot into a fragile multimodal model call.

On a verified hidden page, the helper requests a browser screenshot after each
scroll before extraction. A locked Chrome can update scroll position without
rendering X's virtualized timeline; the screenshot requests a real frame so new
tiles appear. It overwrites `/tmp/twitter-digest-run/background-frame.png`,
records `backgroundFrames`, and never sends the image to a model. This does not
change page visibility, lifecycle, or desktop state.

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

### 3a. Stall handling (implemented by the production collector)

When the source stalls, `collect-digest.py` applies the sanctioned recoveries,
re-probes visibility/auth/DOM state, captures a forensic screenshot when it
ships on a clean plateau, and writes the decision to `collection.json`.

The helper fingerprints visible dialogs and spends at most one native Escape
attempt per distinct dialog signature; a persistent selector match cannot burn
the cap repeatedly. It checks rendered descendants of zero-height dialog roots
and verifies that Escape removed the obstruction. A persistent or recurring
blocking dialog is `kind: stall`, never a clean plateau. At every mature stall it re-probes page visibility,
authentication, and the primary column before deciding that a plateau is
clean. Under-target feeds spend the bounded `scrollTo(0, 0)` and Home-refresh
recoveries before shipping under target.

Screenshots persist under `state/stalls/` for operator forensics and the helper
keeps the last 10. Scheduled execution never opens, analyzes, or attaches them.
The categorized failure record—not model interpretation of pixels—is the
automation contract. For the operator-side screenshot taxonomy, see
`references/runbook.md` and `references/recovery-tactics.md`.

### 4. Pull long-form articles (after scroll loop ends)

X Articles are uncommon. When one appears, the article-page DOM may differ; be defensive.

For each unique `articleLink`:

```bash
ARTICLE_JSON=$(/Users/pattybot/dotfiles/twitter/bin/lib/extract-article.sh "$ARTICLE_URL")
# ARTICLE_JSON is {title, author, body, bodyLen}.
```

The helper navigates the bot Chrome to `$ARTICLE_URL`, sleeps 3s for hydration, then extracts via the dedicated `[data-testid="twitterArticleRichTextView"]` (body) and `[data-testid="twitter-article-title"]` (title) selectors with legacy fallbacks. Returns clean JSON. Inspect `/Users/pattybot/dotfiles/twitter/bin/lib/extract-article.sh` for the full selector fallback chain.

Sanity check: if `bodyLen < 500` and the URL still resolves to the article, the selectors missed the body container. Don't summarize from a tiny body — instead screenshot for the operator (`/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh screenshot /tmp/twitter-digest-article-debug.png`) and emit a one-line "📰 extraction failed" entry, then continue. Operator updates selectors next iteration.

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

**Scan reporting:** use the actual `scanned` count from `collection.json` in the footer, never the target or bullet count. Include `target <scanTarget>`; when `scanShortfall > 0`, also include `<scanShortfall> below target (<reason>)`. Retain these facts in the run report even when no content merits a digest. Do not imply that a bounded successful run necessarily reached 150.

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

`kind` values: `visibility`, `auth`, `dom`, `telegram`, `empty`, and `stall`. For the full operator-side taxonomy and recovery expectations, see `/Users/pattybot/.claude/skills/twitter-digest/references/recovery-tactics.md`.

In all hard-fail cases, do NOT advance `last-success.json` and do NOT append to `digested-urls.json` — a failed run shouldn't mark its un-shipped content as already-summarized.

In all hard-fail cases, do NOT send a Telegram alert about the failure. Operator finds it in the log.

## What NOT to do

See `/Users/pattybot/dotfiles/twitter/CLAUDE.md` section "What 'fixing it' usually does NOT mean" for the canonical rejected-fixes list with full reasoning. Keep new rejected fixes there so this section does not drift.
