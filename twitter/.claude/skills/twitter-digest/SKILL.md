---
name: twitter-digest
description: Generate the X (Twitter) digest — attaches via CDP to a long-running bot Chrome daemon (launchctl-managed, persistent profile, debug port 9222), scrolls x.com/home, scores candidate posts, writes a candidate audit, groups selected posts into dynamic sections, separately flags + summarizes any long-form X Articles, and delivers to Telegram. Fires twice daily via launchd — morning at 08:00 ET (overnight recap) and evening at 22:00 ET (daytime recap). Use when the user asks for "twitter digest", "morning digest", "evening recap", "X digest", "what's new on twitter", or when fired by launchd.
---

# Twitter Digest

Twice-daily job: attach to the persistent bot Chrome on `127.0.0.1:9222`, scroll x.com/home, score candidate posts, write a candidate audit, summarize selected content into dynamic Telegram sections. The two scheduled fires are 08:00 ET (overnight recap) and 22:00 ET (daytime recap). **No time cutoff** — the natural stop signal is URL dedup against `state/digested-urls.json` (we don't repeat anything we've already summarized) + the 3-min wall budget + feed plateau. This mirrors how a human reads X: scroll until you recognize stuff you've already seen, then stop. Designed to be fired headlessly via `claude -p` from launchd, but works fine when invoked interactively.

## Inputs (from environment / state)

- **Browser**: long-running daemon Chrome managed by the `com.pattybot.twitter-bot-chrome` LaunchAgent, listening on `http://127.0.0.1:9222` for CDP. Persistent user-data-dir at `$HOME/Library/Application Support/twitter-bot-chrome`. Auth state (X cookies) lives in that profile and is set by manual sign-in via the bot Chrome window — NOT by cookie import. **Never spawn a new browser-use Chrome with `--profile` or `--headed` — always attach via `--cdp-url`.**
- **Lookback**: no time cutoff. URL dedup is the natural stop signal — a human reads until they recognize already-seen content.
- **URL dedup**: `state/digested-urls.json` is an array of `{url, digestedAt}` entries listing every `statusUrl` actually shipped in a prior run. At extract time, drop any tweet whose `statusUrl` is in this set. After a successful run, append only URLs whose audit row has `shipped:true` and prune entries older than 7 days. (7d TTL is enough — X's For You almost never re-surfaces anything older than ~3 days, so URLs falling out of the dedup set won't realistically come back.)
- **Candidate audit**: every run writes `state/candidate-audits/<runAt>.json` with every unique extracted tile that had enough structure to reason about, including drafted posts, shipped posts, rejected posts, and hard-filtered-but-explainable posts such as promoted / already-digested / no-status-url. This is the product feedback loop for checking whether useful posts are being filtered out.
- **Telegram bot token**: parse from `~/.claude/channels/telegram/.env` (key `TELEGRAM_BOT_TOKEN`).
- **Telegram chat_id**: `7953915703`.
- **Selection guide**: read `references/themes.md` before composing. It defines interest anchors, scoring dimensions, dynamic section behavior, and rejection reason codes. Edits to that file flow into the next digest with no other change.

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

- `vis !== "visible"` or `iw === 0` → try CDP `Page.bringToFront` once, wait 1s, then re-probe. If still not visible, write `kind:"visibility"` and exit non-zero. Never use `Page.setWebLifecycleState("active")`.
- `hasLoginWall === true` or `title` matches the public landing → write `kind:"auth"` and exit. Do not attempt login.
- `hasPrimaryColumn === false` despite `vis === "visible"` and no login wall → write `kind:"dom"` and exit.

For operator recovery detail, see `references/runbook.md`. For the Page.bringToFront rationale and rejected visibility fixes, see `references/recovery-tactics.md`.

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

A useful internal target is **~50 substantive tweets** — enough to triage 2-3 substantive bullets per cluster. Don't stop early on hitting it; don't fail or escalate on missing it. It's a "is this run going well?" indicator that shapes how aggressively to recover from stalls (well below → keep trying recovery tactics; well above → let plateaus end naturally).

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

1. **Scroll-extract loop**: alternate scroll + call the shared extraction helper. Pause 1-2s after each scroll for hydration:

   ```bash
   # Scroll.
   browser-use --cdp-url http://127.0.0.1:9222 eval "window.scrollBy(0, 1500); 'ok'"
   sleep 1.5

   # Extract currently-rendered tiles. Helper returns clean JSON.
   TILES_JSON=$(MAX=80 /Users/pattybot/dotfiles/twitter/bin/lib/extract-tweets.sh)
   ```

   `TILES_JSON` is a JSON array of `{author, text, timeISO, statusUrl, articleLink, isPromoted}`. Inspect `/Users/pattybot/dotfiles/twitter/bin/lib/extract-tweets.sh` for the canonical DOM selectors and the article-detection heuristic (article-cover-image testid AND empty tweetText — combining both eliminates the ~3x false-positive rate that cover-image alone produces on regular tweets with Twitter Card link previews; empirically 151 tiles → 42 cover-image hits → 15 true articles).

   Dedupe by `(author, text)` — later scrolls re-emit earlier tweets, and the dedupe key has to be content-based since X's `data-testid` IDs aren't stable across virtualization recycles.

