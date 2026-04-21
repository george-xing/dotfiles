#!/bin/bash
# twitter-digest-fire.sh — launchd entry point for the daily X digest.
#
# Sets PATH/locale so headless `claude -p` finds browser-use and curl,
# appends a dated block to the log, and exits non-zero on failure so
# launchd surfaces the issue.
#
# Usage:
#   twitter-digest-fire.sh            # live — sends digest to Telegram
#   twitter-digest-fire.sh --dry-run  # composes digest, prints to log, no Telegram

set -uo pipefail

# Absolute paths baked at install time — launchd's default PATH is minimal and
# bare `claude`/`browser-use` would not be found.
CLAUDE_BIN="/Users/pattybot/.local/bin/claude"
BROWSER_USE_BIN="/Users/pattybot/.local/bin/browser-use"
NODE_BIN="/opt/homebrew/bin/node"

# PATH covers the dirs the above binaries live in, plus the usual system dirs
# so anything the skill shells out to (curl, python3, osascript) is reachable.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/Users/pattybot/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export HOME="/Users/pattybot"

LOG="$HOME/Library/Logs/twitter-digest.log"
mkdir -p "$(dirname "$LOG")"

{
  echo "===== fire $(date -Iseconds) ====="

  # Sanity: make sure the baked-in binaries are still where we expected.
  for bin in "$CLAUDE_BIN" "$BROWSER_USE_BIN" "$NODE_BIN"; do
    if [ ! -x "$bin" ]; then
      echo "ERROR: missing binary $bin — reinstall or update wrapper paths" >&2
      exit 127
    fi
  done

  # Best-effort: close any leftover browser-use session so `--profile Patty`
  # can reopen cleanly. `close --all` is idempotent (no-op if nothing open).
  "$BROWSER_USE_BIN" close --all >/dev/null 2>&1 || true

  # Choose prompt: dry-run iff the first arg is --dry-run.
  PROMPT="run the twitter-digest skill"
  if [[ "${1:-}" == "--dry-run" ]]; then
    PROMPT="run the twitter-digest skill in dry-run mode"
  fi

  cd "$HOME"
  "$CLAUDE_BIN" -p "$PROMPT" --output-format text
  STATUS=$?

  # Belt-and-suspenders cleanup: if the skill's own close failed, make sure
  # we aren't leaving a zombie browser-use daemon across fires.
  "$BROWSER_USE_BIN" close --all >/dev/null 2>&1 || true

  echo "----- exit $STATUS at $(date -Iseconds) -----"
  exit $STATUS
} >> "$LOG" 2>&1
