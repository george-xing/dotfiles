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
#   5. Clear any already-visible X dialog with a native Escape.
#   6. Invoke Hermes one-shot behind a hard process-group deadline.
#   7. Require a fresh delivery-success record before accepting exit 0.
#   8. Post-fire frontmost restore (only if bot Chrome still frontmost).
#   9. Release lock; exit with the verified workflow status.
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

HERMES_BIN="${TWITTER_HERMES_BIN:-/Users/pattybot/.local/bin/hermes}"
BROWSER_USE_BIN="/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh"
WINDOW_BIN="/Users/pattybot/dotfiles/twitter/bin/lib/twitter-window.py"
NODE_BIN="/opt/homebrew/bin/node"
SHLOCK_BIN="/usr/bin/shlock"
PYTHON_BIN="/usr/bin/python3"
PREFIRE_BIN="$(dirname "$(realpath "$0")")/twitter-prefire.sh"
AGENT_RUNNER_BIN="$(dirname "$(realpath "$0")")/lib/run-with-timeout.py"
DELIVERY_STATE_BIN="$(dirname "$(realpath "$0")")/lib/verify-delivery-state.py"
LOCK_FILE="$HOME/.claude/skills/.twitter-fire.lock"

LOG="$HOME/Library/Logs/twitter-fire.log"
mkdir -p "$(dirname "$LOG")"

SKILL_NAME="${1:-}"
DRY_RUN_FLAG="${2:-}"
ACTIVE_RUNNER_PID=""
AGENT_OUTPUT_FILE=""

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
for bin in "$HERMES_BIN" "$BROWSER_USE_BIN" "$NODE_BIN" "$SHLOCK_BIN" "$PYTHON_BIN" "$PREFIRE_BIN" "$AGENT_RUNNER_BIN" "$DELIVERY_STATE_BIN" "$WINDOW_BIN"; do
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

