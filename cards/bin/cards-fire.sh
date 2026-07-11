#!/bin/bash
# cards-fire.sh — orchestrator for a single fire of one cards skill.
#
# Usage:
#   cards-fire.sh <skill-name>            # live fire
#   cards-fire.sh <skill-name> --dry-run  # dry-run mode
#
# Direct mirror of twitter-fire.sh with cards-package paths. Steps:
#   1. Validate <skill-name> exists at ~/.claude/skills/<name>/SKILL.md.
#   2. Acquire shared lock at ~/.claude/skills/.cards-fire.lock via shlock(1).
#      Exit 3 (kind:busy) if another cards-fire is currently holding it.
#   3. Call cards-prefire.sh, capture stdout.
#   4. Parse SAVED_FRONTMOST_PID and BOT_CHROME_PID from prefire output.
#   5. Invoke Codex non-interactively to execute the browser-aware skill.
#   6. Post-fire frontmost restore (only if bot Chrome still frontmost).
#   7. Release lock; exit with claude's exit code.
#
# All non-zero exits write a kind-tagged ~/.claude/skills/<skill>/state/
# last-failure.json so a dispatch layer can relay failure to Telegram.
# Timestamps are UTC ISO-8601 for lexicographic comparability across
# timezones and producers.
#
# Note on lock scope: this lock is package-local (.cards-fire.lock), NOT
# shared with twitter-fire. Cards and twitter schedules don't overlap
# (cards 03:00 PT, twitter 08:00 + 22:00 local) — and bank automation
# should never race with anything else for foreground in the first place.

set -uo pipefail

export HOME="/Users/pattybot"
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/Users/pattybot/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

AUTH_BIN="$(dirname "$(realpath "$0")")/cards-auth.py"
CODEX_BIN="/Users/pattybot/.npm-global/bin/codex"
OFFERS_BIN="$(dirname "$(realpath "$0")")/cards-offers.py"
SANDBOX_EXEC="/usr/bin/sandbox-exec"
AGENT_SANDBOX="/Users/pattybot/dotfiles/cards/config/cards-agent.sb"
OP_BIN="/Users/pattybot/.local/bin/op"
SHLOCK_BIN="/usr/bin/shlock"
PYTHON_BIN="/usr/bin/python3"
PREFIRE_BIN="$(dirname "$(realpath "$0")")/cards-prefire.sh"
LOCK_FILE="$HOME/.claude/skills/.cards-fire.lock"

LOG="$HOME/Library/Logs/cards-fire.log"
mkdir -p "$(dirname "$LOG")"

SKILL_NAME="${1:-}"
DRY_RUN_FLAG="${2:-}"

iso_utc_now() {
  "$PYTHON_BIN" -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())"
}

