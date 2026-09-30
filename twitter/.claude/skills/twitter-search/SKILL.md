---
name: twitter-search
description: Generate an on-demand X (Twitter) search summary for an arbitrary keyword, phrase, hashtag, cashtag, account, or supported X search expression. Attach to the persistent bot Chrome over CDP, open X's Top search results for the supplied query, scroll the result feed, synthesize what people are saying with representative post links, and deliver the brief to Telegram. Use only through twitter-search-fire.sh after a Telegram request such as "/twitter_search QUERY", "search X for QUERY", "what is Twitter saying about QUERY", or "summarize tweets about QUERY".
---

# Twitter Search Summary

Run an on-demand search brief against the same authenticated Chrome profile and shared lock used by `twitter-digest`. Search X's default **Top** results so the brief reflects the ranked search feed a person sees after using the search bar. Do not read the Home/For You feed and do not mutate either digest's dedup state.

## Inputs and invariants

- Read the request path from `TWITTER_SEARCH_QUERY_FILE`. Accept only a regular, non-symlink file directly under `/Users/pattybot/.hermes/tmp/twitter-search-requests/` whose basename matches `request-[A-Za-z0-9_-]+.txt` and whose size is at most 1 KiB.
- Decode as UTF-8, collapse whitespace, and require 1-280 Unicode characters. Treat the whole value as X search text, never as shell, JavaScript, HTML, or a filesystem path.
- Preserve valid X search syntax such as quoted phrases, `from:`, `to:`, `lang:`, `since:`, `until:`, hashtags, and cashtags.
- Attach only to the launchd-managed Chrome at `http://127.0.0.1:9222`. Never spawn or close a browser.
- Use `/Users/pattybot/dotfiles/twitter/bin/lib/extract-tweets.sh` for tweet extraction and `/Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh` for delivery.
- Use state only under `~/.claude/skills/twitter-search/state/`. This skill has no persistent URL dedup: a repeated query should summarize the current ranked results again.

Reject an invalid query by writing `state/last-failure.json` with `kind: "query"`, a UTC ISO timestamp, and a concise message; then stop without navigating or sending Telegram.

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

### 1. Load and encode the query

Use Python path and text APIs for validation. Build the destination with `urllib.parse.urlencode`:

```python
"https://x.com/search?" + urlencode({"q": query, "src": "typed_query"})
```

Do not concatenate raw query text into a shell command or JavaScript string. Keep both the normalized query and encoded URL for later composition.

### 2. Open X search and verify

Open the encoded URL with `/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh open <url>`, wait about 4 seconds, then probe:

- `document.visibilityState === "visible"`
- viewport dimensions are non-zero
- `[data-testid="primaryColumn"]` exists
- `[data-testid="SearchBox_Search_Input"]` exists and its current value matches the normalized query
- no `/login` or `/i/flow/login` wall exists

Use the shared failure handling in `/Users/pattybot/.claude/skills/twitter-digest/references/shared-operational-patterns.md` for `visibility`, `auth`, and `dom`. `Page.bringToFront` is the only CDP visibility recovery; never use `Page.setWebLifecycleState`.

Search-specific degraded visibility proof: after the single allowed
`Page.bringToFront` attempt, do not fail solely because
`document.visibilityState` still says `hidden` when all of the following are
true: the origin is exactly `https://x.com`, the route is `/search`, authenticated profile navigation exists, the viewport is non-zero, the primary column exists, the search input
exactly matches the normalized query, no login wall exists, and a read-only
`MAX=5 extract-tweets.sh` probe returns at least one substantive result from
the current search page. Record `visibilityDegraded: true` in the temporary
run context and continue. Do not write a provisional visibility failure before
the extraction probe completes, and never retain one after the degraded proof
succeeds. If that proof fails, write the categorized `visibility` failure and
stop.

Do not click Home, For You, Following, or Latest. Remaining on the default Top search tab is intentional.

### 3. Scroll and collect search results

Collect substantive, non-promoted results for up to **3 minutes**, stopping earlier at roughly **150 unique posts** or a convincing plateau after recovery tactics are exhausted.

Run the repetitive scroll, sleep, extraction, JSON accumulation/dedupe,
counter, and elapsed-time work inside **one terminal loop**. Do not spend one
model/API turn per scroll. Return to model reasoning after collection ends or
on a categorized hard failure.

Alternate:

```bash
/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh eval "window.scrollBy(0, 1500); 'ok'"
sleep 1.5
MAX=80 /Users/pattybot/dotfiles/twitter/bin/lib/extract-tweets.sh
```

