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

# state_diff_is_notifiable PREV NEW → "yes" | "no"
# Notifiable kinds: auth-wall, tab-missing, daemon-down — but only when the
# transition is INTO that kind (not staying there). Recovery (→authed) and
# informational kinds (vis-error, dom-error) are silent.
state_diff_is_notifiable() {
  local prev="$1" new="$2"
  if [[ "$prev" == "$new" ]]; then
    echo "no"
    return
  fi
  case "$new" in
    auth-wall|tab-missing|daemon-down) echo "yes" ;;
    *) echo "no" ;;
  esac
}

# lock_is_stale NOW_EPOCH LOCK_MTIME_EPOCH STALE_SEC → "yes" | "no"
# Returns yes when the lock's mtime is older than STALE_SEC ago.
lock_is_stale() {
  local now="$1" mtime="$2" cap="$3"
  if (( now - mtime > cap )); then
    echo "yes"
  else
    echo "no"
  fi
}

# ----------------------------------------------------------------------------
# CDP I/O (impure; smoke-tested via Rung 2 of the validation ladder).
# ----------------------------------------------------------------------------

# discover_tabs → prints "<issuer>|<ws_url>|<page_url>" lines, one per issuer.
# ws_url is empty if no matching tab is found OR if the tab has no
# webSocketDebuggerUrl (rare; service-worker-adjacent tabs). Connection failures
# (refused, timeout) return exit 2 (daemon-down). HTTP errors AND malformed JSON
# both return exit 3 (dom-error — Chrome is reachable but not behaving).
discover_tabs() {
  local raw
  if ! raw=$(curl --max-time "$CDP_TIMEOUT_SEC" -sS "http://127.0.0.1:$DAEMON_PORT/json" 2>/dev/null); then
    return 2
  fi
  "$PYTHON_BIN" - "$raw" <<'PY'
import json, sys
try:
    tabs = json.loads(sys.argv[1])
except json.JSONDecodeError as e:
    print(f"discover_tabs: malformed CDP /json: {e}", file=sys.stderr)
    sys.exit(3)
tracked = [
    ("amex",  "americanexpress.com"),
    ("chase", "chase.com"),
]
page_tabs = [t for t in tabs if t.get("type") == "page"]
for issuer, needle in tracked:
    match = next((t for t in page_tabs if needle in (t.get("url") or "")), None)
    # Defensive: a matched tab without webSocketDebuggerUrl is unusable.
    # Treat as if no tab was found (will emit tab-missing in main flow).
    ws_url = (match.get("webSocketDebuggerUrl") or "") if match else ""
    page_url = (match.get("url") or "") if match else ""
    print(f"{issuer}|{ws_url}|{page_url}")
PY
}

# probe_tab WS_URL → prints JSON {"vis":..,"hasPwInput":..,"url":..,"err":..}
# Runs Page.bringToFront, a tiny randomized scroll, counter-scroll, and a
# probe_js. Returns "err" non-empty if the websocket failed or eval threw.
probe_tab() {
  local ws_url="$1"
  "$PYTHON_BIN" - "$ws_url" <<'PY'
import json, sys, time, random
try:
    import websocket
except ImportError:
    print(json.dumps({"err": "websocket-client missing"}))
    sys.exit(0)

ws_url = sys.argv[1]
try:
    ws = websocket.create_connection(ws_url, suppress_origin=True, timeout=5)
except Exception as e:
    print(json.dumps({"err": f"ws connect: {e}"}))
    sys.exit(0)

_msg_id = [0]
def cdp(method, params=None, timeout=5):
    _msg_id[0] += 1
    mid = _msg_id[0]
    ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            ws.settimeout(max(0.05, deadline - time.time()))
            r = json.loads(ws.recv())
        except Exception as e:
            return {"error": {"message": f"recv: {e}"}}
        if r.get("id") == mid:
            return r
    return {"error": {"message": "timeout"}}

def evaluate(js):
    r = cdp("Runtime.evaluate", {"expression": js, "returnByValue": True, "awaitPromise": True})
    if "error" in r:
        return None, r["error"]
    res = r.get("result", {}).get("result", {})
    if res.get("subtype") == "error":
        return None, {"message": res.get("description", "js error")}
    return res.get("value"), None

# Step 1: bring to front (real OS-level activation, not Page.setWebLifecycleState).
cdp("Page.bringToFront")

# Step 2: small forward scroll (1-3 px randomized).
scroll_px = 1 + random.randint(0, 2)
_, err = evaluate(f"window.scrollBy(0, {scroll_px});")
if err:
    print(json.dumps({"err": f"scrollBy fwd: {err.get('message')}"}))
    ws.close()
    sys.exit(0)

time.sleep(0.25)

# Step 3: counter-scroll to prevent visual drift over time.
evaluate("window.scrollBy(0, -2);")

# Step 4: probe.
probe_js = """
(() => ({
  vis: document.visibilityState,
  hasPwInput: !!document.querySelector('input[type="password"]'),
  url: location.href
}))()
"""
val, err = evaluate(probe_js)
ws.close()
if err:
    print(json.dumps({"err": f"probe eval: {err.get('message')}"}))
    sys.exit(0)
val["err"] = ""
print(json.dumps(val))
PY
}

