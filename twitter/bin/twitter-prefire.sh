#!/bin/bash
# Health-check the dedicated Chrome, then prepare its native/CDP window.
# Locked desktops are supported through the workflows' content verification.
# No Apple Events, desktop clicks, browser spawning, or Telegram delivery.
# Output ends with SAVED_FRONTMOST_PID=<pid_or_empty>; exit 2 means no daemon.

set -uo pipefail

DAEMON_PORT=9222
DAEMON_URL="http://127.0.0.1:${DAEMON_PORT}/json/version"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"

if [ ! -x "$PYTHON_BIN" ]; then
  echo "ERROR: Python helper is not executable: $PYTHON_BIN" >&2
  exit 1
fi

export PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

wait_for_daemon() {
  local deadline response
  deadline=$(( $(date +%s) + 12 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    response=$(curl -fsS --max-time 2 "$DAEMON_URL" 2>/dev/null) || { sleep 1; continue; }
    if echo "$response" | "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "Browser" in d else 1)' 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! wait_for_daemon; then
  echo "ERROR: daemon Chrome at $DAEMON_URL not responding after 12s" >&2
  echo "  Check: launchctl print gui/\$(id -u)/com.pattybot.twitter-bot-chrome" >&2
  echo "  Logs:  ~/Library/Logs/twitter-bot-chrome.{out,err}.log" >&2
  exit 2
fi

# Native AppKit/CDP preparation also works from the gateway's launchd context.
# A locked desktop is expected for unattended work: the workflow must prove
# authenticated page content instead of treating a focus attempt as success.
"$(dirname "$(realpath "$0")")/lib/twitter-window.py"