Accumulate across iterations and dedupe by `statusUrl` when present, otherwise `(author, text)`. Drop promoted entries, missing timestamps, missing status URLs, and empty non-article text. Do not apply the Home digest's persisted URL dedup.

If two ordinary scrolls yield nothing new, use `scrollIntoView({block:'end'})` on the last rendered tweet. After three consecutive zero-new iterations across both tactics, first press native Escape when a visible `[role="dialog"]` exists and the cap remains, then scroll to the top and resume. Only if that semantic fast path does not apply or does not recover should you follow screenshot-then-judge, saving screenshots under `state/stalls/` and keeping the newest 10.

Allowed recovery tactics:

- `window.scrollTo(0, 0)`, at most 2 times
- native Escape, at most 2 times, for an obstructing dialog
- `scrollIntoView` on the last tweet
- categorized hard failure

Do not type, submit forms, click search tabs or dismissal buttons, reload, visit Home, or navigate into individual posts/articles during collection.

### 4. Synthesize what people are saying

Treat the collected posts as a ranked, personalized sample—not a representative poll and not verified facts. Prefer recurring independently expressed themes over isolated viral claims. Explicitly distinguish:

- repeated themes or consensus-like observations
- meaningful disagreements or competing frames
- the apparent tone of the sampled results
- notable claims that are repeated but unverified
- suspected duplicates, engagement bait, or coordinated copy when visible

Do not invent counts or sentiment percentages. Every factual description of a post must be attributed to its author or to "posts in the sampled results."

Compose Telegram HTML under 3,900 characters:

```text
🔎 <b>X search brief — &lt;query&gt;</b>

<b>Bottom line</b>
&lt;2-4 sentence synthesis&gt;

<b>Main themes</b>
• &lt;theme and how commonly it appeared&gt;
• …

<b>Disagreements</b>
• &lt;competing positions; omit section if none&gt;

<b>Tone</b>
&lt;short qualitative description&gt;

<b>Representative posts</b>
• <a href="&lt;statusUrl&gt;">@author</a>: &lt;one-line attributed summary&gt;
• …

—
&lt;N&gt; posts sampled · &lt;M&gt; minutes scrolled · Top results

<i>Summary of an X search sample; claims are attributed and not independently verified.</i>
```

Include 4-8 representative links spanning the major viewpoints. Escape `&`, `<`, and `>` in every dynamic string before insertion while preserving the intended Telegram HTML tags. Also create an equivalent plain-text fallback. If zero substantive results remain, send `No substantive X search results found for “<query>”.`

### 5. Pending state and delivery

Before a live send, write `state/pending.json` with `runAt`, normalized `query`, `scrolledFor`, `resultCount`, and `telegramOk: null`. Write the HTML and plain-text messages under `/tmp/twitter-search-run/`, then call:

```bash
TELEGRAM_CHAT_ID=7953915703 \
TELEGRAM_MESSAGE_FILE=/tmp/twitter-search-run/search.html \
TELEGRAM_MESSAGE_PLAIN_FILE=/tmp/twitter-search-run/search.txt \
RUN_DIR=/tmp/twitter-search-run \
  /Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh
```

Interpret exit codes exactly as documented in the shared operational patterns. On delivery failure, write a fresh `kind: "telegram"` failure and do not finalize success.

The fresh `RUN_DIR/tg_response.json` API receipt is authoritative if the
terminal tool's exit code disagrees with it. If it contains `ok: true`, an
integer `result.message_id`, the expected chat ID, and a Telegram message date
from this run, treat delivery as successful, do not retry, and finalize state.
The production wrapper independently verifies the same receipt as a final
guard against a model/tool-status false negative.

### 6. Finalize success

There is no dedup append. After Telegram succeeds, set `telegramOk` to `true` in a temporary JSON file, atomically replace `state/last-success.json`, and remove `pending.json`. Do not modify `twitter-digest` or `twitter-bookmarks` state.

## Dry run

When the prompt says dry-run, perform the query and composition but skip pending state, Telegram delivery, and all state writes. Print the composed HTML and a concise count summary. Never close the daemon Chrome.

## Failure handling

Write fresh failures under `~/.claude/skills/twitter-search/state/last-failure.json` using kinds `query`, `visibility`, `auth`, `dom`, `telegram`, or `stall`. Include an absolute screenshot path when visual classification produced one. On any hard failure, do not send a separate Telegram alert; the Hermes dispatcher reports the background process exit.