2. **When `scrollBy` plateaus** (no new uniques after ~2 scrolls): try `scrollIntoView` on the last article. If that also plateaus (3 consecutive zero-new across both), invoke step 3a (screenshot-then-judge) to pick the next move from the toolkit.

3. **Stop the entire run when**:
   - Wall budget elapsed (3 min total), OR
   - The For You feed is convincingly exhausted (3a screenshot shows "you're all caught up" / repeated tweets / no obstruction, AND no recovery tactic has any caps remaining), OR
   - A hard-fail `kind` is set.

   Don't stop early on hitting 50 — content quality scales with volume (more raw → better triage → more substantive bullets per dynamic section), so always burn the full wall budget when content's flowing. Use `len(seen)` against 50 to decide how patient to be at stalls: well under → spend a recovery cap to push through; well over → let the plateau end naturally.

4. **Anti-pattern to avoid: stale-percentage-based early termination.** Per-scroll tracing on For You shows `stale%` oscillates wildly between 30% and 100% even while fresh content is still being surfaced — the algorithm interleaves pockets of old and new. A "3 consecutive scrolls > N% stale" rule fires on the stale pockets and misses the fresh ones right after.

#### Filters

- **Hard filter at extract time**:
  - Drop every tweet where `isPromoted === true`.
  - Drop entries with no `timeISO` — they're typically promoted/structurally-anomalous.
  - Drop every tweet whose `statusUrl` is in `state/digested-urls.json` — already summarized in a prior run.
- **Soft filter at triage time**: marketing / influencer-shill content (see `references/themes.md` → "Triage rules"). Also downweight obviously stale content — if a tweet's relative timestamp is "3d" or older AND the substance is time-sensitive (e.g. a "BREAKING:" tweet from days ago, a sports score), drop it. Evergreen content (essays, opinions, references) at any age is fine if it survived URL dedup. Record soft-filter decisions in the candidate audit rather than silently discarding them.
- **Audit filter decisions**: hard-filtered items should not enter scoring or Telegram composition, but they should appear in the candidate audit when they have a stable enough `statusUrl` / author / text to make the reason useful. Use `selectedForDraft:false`, `shipped:false`, `section:null`, and `rejectionReason:"promoted"`, `"already_digested"`, `"no_status_url"`, or the matching reason code.

**Note on URL dedup vs. triage**: only *shipped* URLs (the bullets that actually reached Telegram) get added to `digested-urls.json`, NOT every URL we scrolled past. So a tweet that was scraped but dropped in triage one run can be re-evaluated cleanly the next run if the algo re-surfaces it — borderline content gets a second chance to make the cut. The candidate audit records the previous rejection, but it is not a dedup source.

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

#### Tactic dispatch notes

Use native `browser-use keys "Escape"` for modal recovery; never synthesize DOM keyboard events. For the reasoning behind native Escape, tactic caps, and the restricted toolkit, see `/Users/pattybot/.claude/skills/twitter-digest/references/recovery-tactics.md`.

### 4. Pull long-form articles (after scroll loop ends)

X Articles are uncommon. When one appears, the article-page DOM may differ; be defensive.

For each unique `articleLink`:

```bash
ARTICLE_JSON=$(/Users/pattybot/dotfiles/twitter/bin/lib/extract-article.sh "$ARTICLE_URL")
# ARTICLE_JSON is {title, author, body, bodyLen}.
```

The helper navigates the bot Chrome to `$ARTICLE_URL`, sleeps 3s for hydration, then extracts via the dedicated `[data-testid="twitterArticleRichTextView"]` (body) and `[data-testid="twitter-article-title"]` (title) selectors with legacy fallbacks. Returns clean JSON. Inspect `/Users/pattybot/dotfiles/twitter/bin/lib/extract-article.sh` for the full selector fallback chain.

Sanity check: if `bodyLen < 500` and the URL still resolves to the article, the selectors missed the body container. Don't summarize from a tiny body — instead screenshot for the operator (`browser-use --cdp-url http://127.0.0.1:9222 screenshot /tmp/twitter-digest-article-debug.png`) and emit a one-line "📰 extraction failed" entry, then continue. Operator updates selectors next iteration.

