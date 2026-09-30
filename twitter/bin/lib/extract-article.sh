#!/bin/bash
# extract-article.sh — navigate bot Chrome to an X Article URL and extract body.
#
# Usage:
#   extract-article.sh <article_url>
#
# Writes to stdout a single JSON object:
#   {
#     "title":   string,  // article title (clean, no metadata)
#     "author":  string,  // "Name\n@handle" (or longer with verified marker)
#     "body":    string,  // article body, truncated at 12000 chars
#     "bodyLen": int      // full length of bodyEl.innerText before truncation
#   }
#
# Exit codes:
#   0 — emitted JSON
#   1 — browser-use navigation failed (network / Chrome down / bad URL)
#   2 — output parse failed (unexpected DOM)
#
# X Article extraction selectors (priority order):
#
# Title:
#   1. [data-testid="twitter-article-title"]   ← clean dedicated selector
#   2. h1                                       ← typical fallback
#   3. [data-testid="article-title"]           ← legacy testid (may not exist on current X)
#   4. document.title                           ← last-resort, includes "X" suffix
#
# Body:
#   1. [data-testid="twitterArticleRichTextView"]  ← clean dedicated selector
#   2. [data-testid="longformText"]                ← legacy
#   3. [data-testid="article-body"]                ← legacy
#   4. article                                      ← fallback, includes view counts/reply
#   5. body                                         ← last-resort

set -uo pipefail

BROWSER_USE_BIN="/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh"
PYTHON_BIN="/usr/bin/python3"

ARTICLE_URL="${1:-}"
if [ -z "$ARTICLE_URL" ]; then
  echo "usage: extract-article.sh <article_url>" >&2
  exit 64
fi

# Step 1: navigate.
"$BROWSER_USE_BIN" open "$ARTICLE_URL" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "extract-article: navigation to $ARTICLE_URL failed (rc=$RC)" >&2
  exit 1
fi
sleep 3

# Step 2: extract via CDP eval. JS wraps result in JSON.stringify for clean stdout.
RAW=$("$BROWSER_USE_BIN" eval "
  JSON.stringify((() => {
    const titleEl = document.querySelector('[data-testid=\"twitter-article-title\"]')
                || document.querySelector('h1')
                || document.querySelector('[data-testid=\"article-title\"]');
    const bodyEl = document.querySelector('[data-testid=\"twitterArticleRichTextView\"]')
                || document.querySelector('[data-testid=\"longformText\"]')
                || document.querySelector('[data-testid=\"article-body\"]')
                || document.querySelector('article')
                || document.body;
    const bodyText = bodyEl?.innerText || '';
    return {
      title: titleEl?.innerText || document.title,
      author: document.querySelector('[data-testid=\"User-Name\"]')?.innerText
           || document.querySelector('[data-testid=\"article-author\"]')?.innerText
           || '',
      body: bodyText.slice(0, 12000),
      bodyLen: bodyText.length
    };
  })())
" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "extract-article: CDP eval failed (rc=$RC): $RAW" >&2
  exit 1
fi

echo "$RAW" | "$PYTHON_BIN" -c '
import sys, json, re

raw = sys.stdin.read()
m = re.search(r"^result:\s*(.+)$", raw, re.MULTILINE | re.DOTALL)
val_str = m.group(1).strip() if m else raw.strip()

try:
    val = json.loads(val_str)
except Exception:
    if (val_str.startswith("'\''") and val_str.endswith("'\''")) or (val_str.startswith("\"") and val_str.endswith("\"")):
        try:
            val = json.loads(val_str[1:-1])
        except Exception as e:
            sys.stderr.write(f"extract-article: parse failed ({e}); raw[:200]={val_str[:200]!r}\n")
            sys.exit(2)
    else:
        sys.stderr.write(f"extract-article: JSON parse failed; raw[:200]={val_str[:200]!r}\n")
        sys.exit(2)

if not isinstance(val, dict):
    sys.stderr.write(f"extract-article: expected dict, got {type(val).__name__}\n")
    sys.exit(2)

json.dump(val, sys.stdout)
'
exit $?
