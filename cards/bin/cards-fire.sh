#!/bin/bash
# Retired after migration to Hermes on 2026-09-20.
printf '%s\n' "Retired: cards now run through Hermes. Use hermes cron list and the credit-card-offers skill; do not provision a separate Keychain token." >&2
exit 64

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

perform_logout() {
  LOGOUT_OUT=""
  LOGOUT_STATUS=0
  if [[ "$DRY_RUN_FLAG" == "--dry-run" ]]; then
    return 0
  fi
  LOGOUT_OUT=$("$AUTH_BIN" logout 2>&1)
  LOGOUT_STATUS=$?
  echo "  logout: $LOGOUT_OUT"
  return 0
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
  FIRE_STARTED_AT=$(iso_utc_now)
  echo "===== fire $FIRE_STARTED_AT skill=${SKILL_NAME} ====="

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
  AUTH_READY_COUNT=$(printf '%s' "$AUTH_OUT" | "$PYTHON_BIN" -c 'import json,sys
try:
    results=json.load(sys.stdin).get("results", [])
    print(sum(x.get("status") in ("authenticated","already_authenticated","authenticated_totp") for x in results))
except Exception:
    print(0)' 2>/dev/null || echo 0)
  AUTH_AVAILABLE_ISSUERS=$(printf '%s' "$AUTH_OUT" | "$PYTHON_BIN" -c 'import json,sys
try:
    results=json.load(sys.stdin).get("results", [])
    print(",".join(x.get("issuer","") for x in results if x.get("status") in ("authenticated","already_authenticated","authenticated_totp")))
except Exception:
    print("")' 2>/dev/null || true)
  AUTH_FAILURES_JSON=$(printf '%s' "$AUTH_OUT" | "$PYTHON_BIN" -c 'import json,sys
try:
    data=json.load(sys.stdin)
    failures=[{"issuer":x.get("issuer","issuer"),"kind":x.get("kind","auth"),"message":x.get("message","authentication failed")} for x in data.get("results",[]) if x.get("status") in ("error","login_required")]
    print(json.dumps(failures))
except Exception:
    print("[]")' 2>/dev/null || echo '[]')
  AUTH_CONTEXT=$(printf '%s' "$AUTH_OUT" | "$PYTHON_BIN" -c 'import json,sys
try:
    results=json.load(sys.stdin).get("results", [])
    parts=[]
    for result in results:
        issuer=result.get("issuer","issuer")
        status=result.get("status","unknown")
        if status in ("authenticated","already_authenticated","authenticated_totp"):
            parts.append(f"{issuer}=available")
        else:
            parts.append("{}=unavailable(kind:{})".format(issuer,result.get("kind","auth")))
    print(", ".join(parts) or "no issuer results")
except Exception:
    print("no issuer results")' 2>/dev/null || echo "no issuer results")

  if [[ "$AUTH_STATUS" != "0" && "$AUTH_READY_COUNT" -eq 0 ]]; then
    AUTH_SUMMARY=$(printf '%s' "$AUTH_OUT" | "$PYTHON_BIN" -c 'import json,sys
try:
    data=json.load(sys.stdin)
    failures=[]
    for result in data.get("results", []):
        if result.get("status") == "error":
            issuer=result.get("issuer", "issuer")
            kind=result.get("kind", "auth")
            message=result.get("message", "authentication failed")
            failures.append(f"{issuer} kind:{kind} — {message}")
    print("; ".join(failures) or data.get("message", "secure bank login failed"))
except Exception:
    print("secure bank login failed")' 2>/dev/null || echo "secure bank login failed")
    AUTH_KIND=$(printf '%s' "$AUTH_OUT" | "$PYTHON_BIN" -c 'import json,sys
try:
    data=json.load(sys.stdin)
    failures=[x for x in data.get("results",[]) if x.get("status") in ("error","login_required")]
    print((failures[0].get("kind") if failures else data.get("kind")) or "auth")
except Exception: print("auth")' 2>/dev/null || echo auth)
    case "$AUTH_KIND" in
      config|onepassword|browser|auth|mfa|challenge|dom) ;;
      *) AUTH_KIND="auth" ;;
    esac
    write_failure "$AUTH_KIND" "$AUTH_SUMMARY"
    if [[ "$DRY_RUN_FLAG" != "--dry-run" ]]; then
      send_operator_notice "💳 Card offers paused: $AUTH_SUMMARY. No credential submission was retried."
    fi
    perform_logout
    echo "----- exit $AUTH_STATUS (authentication failed) at $(iso_utc_now) -----"
    exit "$AUTH_STATUS"
  fi
  if [[ "$AUTH_STATUS" != "0" ]]; then
    echo "  auth: partial availability ($AUTH_CONTEXT); continuing with authenticated issuer(s)"
  fi

  # Post-login offer handling stays agentic because both bank UIs drift.
  # Codex auth is verified to work from the launchd GUI domain; the agent
  # never receives bank credentials and is constrained by the skill rules to
  # the already-authenticated CDP tabs and offer-activation controls.
  CODEX_PROMPT="Read /Users/pattybot/dotfiles/cards/.claude/skills/credit-card-offers/SKILL.md completely, then execute that skill now. Authentication boundary: $AUTH_CONTEXT. Process only issuers marked available; do not navigate, probe, or submit credentials for unavailable issuers. Treat unavailable issuers as authentication failures in the partial report. Follow every hard rule, persist accurate partial progress, and send the Telegram report. Do not perform login or read 1Password."
  if [[ "$DRY_RUN_FLAG" == "--dry-run" ]]; then
    CODEX_PROMPT="$CODEX_PROMPT Run in dry-run mode: do not click, send Telegram, or write state."
  fi
  cd "/Users/pattybot/dotfiles/cards"
  AGENT_OUT=$(mktemp /tmp/cards-agent-output.XXXXXX)
  </dev/null "$SANDBOX_EXEC" -f "$AGENT_SANDBOX" "$CODEX_BIN" exec --ephemeral --skip-git-repo-check \
    -C "/Users/pattybot/dotfiles/cards" \
    -m gpt-5.6-luna -c 'model_reasoning_effort="low"' \
    -s danger-full-access -c 'approval_policy="never"' \
    "$CODEX_PROMPT" 2>&1 | tee "$AGENT_OUT"
  STATUS=${PIPESTATUS[0]}

  # Model credits/auth are not allowed to make the bank job unavailable.
  # This fallback uses the same live-state transitions the agentic runbook
  # validated, and only runs for a model-service failure.
  if [[ "$STATUS" != "0" ]] && grep -Eqi 'usage limit|purchase more credits|401 Invalid authentication credentials|Selected model is at capacity' "$AGENT_OUT"; then
    echo "  agent unavailable before completion; running validated browser fallback"
    if [[ "$DRY_RUN_FLAG" == "--dry-run" ]]; then
      CARDS_AVAILABLE_ISSUERS="$AUTH_AVAILABLE_ISSUERS" \
      CARDS_AUTH_FAILURES_JSON="$AUTH_FAILURES_JSON" \
        "$OFFERS_BIN" --dry-run
    else
      CARDS_AVAILABLE_ISSUERS="$AUTH_AVAILABLE_ISSUERS" \
      CARDS_AUTH_FAILURES_JSON="$AUTH_FAILURES_JSON" \
        "$OFFERS_BIN"
    fi
    STATUS=$?
  fi
  rm -f "$AGENT_OUT"

  # A successful model/process exit is not sufficient evidence that the live
  # bank workflow succeeded. The offer agent may have delivered a failure
  # digest successfully and accidentally propagated Telegram's zero exit code
  # (as happened on 2026-07-15). Require this fire to have atomically advanced
  # last-success.json with successful Telegram delivery before launchd sees 0.
  if [[ "$DRY_RUN_FLAG" != "--dry-run" && "$STATUS" == "0" ]]; then
    LAST_SUCCESS="$HOME/.claude/skills/$SKILL_NAME/state/last-success.json"
    STATE_CHECK=$(
      "$PYTHON_BIN" - "$FIRE_STARTED_AT" "$LAST_SUCCESS" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

started_raw, path = sys.argv[1:]
try:
    started = datetime.fromisoformat(started_raw.replace("Z", "+00:00"))
    state = json.load(open(path))
    completed = datetime.fromisoformat(str(state["runAt"]).replace("Z", "+00:00"))
    if completed >= started and state.get("telegramOk") is True:
        # Success is authoritative now; a pending marker from this or an older
        # interrupted fire is stale and must not survive terminal validation.
        try:
            Path(path).with_name("pending.json").unlink()
        except FileNotFoundError:
            pass
        print("ok")
        raise SystemExit(0)
    print("last-success is stale or Telegram was not confirmed")
except Exception as exc:
    print(f"no valid current success state: {type(exc).__name__}")
raise SystemExit(1)
PY
    )
    STATE_CHECK_STATUS=$?
    if [[ "$STATE_CHECK_STATUS" != "0" ]]; then
      echo "  terminal-state validation failed: $STATE_CHECK"
      STATUS=4
      # Preserve a richer issuer failure written by the agent. Only synthesize
      # state failure metadata when no failure record exists at all.
      if [[ ! -f "$HOME/.claude/skills/$SKILL_NAME/state/last-failure.json" ]]; then
        write_failure "state" "agent exited zero without current successful terminal state"
      fi
    fi
  fi

  # Always attempt explicit bank sign-out after a live run, including when
  # the offer agent fails. This cleanup never reads 1Password.
  if [[ "$DRY_RUN_FLAG" != "--dry-run" ]]; then
    perform_logout
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