write_failure() {
  local kind="$1"
  local message="$2"
  local skill="${3:-$SKILL_NAME}"
  [ -z "$skill" ] && return 0
  local state_dir="$HOME/.claude/skills/${skill}/state"
  mkdir -p "$state_dir" 2>/dev/null || return 0
  local at
  at=$(iso_utc_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S+00:00)
  local esc_msg
  esc_msg=$(printf '%s' "$message" | "$PYTHON_BIN" -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$message")
  printf '{"kind":"%s","at":"%s","message":%s}\n' "$kind" "$at" "$esc_msg" \
    > "${state_dir}/last-failure.json" 2>/dev/null || true
}

send_operator_notice() {
  local plain="$1"
  local helper="/Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh"
  [ -x "$helper" ] || return 0
  local run_dir="/tmp/credit-card-offers-notice.$$"
  mkdir -p "$run_dir" || return 0
  chmod 700 "$run_dir" 2>/dev/null || true
  printf '%s' "$plain" > "$run_dir/message.txt"
  TELEGRAM_CHAT_ID=7953915703 \
  TELEGRAM_MESSAGE_FILE="$run_dir/message.txt" \
  TELEGRAM_MESSAGE_PLAIN_FILE="$run_dir/message.txt" \
  RUN_DIR="$run_dir" "$helper" >/dev/null 2>&1 || true
  rm -rf "$run_dir"
}

if [ -z "$SKILL_NAME" ]; then
  echo "usage: cards-fire.sh <skill-name> [--dry-run]" >&2
  exit 64
fi

SKILL_PATH="$HOME/.claude/skills/${SKILL_NAME}/SKILL.md"
if [ ! -f "$SKILL_PATH" ]; then
  echo "ERROR: skill not found at $SKILL_PATH" >&2
  write_failure "config" "skill not found at $SKILL_PATH"
  exit 65
fi

for bin in "$AUTH_BIN" "$CODEX_BIN" "$OFFERS_BIN" "$OP_BIN" "$SHLOCK_BIN" "$PYTHON_BIN" "$PREFIRE_BIN" "$SANDBOX_EXEC"; do
  if [ ! -x "$bin" ]; then
    echo "ERROR: missing binary $bin — reinstall or update wrapper paths" >&2
    write_failure "config" "missing binary $bin"
    exit 127
  fi
done
if [ ! -r "$AGENT_SANDBOX" ]; then
  echo "ERROR: missing agent sandbox profile $AGENT_SANDBOX" >&2
  write_failure "config" "missing agent sandbox profile"
  exit 127
fi

mkdir -p "$(dirname "$LOCK_FILE")"

# Acquire lock via shlock(1) — macOS-native PID-file locking with built-in
# stale-PID detection. If lock is held by a live process, exits non-zero.
# If lock file exists but holder is dead, shlock cleans it and acquires.
if ! "$SHLOCK_BIN" -p $$ -f "$LOCK_FILE"; then
  HOLDER_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "?")
  write_failure "busy" "another cards-fire in progress (PID $HOLDER_PID)"
  {
    echo "===== fire $(iso_utc_now) skill=${SKILL_NAME} BUSY ====="
    echo "  another cards-fire is holding the lock; holder PID=$HOLDER_PID"
    echo "----- exit 3 at $(iso_utc_now) -----"
  } >> "$LOG"
  exit 3
fi

# fire-in-progress sentinel: tells cards-keepalive.sh to skip iterations
# while we own the bot Chrome. PID-aware (first whitespace-delimited token).
FIRE_IN_PROGRESS_LOCK="$HOME/.claude/skills/credit-card-offers/state/fire-in-progress.lock"
mkdir -p "$(dirname "$FIRE_IN_PROGRESS_LOCK")"
# Atomic write: tmp + rename avoids a window where the lock file exists
# but is mid-truncate/mid-write (keepalive's PID parse would see empty).
echo "$$ $(date -u +%FT%TZ)" > "$FIRE_IN_PROGRESS_LOCK.tmp.$$" && \
  mv "$FIRE_IN_PROGRESS_LOCK.tmp.$$" "$FIRE_IN_PROGRESS_LOCK"

# Single combined trap — cleans BOTH locks on any exit path.
trap 'rm -f "$LOCK_FILE" "$FIRE_IN_PROGRESS_LOCK"' EXIT INT TERM