# probe_tab_to_state PROBE_JSON → emits one of: authed, auth-wall, vis-error, dom-error
probe_tab_to_state() {
  local probe="$1"
  "$PYTHON_BIN" - "$probe" <<'PY'
import json, sys
p = json.loads(sys.argv[1])
if p.get("err"):
    print("dom-error")
    sys.exit(0)
if p.get("hasPwInput"):
    print("auth-wall")
    sys.exit(0)
if p.get("vis") != "visible":
    print("vis-error")
    sys.exit(0)
print("authed")
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

  # state_diff_is_notifiable(prev, new) → "yes" or "no"
  assert_eq "diff: unknown→authed (first obs)" \
    "no" "$(state_diff_is_notifiable unknown authed)"
  assert_eq "diff: unknown→auth-wall" \
    "yes" "$(state_diff_is_notifiable unknown auth-wall)"
  assert_eq "diff: unknown→tab-missing" \
    "yes" "$(state_diff_is_notifiable unknown tab-missing)"
  assert_eq "diff: unknown→daemon-down" \
    "yes" "$(state_diff_is_notifiable unknown daemon-down)"
  assert_eq "diff: authed→auth-wall" \
    "yes" "$(state_diff_is_notifiable authed auth-wall)"
  assert_eq "diff: auth-wall→authed (recovery silent)" \
    "no" "$(state_diff_is_notifiable auth-wall authed)"
  assert_eq "diff: auth-wall→auth-wall (no-op)" \
    "no" "$(state_diff_is_notifiable auth-wall auth-wall)"
  assert_eq "diff: authed→vis-error (informational)" \
    "no" "$(state_diff_is_notifiable authed vis-error)"
  assert_eq "diff: authed→dom-error" \
    "no" "$(state_diff_is_notifiable authed dom-error)"

  # lock_is_stale(now_epoch, lock_mtime_epoch, stale_sec) → "yes" or "no"
  # (Tested at the 60-min boundary that matches STALE_LOCK_SEC in production.)
  assert_eq "lock: 0s old" \
    "no" "$(lock_is_stale 1700000000 1700000000 3600)"
  assert_eq "lock: 59:59 old (just under cap)" \
    "no" "$(lock_is_stale 1700003599 1700000000 3600)"
  assert_eq "lock: 60:01 old (just over cap)" \
    "yes" "$(lock_is_stale 1700003601 1700000000 3600)"
  assert_eq "lock: 7d old" \
    "yes" "$(lock_is_stale 1700604800 1700000000 3600)"

  # probe_tab_to_state(probe_json) → state
  # Precedence: err > hasPwInput > vis-error > authed.
  assert_eq "probe: authed" \
    "authed" "$(probe_tab_to_state '{"vis":"visible","hasPwInput":false,"url":"x","err":""}')"
  assert_eq "probe: auth-wall (pw input)" \
    "auth-wall" "$(probe_tab_to_state '{"vis":"visible","hasPwInput":true,"url":"x","err":""}')"
  assert_eq "probe: vis-error (hidden)" \
    "vis-error" "$(probe_tab_to_state '{"vis":"hidden","hasPwInput":false,"url":"x","err":""}')"
  assert_eq "probe: dom-error (ws failed)" \
    "dom-error" "$(probe_tab_to_state '{"err":"ws connect: refused"}')"
  assert_eq "probe: err wins over hasPwInput" \
    "dom-error" "$(probe_tab_to_state '{"vis":"visible","hasPwInput":true,"url":"x","err":"eval failed"}')"
  assert_eq "probe: pw input wins over vis-error" \
    "auth-wall" "$(probe_tab_to_state '{"vis":"hidden","hasPwInput":true,"url":"x","err":""}')"

  printf "\nselftest: %d/%d passed\n" \
    "$((selftest_total - selftest_failures))" "$selftest_total"
  exit $(( selftest_failures > 0 ? 1 : 0 ))
fi

# ----------------------------------------------------------------------------
# Main flow (stubbed until later tasks).
# ----------------------------------------------------------------------------
echo "cards-keepalive: main flow not yet implemented" >&2
exit 0