Otherwise summarize each article in 2-3 sentences. Capture `{ title, author, url, summary }`.

### 5. Score, audit, dynamically classify, and compose

Read `references/themes.md` and apply the scoring + triage rules. Do this in four passes:

1. **Score every candidate before assigning a section.** For each unique tweet that survived hard extraction filters, produce integer 0-5 scores for `importance`, `novelty`, `personal_relevance`, `substance`, and `delight`. Also produce `scores.total`, `candidateLabels` (at least one rough label such as `AI`, `NYC`, `science`, `startup_markets`, unless the rejection is exactly `low_substance` or `off_topic`), and a short `scoreReason`. Labels must be meaningful enough to explain what the post was about; do not use `random`, `misc`, or `other` as the only label. `scoreReason` must explain the concrete reason for the score/rejection; do not use placeholders like `auto-labeled; not selected`. For hard-filtered rows, skip scoring and record the rejection reason.
2. **Select the strongest posts independent of section shape.** Pick the posts that are actually useful or interesting; do not drop a strong post just because it does not fit AI / Startups / NYC / Random. Use rejection reason codes from `references/themes.md` for everything plausible but not selected.
3. **Run a rescue pass before finalizing the draft.** Re-check rejected posts for personal utility, AI tooling/coding-agent relevance, high-signal accounts, science/health follow-ups, and anything stronger than the weakest selected item. Rescue useful oddballs into a small `Worth a skim` / `Useful odds & ends` section instead of forcing them into an old anchor.
4. **Write the candidate audit before composing Telegram.** The audit is durable even if the Telegram send later fails, so the operator can inspect what was seen and why items were selected or rejected.
5. **Derive dynamic sections from the selected posts.** Name sections after the actual clusters in this run. The old anchors can appear when they fit, but do not force them. Use 2-5 tweet sections, plus `📰 Long-form articles` when articles qualify.

Do not build the audit with a generic fallback pass that assigns `candidateLabels:["random"]` or `scoreReason:"auto-labeled; not selected"` to the long tail. If the candidate set is large, use concise but specific labels and reasons in batches: for example `culture` + `weak_personal_fit`, `sports` + `off_topic`, `markets` + `duplicate_topic`, `AI`/`coding_agents` + `lower_score_than_cluster`, `health` + `telegram_budget`. The audit is useful only if a rejected row is understandable without re-reading the original tweet.

Candidate audit shape: top-level `runAt`, `dryRun`, `scrolledFor`, `rawTileCount`, `auditedTileCount`, `candidateCount`, `selectedForDraftCount`, `shippedCount`, `sectionNames`, `shippedUrls`, and `candidates[]`. Each candidate should include `statusUrl`, `author`, `timeISO`, `text`, `articleLink`, `hardFiltered`, `scores` (`importance`, `novelty`, `personal_relevance`, `substance`, `delight`, `total`), `candidateLabels`, `selectedForDraft`, `shipped`, `section`, `rejectionReason`, `cutReason`, and `scoreReason`.

Field semantics:

- `selectedForDraft:true` means the post survived triage and was intended for the digest before Telegram length / final composition cuts.
- `shipped:true` means the post actually appears in the Telegram message. Only these URLs belong in `shippedUrls` and `SUMMARIZED_URLS_JSON`.
- `cutReason` is required when `selectedForDraft:true` but `shipped:false` (`telegram_budget`, `article_budget`, `duplicate_topic`, etc.).
- `rejectionReason` is for candidates never selected for the draft; leave it null for shipped posts. Use `lower_score_than_cluster` only when the candidate shares a meaningful label with a selected post and lost to stronger coverage in that same cluster. Otherwise use a specific reason such as `weak_personal_fit`, `weak_utility`, `duplicate_topic`, `off_topic`, `stale_time_sensitive`, or `telegram_budget`.

Write it with an atomic temp-file replacement and prune to the last 30 audits:

```bash
AUDITS_DIR=~/.claude/skills/twitter-digest/state/candidate-audits
mkdir -p "$AUDITS_DIR"
RUN_AT=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
AUDIT_PATH="$AUDITS_DIR/$(printf '%s' "$RUN_AT" | tr ':+' '--').json"

# Compose $CANDIDATE_AUDIT_JSON as valid JSON matching the schema above. If the
# JSON is large, prefer writing it from Python with json.dump instead of passing
# it through additional shell commands.
printf '%s' "$CANDIDATE_AUDIT_JSON" > "$AUDIT_PATH.tmp"
python3 -m json.tool "$AUDIT_PATH.tmp" > "$AUDIT_PATH.pretty"
mv "$AUDIT_PATH.pretty" "$AUDIT_PATH"
rm -f "$AUDIT_PATH.tmp"

ls -t "$AUDITS_DIR"/*.json 2>/dev/null | tail -n +31 | xargs -I {} rm -f {}
```

