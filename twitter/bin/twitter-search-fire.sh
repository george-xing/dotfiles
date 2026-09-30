#!/bin/bash
# twitter-search-fire.sh — safe query-file bridge into the shared Twitter fire.

set -uo pipefail

export HOME="/Users/pattybot"
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PYTHON_BIN="/usr/bin/python3"
FIRE_BIN="/Users/pattybot/dotfiles/twitter/bin/twitter-fire.sh"
REQUEST_ROOT="$HOME/.hermes/tmp/twitter-search-requests"
REQUEST_FILE="${1:-}"
MODE="${2:-}"

usage() {
  echo "usage: twitter-search-fire.sh <request-file> [--dry-run|--validate-only]" >&2
}

if [ -z "$REQUEST_FILE" ]; then
  usage
  exit 64
fi

if [ -n "$MODE" ] && [ "$MODE" != "--dry-run" ] && [ "$MODE" != "--validate-only" ]; then
  usage
  exit 64
fi

mkdir -p "$REQUEST_ROOT"

# Validate with Python so symlinks, traversal, UTF-8, and Unicode length are
# handled consistently. Query contents never enter a shell command.
VALIDATION=$(
  REQUEST_ROOT="$REQUEST_ROOT" REQUEST_FILE="$REQUEST_FILE" "$PYTHON_BIN" -c '
import os
import re
import sys
from pathlib import Path

root = Path(os.environ["REQUEST_ROOT"]).resolve()
candidate = Path(os.environ["REQUEST_FILE"])

if not re.fullmatch(r"request-[A-Za-z0-9_-]+\.txt", candidate.name):
    print("request filename must match request-[A-Za-z0-9_-]+.txt")
    raise SystemExit(1)
if candidate.is_symlink():
    print("request file may not be a symlink")
    raise SystemExit(1)
try:
    resolved = candidate.resolve(strict=True)
except OSError as exc:
    print(f"request file is unreadable: {exc}")
    raise SystemExit(1)
if resolved.parent != root:
    print("request file is outside the allowed request directory")
    raise SystemExit(1)
if not resolved.is_file():
    print("request path is not a regular file")
    raise SystemExit(1)
if resolved.stat().st_size > 1024:
    print("request file exceeds 1 KiB")
    raise SystemExit(1)
try:
    query = " ".join(resolved.read_text(encoding="utf-8").split())
except (OSError, UnicodeError) as exc:
    print(f"request is not readable UTF-8: {exc}")
    raise SystemExit(1)
if not query:
    print("search query is empty")
    raise SystemExit(1)
if len(query) > 280:
    print("search query exceeds 280 characters")
    raise SystemExit(1)
print("ok")
' 2>&1
)
VALIDATION_EXIT=$?

if [ "$VALIDATION_EXIT" -ne 0 ]; then
  echo "twitter-search-fire: $VALIDATION" >&2
  exit 66
fi

# The helper owns only its tightly validated ephemeral request file.
cleanup() {
  rm -f -- "$REQUEST_FILE"
}
trap cleanup EXIT INT TERM

if [ "$MODE" = "--validate-only" ]; then
  echo "valid twitter search request"
  exit 0
fi

export TWITTER_SEARCH_QUERY_FILE="$REQUEST_FILE"

if [ "$MODE" = "--dry-run" ]; then
  "$FIRE_BIN" twitter-search --dry-run
else
  "$FIRE_BIN" twitter-search
fi
exit $?