# Ensure a signal cannot orphan the timeout runner or its Hermes process group.
cleanup() {
  if [ -n "$ACTIVE_RUNNER_PID" ] && kill -0 "$ACTIVE_RUNNER_PID" 2>/dev/null; then
    kill -TERM "$ACTIVE_RUNNER_PID" 2>/dev/null || true
    wait "$ACTIVE_RUNNER_PID" 2>/dev/null || true
  fi
  [ -n "$AGENT_OUTPUT_FILE" ] && rm -f "$AGENT_OUTPUT_FILE"
  rm -f "$LOCK_FILE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

FIRE_STARTED_AT=$(iso_utc_now)

{
  echo "===== fire ${FIRE_STARTED_AT} skill=${SKILL_NAME} ====="

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

  # Global X interstitials can survive navigation and block every source. A
  # native Escape is non-committing and harmless when no dialog is present.
  # Doing this once before the agent starts avoids spending a vision/model turn
  # classifying common prompts such as "Snooze Topics".
  if "$BROWSER_USE_BIN" keys "Escape" >/dev/null 2>&1; then
    echo "  pre-agent: sent native Escape to clear any existing X dialog"
  else
    echo "  pre-agent: WARN native Escape preflight failed; skill recovery remains available"
  fi

  if [[ "$DRY_RUN_FLAG" == "--dry-run" ]]; then
    PROMPT="Read $SKILL_PATH completely and execute that ${SKILL_NAME} workflow yourself in dry-run mode using Hermes tools directly. Do not invoke Claude or any other agent. Batch repetitive scroll/extract work inside terminal loops instead of spending one model turn per scroll. Skip the Telegram send and all state-file writes. Return a concise parity-test result."
  else
    PROMPT="Read $SKILL_PATH completely and execute that ${SKILL_NAME} workflow yourself using Hermes tools directly. Do not invoke Claude or any other agent. Batch repetitive scroll/extract work inside terminal loops instead of spending one model turn per scroll. Execute the live delivery and state contract exactly as described."
  fi
  PROMPT="$PROMPT Use /Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh for all browser commands; it owns the isolated Twitter session. Do not use a bare browser-use command or Hermes browser_exec for this production workflow. The Mac may be locked; apply the skill's authenticated background-content checks instead of requiring desktop focus."

  if [ "$SKILL_NAME" = "twitter-digest" ]; then
    PROMPT="$PROMPT For steps 1-3, invoke /usr/bin/python3 /Users/pattybot/dotfiles/twitter/bin/lib/collect-digest.py exactly once. Continue from its JSON outputs. Do not create another collector and do not call an image or vision tool for a stall screenshot."
  fi

  if [ "$SKILL_NAME" = "twitter-search" ]; then
    if [ -z "${TWITTER_SEARCH_QUERY_FILE:-}" ]; then
      write_failure "query" "TWITTER_SEARCH_QUERY_FILE was not supplied by twitter-search-fire.sh"
      echo "  wrapper: missing validated Twitter search request path"
      exit 66
    fi
    PROMPT="$PROMPT The production bridge already validated the search request. Its file path is $TWITTER_SEARCH_QUERY_FILE. Read that file exactly as the skill directs; do not ask the user for a query."
  fi

  case "$SKILL_NAME" in
    twitter-bookmarks) DEFAULT_AGENT_TIMEOUT_SECONDS=900 ;;
    twitter-digest|twitter-search) DEFAULT_AGENT_TIMEOUT_SECONDS=600 ;;
    *) DEFAULT_AGENT_TIMEOUT_SECONDS=600 ;;
  esac
  AGENT_TIMEOUT_SECONDS="${TWITTER_FIRE_TIMEOUT_SECONDS:-$DEFAULT_AGENT_TIMEOUT_SECONDS}"
  AGENT_KILL_GRACE_SECONDS="${TWITTER_FIRE_KILL_GRACE_SECONDS:-10}"
  AGENT_OUTPUT_FILE="/tmp/twitter-${SKILL_NAME}-agent-$$.log"

  cd "$HOME"
  # The outer deadline is deliberately independent of Hermes's stream-idle
  # watchdog. Providers may emit keepalives forever; that is activity to the
  # stream watchdog but not useful progress for this finite production job.
  HERMES_CODEX_HARD_TIMEOUT_SECONDS="${HERMES_CODEX_HARD_TIMEOUT_SECONDS:-180}" \
    "$PYTHON_BIN" "$AGENT_RUNNER_BIN" \
      --timeout "$AGENT_TIMEOUT_SECONDS" \
      --grace "$AGENT_KILL_GRACE_SECONDS" \
      -- "$HERMES_BIN" -z "$PROMPT" \
      > "$AGENT_OUTPUT_FILE" 2>&1 &
  ACTIVE_RUNNER_PID=$!
  wait "$ACTIVE_RUNNER_PID"
  STATUS=$?
  ACTIVE_RUNNER_PID=""
  cat "$AGENT_OUTPUT_FILE"

  # Hermes one-shot returns 0 for a final text response, including apology/error
  # text. Live success is therefore proven by state, never by process status.
  FAILURE_FILE="$HOME/.claude/skills/${SKILL_NAME}/state/last-failure.json"
  SUCCESS_FILE="$HOME/.claude/skills/${SKILL_NAME}/state/last-success.json"
  STATE_DIR="$HOME/.claude/skills/${SKILL_NAME}/state"

  # Telegram's API response is the authoritative delivery receipt. A Hermes
  # tool result can occasionally report a non-zero command status even though
  # sendMessage returned ok:true. Reconcile only a fresh, same-chat search
  # response so an old artifact can never turn a new run into success.
  if [ "$STATUS" -eq 0 ] && [ "$DRY_RUN_FLAG" != "--dry-run" ] && [ "$SKILL_NAME" = "twitter-search" ]; then
    RECONCILED=$(
      "$PYTHON_BIN" "$DELIVERY_STATE_BIN" reconcile-search \
        "$STATE_DIR" "/tmp/twitter-search-run/tg_response.json" \
        "$FIRE_STARTED_AT" "7953915703" 2>/dev/null
    )
    if [ "$RECONCILED" = "1" ]; then
      echo "  wrapper: reconciled fresh Telegram ok:true response into search success state"
    fi
  fi

  FRESH_FAILURE=$(
    "$PYTHON_BIN" "$DELIVERY_STATE_BIN" fresh \
      "$FAILURE_FILE" at "$FIRE_STARTED_AT" 2>/dev/null
  )

  if [ "$STATUS" -eq 124 ]; then
    write_failure "timeout" "Hermes ${SKILL_NAME} exceeded the ${AGENT_TIMEOUT_SECONDS}s wall deadline and was terminated"
  elif [ "$STATUS" -ne 0 ] && [ "$FRESH_FAILURE" != "1" ]; then
    write_failure "agent" "Hermes ${SKILL_NAME} exited $STATUS before completing the workflow"
  fi

  if [ "$STATUS" -eq 0 ] && [ "$DRY_RUN_FLAG" != "--dry-run" ]; then
    FRESH_SUCCESS=$(
      "$PYTHON_BIN" "$DELIVERY_STATE_BIN" fresh \
        "$SUCCESS_FILE" runAt "$FIRE_STARTED_AT" \
        --require-telegram-ok 2>/dev/null
    )
    if [ "$FRESH_SUCCESS" = "1" ]; then
      CLEARED_FAILURE=$(
        "$PYTHON_BIN" "$DELIVERY_STATE_BIN" clear-superseded-failure \
          "$STATE_DIR" "$FIRE_STARTED_AT" 2>/dev/null
      )
      if [ "$CLEARED_FAILURE" = "1" ]; then
        echo "  wrapper: removed a provisional failure superseded by confirmed success"
      fi
    fi
    if [ "$FRESH_SUCCESS" != "1" ]; then
      if [ "$FRESH_FAILURE" = "1" ]; then
        echo "  wrapper: fresh last-failure.json detected despite Hermes exit 0; promoting exit to 70"
      else
        write_failure "agent" "Hermes exited 0 without a fresh Telegram-confirmed last-success record"
        echo "  wrapper: Hermes exit 0 lacked fresh delivery proof; promoting exit to 70"
      fi
      STATUS=70
    fi
  elif [ "$STATUS" -eq 0 ] && [ "$FRESH_FAILURE" = "1" ]; then
      echo "  wrapper: fresh last-failure.json detected despite Hermes exit 0; promoting exit to 70"
      STATUS=70
  fi

  # Post-fire frontmost restore. Only if:
  #   1. Saved PID is non-empty.
  #   2. Saved PID isn't the bot Chrome itself.
  #   3. Bot Chrome is STILL frontmost (user hasn't manually switched).
  if [ -n "$SAVED_FRONTMOST_PID" ] && [ -n "$BOT_CHROME_PID" ] && [ "$SAVED_FRONTMOST_PID" != "$BOT_CHROME_PID" ]; then
    "$WINDOW_BIN" restore "$SAVED_FRONTMOST_PID" "$BOT_CHROME_PID" || true
  fi

  echo "----- exit $STATUS at $(iso_utc_now) -----"
  exit $STATUS
} >> "$LOG" 2>&1
