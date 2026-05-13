#!/bin/bash
# twitter-fire.sh — orchestrator for a single fire of one twitter skill.
#
# Usage:
#   twitter-fire.sh <skill-name>            # live fire
#   twitter-fire.sh <skill-name> --dry-run  # dry-run mode
#
# Steps:
#   1. Validate <skill-name> exists at ~/.claude/skills/<name>/SKILL.md.
#   2. Acquire shared flock on ~/.claude/skills/.twitter-fire.lock (non-blocking).
#      Exit 3 if another twitter-fire.sh is currently holding it.
#   3. Call twitter-prefire.sh, capture stdout.
#   4. Parse SAVED_FRONTMOST_PID and BOT_CHROME_PID from prefire output.
#   5. Invoke claude -p with the skill prompt (or dry-run variant).
#   6. Post-fire frontmost restore (only if bot Chrome still frontmost
#      and SAVED is valid).
#   7. Exit with claude's exit code.

set -uo pipefail

# Export env BEFORE any $HOME reference. launchd's default env is minimal;
# $HOME may be unset until we export it explicitly.
export HOME="/Users/pattybot"
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/Users/pattybot/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

CLAUDE_BIN="/Users/pattybot/.local/bin/claude"
BROWSER_USE_BIN="/Users/pattybot/.local/bin/browser-use"
NODE_BIN="/opt/homebrew/bin/node"
PREFIRE_BIN="$(dirname "$(realpath "$0")")/twitter-prefire.sh"
LOCK_FILE="$HOME/.claude/skills/.twitter-fire.lock"

LOG="$HOME/Library/Logs/twitter-fire.log"
mkdir -p "$(dirname "$LOG")"

SKILL_NAME="${1:-}"
DRY_RUN_FLAG="${2:-}"

if [ -z "$SKILL_NAME" ]; then
  echo "usage: twitter-fire.sh <skill-name> [--dry-run]" >&2
  exit 64
fi

SKILL_PATH="$HOME/.claude/skills/${SKILL_NAME}/SKILL.md"
if [ ! -f "$SKILL_PATH" ]; then
  echo "ERROR: skill not found at $SKILL_PATH" >&2
  exit 65
fi

# Sanity: baked-in binaries.
for bin in "$CLAUDE_BIN" "$BROWSER_USE_BIN" "$NODE_BIN" "$PREFIRE_BIN"; do
  if [ ! -x "$bin" ]; then
    echo "ERROR: missing binary $bin — reinstall or update wrapper paths" >&2
    exit 127
  fi
done

mkdir -p "$(dirname "$LOCK_FILE")"

# Acquire flock non-blocking. fd 200 is conventional.
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  HOLDER_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "?")
  mkdir -p "$HOME/.claude/skills/${SKILL_NAME}/state" 2>/dev/null || true
  echo "{\"kind\":\"busy\",\"at\":\"$(date -Iseconds)\",\"message\":\"another twitter-fire in progress (PID $HOLDER_PID)\"}" \
    > "$HOME/.claude/skills/${SKILL_NAME}/state/last-failure.json" 2>/dev/null || true
  {
    echo "===== fire $(date -Iseconds) skill=${SKILL_NAME} BUSY ====="
    echo "  another twitter-fire is holding the lock; holder PID=$HOLDER_PID"
    echo "----- exit 3 at $(date -Iseconds) -----"
  } >> "$LOG"
  exit 3
fi
echo $$ > "$LOCK_FILE"

{
  echo "===== fire $(date -Iseconds) skill=${SKILL_NAME} ====="

  # Call prefire, capture stdout for SAVED_FRONTMOST_PID parsing.
  PREFIRE_OUT=$("$PREFIRE_BIN" 2>&1)
  PREFIRE_EXIT=$?
  echo "$PREFIRE_OUT"
  if [ "$PREFIRE_EXIT" -ne 0 ]; then
    echo "----- exit $PREFIRE_EXIT (prefire failed) at $(date -Iseconds) -----"
    exit $PREFIRE_EXIT
  fi

  SAVED_FRONTMOST_PID=$(echo "$PREFIRE_OUT" | grep '^SAVED_FRONTMOST_PID=' | tail -1 | cut -d= -f2)
  BOT_CHROME_PID=$(echo "$PREFIRE_OUT" | grep -oE 'activating bot Chrome PID=[0-9]+' | head -1 | cut -d= -f2)

  # Compose claude -p prompt.
  if [[ "$DRY_RUN_FLAG" == "--dry-run" ]]; then
    PROMPT="Run the ${SKILL_NAME} skill defined in $SKILL_PATH in dry-run mode — execute it as described there but skip the Telegram send and state-file writes."
  else
    PROMPT="Run the ${SKILL_NAME} skill defined in $SKILL_PATH — execute it as described there."
  fi

  cd "$HOME"
  "$CLAUDE_BIN" -p "$PROMPT" --output-format text
  STATUS=$?

  # Post-fire frontmost restore. Only if:
  #   1. Saved PID is non-empty.
  #   2. Saved PID isn't the bot Chrome itself (would be no-op).
  #   3. Bot Chrome is STILL frontmost (user hasn't manually switched during scrape).
  if [ -n "$SAVED_FRONTMOST_PID" ] && [ -n "$BOT_CHROME_PID" ] && [ "$SAVED_FRONTMOST_PID" != "$BOT_CHROME_PID" ]; then
    POST_FIRE_FRONTMOST=$(osascript <<OSA 2>/dev/null
try
  with timeout of 3 seconds
    tell application "System Events"
      return unix id of first application process whose frontmost is true
    end tell
  end timeout
end try
OSA
)
    if [ "$POST_FIRE_FRONTMOST" = "$BOT_CHROME_PID" ]; then
      echo "  post-fire: restoring frontmost to PID=$SAVED_FRONTMOST_PID"
      osascript <<OSA 2>/dev/null || true
try
  with timeout of 5 seconds
    tell application "System Events"
      set frontmost of (first process whose unix id is $SAVED_FRONTMOST_PID) to true
    end tell
  end timeout
end try
OSA
    else
      echo "  post-fire: user moved to PID=$POST_FIRE_FRONTMOST during scrape; not restoring"
    fi
  fi

  echo "----- exit $STATUS at $(date -Iseconds) -----"
  exit $STATUS
} >> "$LOG" 2>&1
