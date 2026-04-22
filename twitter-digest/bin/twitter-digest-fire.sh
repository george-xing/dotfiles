#!/bin/bash
# twitter-digest-fire.sh — launchd entry point for the twice-daily X digest.
#
# What this does:
#   1. Health-check the bot Chrome daemon on 127.0.0.1:9222 (12s retry window
#      with JSON parse validation, so we don't false-fail on a transient
#      KeepAlive respawn gap).
#   2. Invoke `claude -p` with the twitter-digest skill prompt.
#   3. Append a dated block to the log; exit non-zero on failure so launchd
#      surfaces it.
#
# What this deliberately doesn't do:
#   - Quit/launch Chrome. The bot Chrome is owned by launchctl
#     (com.pattybot.twitter-bot-chrome). We never touch it directly. Quitting
#     it would just trigger KeepAlive respawn and lose tab state.
#   - browser-use close --all. Same reason — the daemon Chrome's CDP session
#     must persist; the skill attaches via --cdp-url, doesn't spawn anything.
#   - osascript anything. Two Chrome.app instances are indistinguishable to
#     AppleScript, so any `tell app "Google Chrome"` would target the wrong one.
#
# Usage:
#   twitter-digest-fire.sh            # live — sends digest to Telegram
#   twitter-digest-fire.sh --dry-run  # composes digest, prints to log, no Telegram

set -uo pipefail

# Absolute paths baked at install time — launchd's default PATH is minimal.
CLAUDE_BIN="/Users/pattybot/.local/bin/claude"
BROWSER_USE_BIN="/Users/pattybot/.local/bin/browser-use"
NODE_BIN="/opt/homebrew/bin/node"
DAEMON_PORT=9222
DAEMON_URL="http://127.0.0.1:${DAEMON_PORT}/json/version"

# PATH covers the dirs the above binaries live in, plus the usual system dirs
# so anything the skill shells out to (curl, python3) is reachable.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/Users/pattybot/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export HOME="/Users/pattybot"

LOG="$HOME/Library/Logs/twitter-digest.log"
mkdir -p "$(dirname "$LOG")"

# Wait up to 12s for the daemon Chrome to be reachable AND return a valid JSON
# /json/version response. KeepAlive can momentarily produce ECONNREFUSED during
# a respawn (e.g. Chrome auto-update); we don't want to fail on that. We also
# require a parseable {"Browser": "..."} body — a 200 alone isn't enough.
wait_for_daemon() {
  local i response
  for i in $(seq 1 12); do
    response=$(curl -fsS --max-time 2 "$DAEMON_URL" 2>/dev/null) || { sleep 1; continue; }
    if echo "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "Browser" in d else 1)' 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

{
  echo "===== fire $(date -Iseconds) ====="

  # Sanity: baked-in binaries still where we expect.
  for bin in "$CLAUDE_BIN" "$BROWSER_USE_BIN" "$NODE_BIN"; do
    if [ ! -x "$bin" ]; then
      echo "ERROR: missing binary $bin — reinstall or update wrapper paths" >&2
      exit 127
    fi
  done

  # Daemon health check. If the daemon isn't responding within 12s, abort —
  # don't waste a claude -p turn that will fail at step 2 anyway.
  if ! wait_for_daemon; then
    echo "ERROR: daemon Chrome at $DAEMON_URL not responding after 12s" >&2
    echo "  Check: launchctl print gui/\$(id -u)/com.pattybot.twitter-bot-chrome" >&2
    echo "  Logs:  ~/Library/Logs/twitter-bot-chrome.{out,err}.log" >&2
    exit 2
  fi

  PROMPT="run the twitter-digest skill"
  if [[ "${1:-}" == "--dry-run" ]]; then
    PROMPT="run the twitter-digest skill in dry-run mode"
  fi

  cd "$HOME"
  "$CLAUDE_BIN" -p "$PROMPT" --output-format text
  STATUS=$?

  echo "----- exit $STATUS at $(date -Iseconds) -----"
  exit $STATUS
} >> "$LOG" 2>&1
