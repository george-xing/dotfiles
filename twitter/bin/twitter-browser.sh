#!/bin/bash
# Shared CDP client for digest, bookmarks, and search. The wrapper's PID lock
# serializes these workflows; unrelated Hermes sessions use another client.
set -euo pipefail

CLIENT="${TWITTER_BROWSER_USE_BIN:-/Users/pattybot/.local/lib/twitter-browser/bin/browser-use}"
SESSION="${TWITTER_BROWSER_SESSION:-twitter-production}"
CDP_URL="${TWITTER_CDP_URL:-http://127.0.0.1:9222}"

if [[ -z "$SESSION" || "$SESSION" == default || "$SESSION" == *[!a-zA-Z0-9_-]* ]]; then
  echo 'twitter-browser: use a dedicated named session, never default' >&2
  exit 64
fi
# Callers supply a command, never global options that could override routing.
case "${1:-}" in
  open|eval|state|screenshot|keys|scroll|click|input|type|switch|tabs) ;;
  *) echo 'twitter-browser: expected a browser command; session/endpoint are owned by this helper' >&2; exit 64 ;;
esac
exec "$CLIENT" --session "$SESSION" --cdp-url "$CDP_URL" "$@"
