#!/bin/bash
# telegram-send.sh — hardened curl-pattern Telegram delivery.
#
# Reads:
#   TELEGRAM_CHAT_ID            — target chat
#   TELEGRAM_MESSAGE_FILE       — HTML message body path
#   TELEGRAM_MESSAGE_PLAIN_FILE — plain-text fallback path
#   ~/.claude/channels/telegram/.env — TELEGRAM_BOT_TOKEN
#
# Writes:
#   $RUN_DIR/tg_response.json — Telegram's response
#
# Exit codes:
#   0 — sent successfully (HTML or plain-text fallback)
#   1 — Telegram returned ok:false even after plain-text retry
#   2 — curl/network/local parse failure (no retry — caller decides)
#
# Critical: payload routed via --data-urlencode "text@<file>" from file,
# NEVER from shell $(...). Multi-byte UTF-8 in emoji content can be mangled
# by shell interpolation → spurious retry → DUPLICATE MESSAGE bug. This
# was a real production incident; don't change this pattern.

set -uo pipefail

: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"
: "${TELEGRAM_MESSAGE_FILE:?TELEGRAM_MESSAGE_FILE is required}"
: "${TELEGRAM_MESSAGE_PLAIN_FILE:?TELEGRAM_MESSAGE_PLAIN_FILE is required}"

for f in "$TELEGRAM_MESSAGE_FILE" "$TELEGRAM_MESSAGE_PLAIN_FILE"; do
  [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 2; }
done

TOKEN_FILE="$HOME/.claude/channels/telegram/.env"
TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$TOKEN_FILE" | cut -d= -f2-)
if [ -z "$TOKEN" ]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN not found in $TOKEN_FILE" >&2
  exit 2
fi

RUN_DIR="${RUN_DIR:-/tmp/twitter-tg-resp-$$}"
mkdir -p "$RUN_DIR"
RESPONSE_FILE="$RUN_DIR/tg_response.json"

# Attempt 1: HTML.
curl -sS "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text@${TELEGRAM_MESSAGE_FILE}" \
  -d "parse_mode=HTML" \
  -d "disable_web_page_preview=true" \
  -o "$RESPONSE_FILE"
CURL_EXIT=$?
if [ "$CURL_EXIT" -ne 0 ]; then
  echo "telegram-send: curl exited $CURL_EXIT (no retry on network errors)" >&2
  exit 2
fi

OK=$(python3 -c "
import json, sys
try:
    r = json.load(open('$RESPONSE_FILE'))
    print(r.get('ok', False))
except Exception as e:
    print('parse_error:' + str(e), file=sys.stderr)
    print(False)
" 2>&1)

if [ "$OK" = "True" ]; then
  exit 0
fi

# Local parse error → don't retry (could double-send).
if echo "$OK" | grep -q 'parse_error'; then
  echo "telegram-send: local parse error on response (no retry): $OK" >&2
  exit 2
fi

# Telegram returned ok:false with valid JSON. One retry with plain text.
DESC=$(python3 -c "
import json
r = json.load(open('$RESPONSE_FILE'))
print(r.get('description', '<no description>'))
")
echo "telegram-send: HTML send returned ok:false ($DESC); retrying with plain text" >&2

curl -sS "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text@${TELEGRAM_MESSAGE_PLAIN_FILE}" \
  -d "disable_web_page_preview=true" \
  -o "$RESPONSE_FILE"
CURL_EXIT=$?
if [ "$CURL_EXIT" -ne 0 ]; then
  echo "telegram-send: plain-text retry curl exited $CURL_EXIT" >&2
  exit 1
fi

OK=$(python3 -c "
import json, sys
try:
    r = json.load(open('$RESPONSE_FILE'))
    print(r.get('ok', False))
except Exception as e:
    print('parse_error:' + str(e), file=sys.stderr)
    print(False)
" 2>&1)

if [ "$OK" = "True" ]; then
  exit 0
fi

# Mirror first-attempt parse-error handling — local parse error on retry response
# isn't really a Telegram "ok:false"; classify as transport (exit 2) so caller
# can distinguish from "Telegram explicitly rejected our retry".
if echo "$OK" | grep -q 'parse_error'; then
  echo "telegram-send: local parse error on plain-text retry response: $OK" >&2
  exit 2
fi

DESC=$(python3 -c "
import json
r = json.load(open('$RESPONSE_FILE'))
print(r.get('description', '<no description>'))
")
echo "telegram-send: plain-text retry also returned ok:false ($DESC)" >&2
exit 1