{
  echo "===== fire $(iso_utc_now) skill=${SKILL_NAME} ====="

  PREFIRE_OUT=$("$PREFIRE_BIN" 2>&1)
  PREFIRE_EXIT=$?
  echo "$PREFIRE_OUT"
  if [ "$PREFIRE_EXIT" -ne 0 ]; then
    write_failure "prefire" "cards-prefire.sh exited $PREFIRE_EXIT (see ~/Library/Logs/cards-fire.log)"
    echo "----- exit $PREFIRE_EXIT (prefire failed) at $(iso_utc_now) -----"
    exit $PREFIRE_EXIT
  fi

  SAVED_FRONTMOST_PID=$(echo "$PREFIRE_OUT" | grep '^SAVED_FRONTMOST_PID=' | tail -1 | cut -d= -f2)
  BOT_CHROME_PID=$(echo "$PREFIRE_OUT" | grep -oE 'activating bot Chrome PID=[0-9]+' | head -1 | cut -d= -f2)

  # Authenticate before handing the already-logged-in pages to the agentic
  # offer workflow. cards-auth.py emits metadata only; never secret values.
  if [[ "$DRY_RUN_FLAG" == "--dry-run" ]]; then
    AUTH_OUT=$("$AUTH_BIN" login --dry-run 2>&1)
  else
    AUTH_OUT=$("$AUTH_BIN" login 2>&1)
  fi
  AUTH_STATUS=$?
  echo "  auth: $AUTH_OUT"
  if [[ "$AUTH_STATUS" != "0" ]]; then
    AUTH_KIND=$(printf '%s' "$AUTH_OUT" | "$PYTHON_BIN" -c 'import json,sys
try: print(json.load(sys.stdin).get("kind", "auth"))
except Exception: print("auth")' 2>/dev/null || echo auth)
    case "$AUTH_KIND" in
      config|onepassword|browser|auth|mfa|challenge|dom) ;;
      *) AUTH_KIND="auth" ;;
    esac
    write_failure "$AUTH_KIND" "secure 1Password login failed (see cards-fire.log)"
    if [[ "$DRY_RUN_FLAG" != "--dry-run" ]]; then
      send_operator_notice "💳 Card offers paused: secure bank login failed. Check the Mac mini cards-fire log; manual MFA or 1Password setup may be required. No credential submission was retried."
    fi
    echo "----- exit $AUTH_STATUS (authentication failed) at $(iso_utc_now) -----"
    exit "$AUTH_STATUS"
  fi

  # Post-login offer handling stays agentic because both bank UIs drift.
  # Codex auth is verified to work from the launchd GUI domain; the agent
  # never receives bank credentials and is constrained by the skill rules to
  # the already-authenticated CDP tabs and offer-activation controls.
  CODEX_PROMPT="Read /Users/pattybot/dotfiles/cards/.claude/skills/credit-card-offers/SKILL.md completely, then execute that skill now. Authentication has already completed. Follow every hard rule, process both Chase and Amex, persist accurate partial progress, and send the Telegram report. Do not perform login or read 1Password."
  if [[ "$DRY_RUN_FLAG" == "--dry-run" ]]; then
    CODEX_PROMPT="$CODEX_PROMPT Run in dry-run mode: do not click, send Telegram, or write state."
  fi
  cd "/Users/pattybot/dotfiles/cards"
  AGENT_OUT=$(mktemp /tmp/cards-agent-output.XXXXXX)
  </dev/null "$SANDBOX_EXEC" -f "$AGENT_SANDBOX" "$CODEX_BIN" exec --ephemeral --skip-git-repo-check \
    -C "/Users/pattybot/dotfiles/cards" \
    -m gpt-5.4 \
    -s danger-full-access -c 'approval_policy="never"' \
    "$CODEX_PROMPT" 2>&1 | tee "$AGENT_OUT"
  STATUS=${PIPESTATUS[0]}

  # Model credits/auth are not allowed to make the bank job unavailable.
  # This fallback uses the same live-state transitions the agentic runbook
  # validated, and only runs for a model-service failure.
  if [[ "$STATUS" != "0" ]] && grep -Eqi 'usage limit|purchase more credits|401 Invalid authentication credentials|Selected model is at capacity' "$AGENT_OUT"; then
    echo "  agent unavailable before completion; running validated browser fallback"
    if [[ "$DRY_RUN_FLAG" == "--dry-run" ]]; then
      "$OFFERS_BIN" --dry-run
    else
      "$OFFERS_BIN"
    fi
    STATUS=$?
  fi
  rm -f "$AGENT_OUT"

  # Always attempt explicit bank sign-out after a live run, including when
  # the offer agent fails. This cleanup never reads 1Password.
  if [[ "$DRY_RUN_FLAG" != "--dry-run" ]]; then
    LOGOUT_OUT=$("$AUTH_BIN" logout 2>&1)
    LOGOUT_STATUS=$?
    echo "  logout: $LOGOUT_OUT"
    if [[ "$LOGOUT_STATUS" != "0" && "$STATUS" == "0" ]]; then
      STATUS=$LOGOUT_STATUS
      write_failure "logout" "offer run completed but explicit sign-out failed"
      send_operator_notice "⚠️ Card offers completed, but one or more bank sign-outs could not be verified. Check the Mac mini cards-fire log and sign out manually."
    fi
  fi

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
