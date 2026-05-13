#!/bin/bash
# extract-tweets.sh — single source of truth for tweet/bookmark DOM extraction.
#
# Reads the currently-rendered `article[data-testid="tweet"]` elements from the
# bot Chrome daemon via CDP and emits a clean JSON array to stdout. Caller is
# responsible for scrolling, deduping by (author, text), and accumulating across
# iterations.
#
# Reads (env):
#   MAX — max tiles to slice from the live DOM (default 80).
#
# Writes:
#   stdout — JSON array of tile objects. Each entry has shape:
#     {
#       "author":      string,      // "Name\n@handle\n·\n<date>" (raw, with newlines)
#       "text":        string,      // tweetText.innerText, truncated at 800 chars
#       "timeISO":     string|null, // ISO-8601 tweet authored date; null if no time
#       "statusUrl":   string|null, // "https://x.com/<author>/status/<id>"
#       "articleLink": string|null, // statusUrl if the tile is an X Article; null otherwise
#       "isPromoted":  bool         // true for ads / promoted tweets
#     }
#
# Exit codes:
#   0 — emitted JSON (may be empty array if no tiles currently rendered)
#   1 — browser-use CDP call failed (network / Chrome down)
#   2 — output parse failed (X DOM unexpectedly different; debug needed)
#
# X DOM gotchas baked in here so callers don't have to re-discover:
#
# - Tweet container: `article[data-testid="tweet"]`. Bookmarks use the same testid.
# - Article detection: X Articles do NOT expose `/article/` URLs in tiles. The
#   marker is `[data-testid="article-cover-image"]` AND empty tweetText. The
#   cover-image alone over-matches by ~3x (also fires on regular tweets with
#   Twitter Card link previews); combining with "no tweetText" eliminates the
#   false positives. Articles are reached via the regular statusUrl — X
#   redirects that URL to the article view.
# - JS wraps the return in `JSON.stringify(...)` so browser-use's stdout is
#   clean JSON (otherwise it prints Python `repr()` with `None`/`True` etc.)

set -uo pipefail

BROWSER_USE_BIN="/Users/pattybot/.local/bin/browser-use"
PYTHON_BIN="/usr/bin/python3"
CDP_URL="http://127.0.0.1:9222"
MAX="${MAX:-80}"

RAW=$("$BROWSER_USE_BIN" --cdp-url "$CDP_URL" eval "
  JSON.stringify(
    Array.from(document.querySelectorAll('article[data-testid=\"tweet\"]')).slice(0, ${MAX}).map(a => {
      const author = a.querySelector('[data-testid=\"User-Name\"]')?.innerText || '';
      const text = a.querySelector('[data-testid=\"tweetText\"]')?.innerText || '';
      const timeEl = a.querySelector('time');
      const timeISO = timeEl?.getAttribute('datetime') || null;
      const statusHref = timeEl?.closest('a')?.getAttribute('href')
        || a.querySelector('a[href*=\"/status/\"]')?.getAttribute('href')
        || null;
      const statusUrl = statusHref ? ('https://x.com' + statusHref) : null;
      const hasArticleCover = !!a.querySelector('[data-testid=\"article-cover-image\"]');
      const isArticle = hasArticleCover && text.length === 0;
      const articleLink = isArticle ? statusUrl : null;
      const containerText = a.innerText || '';
      const isPromoted = /\\bPromoted\\b|\\bAd\\b(?=\$|\\n)/.test(containerText) || !!a.querySelector('[data-testid=\"placementTracking\"]');
      return {author, text: text.slice(0, 800), timeISO, statusUrl, articleLink, isPromoted};
    })
  )
" 2>&1)
RC=$?

if [ "$RC" -ne 0 ]; then
  echo "extract-tweets: browser-use CDP call failed (rc=$RC): $RAW" >&2
  exit 1
fi

# browser-use prints "result: <stringified value>". Strip prefix, JSON-parse.
echo "$RAW" | "$PYTHON_BIN" -c '
import sys, json, re

raw = sys.stdin.read()
m = re.search(r"^result:\s*(.+)$", raw, re.MULTILINE | re.DOTALL)
val_str = m.group(1).strip() if m else raw.strip()

# The JS wraps its return in JSON.stringify, so browser-use prints a JSON
# string. Two layers: the outer is browser-use repr of the string ("[...]"),
# the inner is the JSON content.
try:
    # First try: the value is already valid JSON (most common path).
    val = json.loads(val_str)
except Exception:
    # Second try: browser-use may have quoted the JSON string in repr-style
    # single quotes (rare; depends on Python version). Strip outer quotes.
    if (val_str.startswith("'") and val_str.endswith("'")) or (val_str.startswith("\"") and val_str.endswith("\"")):
        try:
            val = json.loads(val_str[1:-1])
        except Exception as e:
            sys.stderr.write(f"extract-tweets: parse failed ({e}); raw[:200]={val_str[:200]!r}\n")
            sys.exit(2)
    else:
        sys.stderr.write(f"extract-tweets: JSON parse failed; raw[:200]={val_str[:200]!r}\n")
        sys.exit(2)

if not isinstance(val, list):
    sys.stderr.write(f"extract-tweets: expected list, got {type(val).__name__}\n")
    sys.exit(2)

json.dump(val, sys.stdout)
'
exit $?
