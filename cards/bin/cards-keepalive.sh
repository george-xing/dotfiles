#!/bin/bash
# cards-keepalive.sh — session-keepalive driver for cards-bot Chrome.
# See cards/docs/superpowers/specs/2026-05-13-cards-session-keepalive-design.md.
#
# One-shot per launchd invocation. No internal loop. Does not log in, does not
# type, does not click, does not retry. Read-only CDP plus bringToFront +
# small scroll per iteration.

set -uo pipefail

# Hardcoded paths — launchd's env is minimal; don't rely on PATH.
export HOME=/Users/pattybot
PYTHON_BIN=/usr/bin/python3
TELEGRAM_HELPER="/Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh"

DAEMON_PORT=19223
STATE_DIR="$HOME/.claude/skills/credit-card-offers/state"
LOCK_FILE="$STATE_DIR/fire-in-progress.lock"
EVENTS_FILE="$STATE_DIR/keepalive-events.jsonl"
COOLDOWN_FILE="$STATE_DIR/auth-notify-cooldown.json"
SCREENSHOT_DIR="$STATE_DIR/screenshots"
LOG_FILE="$HOME/Library/Logs/cards-keepalive.log"

JITTER_MAX_SEC=60
STALE_LOCK_SEC=3600       # 60 min — tertiary fallback against PID reuse;
                          # primary lock-coordination is PID-alive check.
COOLDOWN_SEC=21600        # 6 h
CDP_TIMEOUT_SEC=5

# Tracked-tab table: <issuer> <url-substring>
TRACKED=(
  "amex|americanexpress.com"
  "chase|chase.com"
)

# Telegram destination (matches credit-card-offers SKILL.md).
TELEGRAM_CHAT_ID=7953915703

# ----------------------------------------------------------------------------
# Pure helpers (selftest-covered).
# ----------------------------------------------------------------------------

# cooldown_should_send LAST_ISO NOW_ISO WINDOW_SEC → "yes" | "no"
# LAST_ISO may be empty string; returns "yes" if window elapsed (or never sent).
# ISO timestamps may use either +00:00 or Z suffix (both UTC); both are accepted.
cooldown_should_send() {
  local last="$1" now="$2" window="$3"
  if [[ -z "$last" ]]; then
    echo "yes"
    return
  fi
  "$PYTHON_BIN" - "$last" "$now" "$window" <<'PY'
import sys
from datetime import datetime
last_iso, now_iso, window_s = sys.argv[1], sys.argv[2], int(sys.argv[3])
# Python 3.9's fromisoformat does not accept 'Z' suffix; normalize to +00:00.
last = datetime.fromisoformat(last_iso.replace("Z", "+00:00"))
now = datetime.fromisoformat(now_iso.replace("Z", "+00:00"))
diff = (now - last).total_seconds()
print("yes" if diff >= window_s else "no")
PY
}

# ----------------------------------------------------------------------------
# Selftest harness — runs pure-function assertions and exits.
# Invoked with: KEEPALIVE_SELFTEST=1 ./cards-keepalive.sh
# ----------------------------------------------------------------------------
if [[ "${KEEPALIVE_SELFTEST:-0}" == "1" ]]; then
  selftest_failures=0
  selftest_total=0

  assert_eq() {
    local name="$1" expected="$2" actual="$3"
    selftest_total=$((selftest_total + 1))
    if [[ "$expected" == "$actual" ]]; then
      printf "  ok   %s\n" "$name"
    else
      printf "  FAIL %s — expected=%q actual=%q\n" "$name" "$expected" "$actual" >&2
      selftest_failures=$((selftest_failures + 1))
    fi
  }

  # Placeholder so the harness itself is testable before any real assertions.
  assert_eq "harness sanity" "ok" "ok"

  # cooldown_should_send(last_iso, now_iso, window_sec) → "yes" or "no"
  assert_eq "cooldown: never sent" \
    "yes" "$(cooldown_should_send '' '2026-05-14T12:00:00+00:00' 21600)"
  assert_eq "cooldown: 7h ago" \
    "yes" "$(cooldown_should_send '2026-05-14T05:00:00+00:00' '2026-05-14T12:00:00+00:00' 21600)"
  assert_eq "cooldown: 5h ago" \
    "no" "$(cooldown_should_send '2026-05-14T07:00:00+00:00' '2026-05-14T12:00:00+00:00' 21600)"
  assert_eq "cooldown: exactly 6h-1s ago" \
    "no" "$(cooldown_should_send '2026-05-14T06:00:01+00:00' '2026-05-14T12:00:00+00:00' 21600)"
  assert_eq "cooldown: exactly 6h+1s ago" \
    "yes" "$(cooldown_should_send '2026-05-14T05:59:59+00:00' '2026-05-14T12:00:00+00:00' 21600)"
  assert_eq "cooldown: exactly 6h (Z suffix, boundary inclusive)" \
    "yes" "$(cooldown_should_send '2026-05-14T06:00:00Z' '2026-05-14T12:00:00+00:00' 21600)"

  # Pure-function selftests will be added in subsequent tasks.
  # See: cooldown_should_send (Task 2), state_diff_is_notifiable (Task 3),
  #      lock_is_stale (Task 4).

  printf "\nselftest: %d/%d passed\n" \
    "$((selftest_total - selftest_failures))" "$selftest_total"
  exit $(( selftest_failures > 0 ? 1 : 0 ))
fi

# ----------------------------------------------------------------------------
# Main flow (stubbed until later tasks).
# ----------------------------------------------------------------------------
echo "cards-keepalive: main flow not yet implemented" >&2
exit 0