After writing the audit, run the QA helper and log its output:

```bash
/Users/pattybot/dotfiles/twitter/bin/lib/validate-candidate-audit.py "$AUDIT_PATH"
AUDIT_QA_EXIT=$?
```

Exit non-zero if `AUDIT_QA_EXIT` is non-zero; that means the audit is structurally misleading (for example `shippedUrls` doesn't match `shipped:true` rows). Warnings are allowed to ship but should appear in the run log; they flag quality risks such as blank labels, collapsed scoring, high-personal-relevance rejects or cuts, selected/delivered divergence, and `lower_score_than_cluster` used outside a selected cluster.

Compose HTML (NOT Markdown — Telegram's legacy Markdown breaks on `_*[` in tweet text; HTML mode is more predictable):

Pick the header based on local clock hour at compose time:
- `4 ≤ hour < 16` (morning fires, primarily 08:00 run): `🌅 <b>Morning digest — <date></b>`
- Otherwise (evening fires, primarily 22:00 run): `🌆 <b>Evening recap — <date></b>`

Everything below the header is the same regardless of which fire ran.

```
<🌅 Morning digest | 🌆 Evening recap> — <date>

<dynamic emoji> <b><dynamic section name></b>
• <a href="<statusUrl>">@author tweeted</a>: <one-line summary>
• <a href="<statusUrl>">@author posted</a>: <one-line summary>

<dynamic emoji> <b><dynamic section name></b>
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

If a dynamic section has zero items, omit it entirely. If literally no overnight content qualifies, send a single line `Nothing notable on X 🥱` instead of a multi-section empty digest.

After composing, write the candidate-linked tweet bullets to `$RUN_DIR/digest.html` / `$RUN_DIR/digest.txt` and run the digest-output verifier before Telegram (or before printing in dry-run):

```bash
/Users/pattybot/dotfiles/twitter/bin/lib/validate-digest-output.py "$AUDIT_PATH" "$RUN_DIR/digest.html"
DIGEST_QA_EXIT=$?
```

Exit non-zero if `DIGEST_QA_EXIT` is non-zero. This catches stale hard-coded summary maps, `<missing summary>` placeholders, and cases where the actual composed tweet bullets diverge from `shippedUrls` / `shippedCount`. Do not send Telegram, append dedup, or advance state if this verifier fails.

### 6. Pre-send: write pending state

Before calling Telegram, write `state/pending.json` so a crash mid-send leaves a recoverable trace:

```bash
PENDING=~/.claude/skills/twitter-digest/state/pending.json
NOW=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
cat > "$PENDING" <<EOF
{"runAt": "$NOW", "scrolledFor": $SCROLL_SECONDS, "tweetCount": $TWEET_COUNT, "articleCount": $ARTICLE_COUNT, "auditPath": "$AUDIT_PATH", "shippedUrls": $SUMMARIZED_URLS_JSON, "telegramOk": null}
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
# $SUMMARIZED_URLS_JSON is the JSON array of statusUrls whose audit rows have shipped:true.
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

If invoked with "dry-run" or "--dry-run" in the prompt, still run extraction, scoring, dynamic classification, and candidate-audit writing with `"dryRun": true`. Then print the composed digest HTML to stdout and skip pending.json, Telegram, URL dedup, and last-success update. Useful for iterating on selection/format without spamming the chat.

Do NOT call `browser-use close --all` even in dry-run — the daemon Chrome stays up always.

## Failure handling

Categorize failures and write `state/last-failure.json` with `{kind, at, message}` plus optional `screenshot` — an absolute path to a CDP-captured PNG of the visible state at failure time. Step 3a always captures screenshots for stall-derived failures; step 4 already does for article-extraction failures; step 2's hard-fails may include them when useful. Operators read the screenshot to disambiguate similar failure modes (e.g. "is this `auth` or `dom`?" — the image makes it obvious).

`kind` values: `visibility`, `auth`, `dom`, `telegram`, `empty`, and `stall`. For the full operator-side taxonomy and recovery expectations, see `/Users/pattybot/.claude/skills/twitter-digest/references/recovery-tactics.md`.

In all hard-fail cases, do NOT advance `last-success.json` and do NOT append to `digested-urls.json` — a failed run shouldn't mark its un-shipped content as already-summarized.

In all hard-fail cases, do NOT send a Telegram alert about the failure. Operator finds it in the log.

## What NOT to do

See `/Users/pattybot/dotfiles/twitter/CLAUDE.md` section "What 'fixing it' usually does NOT mean" for the canonical rejected-fixes list with full reasoning. Keep new rejected fixes there so this section does not drift.
