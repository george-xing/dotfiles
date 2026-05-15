#!/bin/bash
# twitter-fire.sh — orchestrator for a single fire of one twitter skill.
#
# Usage:
#   twitter-fire.sh <skill-name>            # live fire
#   twitter-fire.sh <skill-name> --dry-run  # dry-run mode
#
# Steps:
#   1. Validate <skill-name> exists at ~/.claude/skills/<name>/SKILL.md.
#   2. Acquire shared lock at ~/.claude/skills/.twitter-fire.lock via shlock(1).
#      Exit 3 (kind:busy) if another twitter-fire is currently holding it.
#   3. Call twitter-prefire.sh, capture stdout.
#   4. Parse SAVED_FRONTMOST_PID and BOT_CHROME_PID from prefire output.
#   5. Invoke claude -p with the skill prompt (or dry-run variant).
#   6. Post-fire frontmost restore (only if bot Chrome still frontmost).
#   7. Release lock; exit with claude's exit code.
#
# All non-zero exits write a kind-tagged ~/.claude/skills/<skill>/state/last-failure.json
# so the dispatch skill can relay failure to Telegram. Timestamps are UTC ISO-8601
# to be safely lexicographically comparable across timezones.

set -uo pipefail

# Export env BEFORE any $HOME reference. launchd's default env is minimal.
export HOME="/Users/pattybot"
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/Users/pattybot/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

CLAUDE_BIN="/Users/pattybot/.local/bin/claude"
BROWSER_USE_BIN="/Users/pattybot/.local/bin/browser-use"
NODE_BIN="/opt/homebrew/bin/node"
SHLOCK_BIN="/usr/bin/shlock"
PYTHON_BIN="/usr/bin/python3"
PREFIRE_BIN="$(dirname "$(realpath "$0")")/twitter-prefire.sh"
LOCK_FILE="$HOME/.claude/skills/.twitter-fire.lock"

LOG="$HOME/Library/Logs/twitter-fire.log"
mkdir -p "$(dirname "$LOG")"

SKILL_NAME="${1:-}"
DRY_RUN_FLAG="${2:-}"

# UTC ISO timestamp helper — all `at` fields in failure files use this so
# lexicographic comparisons across producers (wrapper + skill + dispatch) work.
iso_utc_now() {
  "$PYTHON_BIN" -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())"
}

# Write a kind-tagged last-failure.json so dispatch's MCP relay can surface
# wrapper-side failures (missing binaries, prefire failure, busy) that previously
# only landed in the log. Skill-name may be empty if the failure is pre-validation.
write_failure() {
  local kind="$1"
  local message="$2"
  local skill="${3:-$SKILL_NAME}"
  [ -z "$skill" ] && return 0
  local state_dir="$HOME/.claude/skills/${skill}/state"
  mkdir -p "$state_dir" 2>/dev/null || return 0
  local at
  at=$(iso_utc_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S+00:00)
  # JSON-escape message (basic — message is wrapper-controlled so no untrusted content)
  local esc_msg
  esc_msg=$(printf '%s' "$message" | "$PYTHON_BIN" -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$message")
  printf '{"kind":"%s","at":"%s","message":%s}\n' "$kind" "$at" "$esc_msg" \
    > "${state_dir}/last-failure.json" 2>/dev/null || true
}

# Sibling Chrome daemons that share Google Chrome.app's NSApplication and would
# occlude bot Chrome via macOS window-server z-order. Per
# project_twitter_digest_macmini_arch.md, bot Chrome must be the SOLE Chrome in
# pattybot's session for vis:visible to hold reliably under launchd-fired runs
# (where osascript activation gets denied by TCC and the skill's Page.bringToFront
# recovery can't always overcome a sibling occluder).
#
# Strategy: snapshot which sibling jobs are loaded right now, bootout each one,
# fire the digest, then bootstrap them back from their plists. The restore runs
# in the EXIT trap so it survives claude crashes, prefire failures, and signals.
SIBLING_CHROME_LABELS=(
  com.pattybot.cards-bot-chrome
  com.pattybot.cards-keepalive
)
BOOTOUTED_SIBLINGS=()

bootout_sibling_chromes() {
  local label uid
  uid=$(id -u)
  for label in "${SIBLING_CHROME_LABELS[@]}"; do
    if launchctl list "$label" >/dev/null 2>&1; then
      if launchctl bootout "gui/${uid}/${label}" 2>/dev/null; then
        BOOTOUTED_SIBLINGS+=("$label")
        echo "  sibling-bootout: $label"
      else
        echo "  sibling-bootout: WARN $label bootout failed (proceeding anyway)"
      fi
    fi
  done
  # Give WindowServer a beat to fire the un-occlusion event on bot Chrome before
  # prefire's CDP un-minimize / activation runs against a possibly-stale state.
  [ ${#BOOTOUTED_SIBLINGS[@]} -gt 0 ] && sleep 2
}

restore_sibling_chromes() {
  local label plist uid
  uid=$(id -u)
  for label in "${BOOTOUTED_SIBLINGS[@]}"; do
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    if [ ! -f "$plist" ]; then
      echo "  sibling-restore: WARN plist missing at $plist; cannot restore $label"
      continue
    fi
    if launchctl bootstrap "gui/${uid}" "$plist" 2>/dev/null; then
      echo "  sibling-restore: $label"
    else
      echo "  sibling-restore: WARN $label bootstrap failed — manual restart needed"
    fi
  done
}

if [ -z "$SKILL_NAME" ]; then
  echo "usage: twitter-fire.sh <skill-name> [--dry-run]" >&2
  exit 64
fi

SKILL_PATH="$HOME/.claude/skills/${SKILL_NAME}/SKILL.md"
if [ ! -f "$SKILL_PATH" ]; then
  echo "ERROR: skill not found at $SKILL_PATH" >&2
  write_failure "config" "skill not found at $SKILL_PATH"
  exit 65
fi

# Sanity: baked-in binaries.
for bin in "$CLAUDE_BIN" "$BROWSER_USE_BIN" "$NODE_BIN" "$SHLOCK_BIN" "$PYTHON_BIN" "$PREFIRE_BIN"; do
  if [ ! -x "$bin" ]; then
    echo "ERROR: missing binary $bin — reinstall or update wrapper paths" >&2
    write_failure "config" "missing binary $bin"
    exit 127
  fi
done

mkdir -p "$(dirname "$LOCK_FILE")"

# Acquire lock via shlock(1) — macOS-native PID-file locking with built-in
# stale-PID detection. If lock is held by a live process, exits non-zero.
# If lock file exists but holder is dead, shlock cleans it and acquires.
if ! "$SHLOCK_BIN" -p $$ -f "$LOCK_FILE"; then
  HOLDER_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "?")
  write_failure "busy" "another twitter-fire in progress (PID $HOLDER_PID)"
  {
    echo "===== fire $(iso_utc_now) skill=${SKILL_NAME} BUSY ====="
    echo "  another twitter-fire is holding the lock; holder PID=$HOLDER_PID"
    echo "----- exit 3 at $(iso_utc_now) -----"
  } >> "$LOG"
  exit 3
fi

# Ensure lock is released and sibling Chrome daemons are restored on any exit
# path (claude crash, signal, prefire failure). Group the redirect so the
# trap's output lands in $LOG — the orchestration block's redirect closes
# before the trap fires.
trap '{ restore_sibling_chromes; rm -f "$LOCK_FILE"; } >> "$LOG" 2>&1' EXIT INT TERM

{
  echo "===== fire $(iso_utc_now) skill=${SKILL_NAME} ====="

  bootout_sibling_chromes

  # Call prefire, capture stdout for SAVED_FRONTMOST_PID parsing.
  PREFIRE_OUT=$("$PREFIRE_BIN" 2>&1)
  PREFIRE_EXIT=$?
  echo "$PREFIRE_OUT"
  if [ "$PREFIRE_EXIT" -ne 0 ]; then
    write_failure "prefire" "twitter-prefire.sh exited $PREFIRE_EXIT (see ~/Library/Logs/twitter-fire.log)"
    echo "----- exit $PREFIRE_EXIT (prefire failed) at $(iso_utc_now) -----"
    exit $PREFIRE_EXIT
  fi

  SAVED_FRONTMOST_PID=$(echo "$PREFIRE_OUT" | grep '^SAVED_FRONTMOST_PID=' | tail -1 | cut -d= -f2)
  BOT_CHROME_PID=$(echo "$PREFIRE_OUT" | grep -oE 'activating bot Chrome PID=[0-9]+' | head -1 | cut -d= -f2)

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
  #   2. Saved PID isn't the bot Chrome itself.
  #   3. Bot Chrome is STILL frontmost (user hasn't manually switched).
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

  echo "----- exit $STATUS at $(iso_utc_now) -----"
  exit $STATUS
} >> "$LOG" 2>&1
