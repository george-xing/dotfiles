# Cards Session Keepalive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `com.pattybot.cards-keepalive` launchd job that injects minimal CDP activity every ~5 min on the cards-bot Chrome's Amex/Chase tabs, observes session state, and Telegrams the operator on auth-wall transitions — extending session lifetime beyond the ~30-min idle timeout.

**Architecture:** One bash script (`bin/cards-keepalive.sh`) with embedded `/usr/bin/python3` for websocket-client; one launchd plist with `StartInterval=300`; three small additive changes to `bin/cards-fire.sh` (lock write, trap-cleanup, park-on-offers). State persistence via append-only `state/keepalive-events.jsonl` and atomic-write `state/auth-notify-cooldown.json`. Strict single-writer file ownership keeps keepalive and fire concerns independent.

**Tech Stack:** bash, `/usr/bin/python3` with `websocket-client`, macOS launchd plists, CDP via local HTTP+WebSocket, `dotfiles/twitter/bin/lib/telegram-send.sh` (existing helper, no changes).

**Spec:** `cards/docs/superpowers/specs/2026-05-13-cards-session-keepalive-design.md` (must be read alongside this plan; this plan implements that spec without re-deriving its decisions).

---

## File Structure

**New:**
| Path | Responsibility | Approx LOC |
|---|---|---|
| `cards/bin/cards-keepalive.sh` | One-shot keepalive iteration. Lock check → CDP probe → state diff → Telegram. Inline `KEEPALIVE_SELFTEST=1` for pure-function assertions. | ~180 |
| `cards/Library/LaunchAgents/com.pattybot.cards-keepalive.plist` | launchd job: `StartInterval=300`, `RunAtLoad=true`, `ProcessType=Interactive`. | ~30 |

**Modified:**
| Path | Changes |
|---|---|
| `cards/bin/cards-fire.sh` | Three additive changes: write `fire-in-progress.lock` at start; trap-cleanup on EXIT/INT/TERM; park Amex+Chase tabs on offers URLs after fire body. |
| `cards/CLAUDE.md` | Rename "Two-job architecture" → "Three-job architecture"; add cards-keepalive row to symlink table; add keepalive control commands to "Common commands". |
| `cards/.claude/skills/credit-card-offers/SKILL.md` | Cross-reference keepalive's bounded action set in "what NOT to do" list; add brief "session-keepalive is a separate launchd job; do not invoke it inline" note. |
| `cards/.claude/skills/credit-card-offers/references/runbook.md` | Add "session died — recovery procedure" section: VNC in, re-login, expect keepalive to record `auth-wall → authed` on next iteration. Add `keepalive-events.jsonl` to forensic-files list. |

**Runtime-created (gitignored, not committed):**
- `state/keepalive-events.jsonl`
- `state/auth-notify-cooldown.json`
- `state/fire-in-progress.lock`
- `state/screenshots/keepalive-*.png`
- `~/Library/Logs/cards-keepalive.{out,err}.log`

**Already committed in spec-pass (skip):**
- `cards/.stow-local-ignore` — `^/docs/` exclusion (already in `e764d0d`).

---

## Order rationale

Pure-function helpers first (TDD-friendly). Then I/O wiring (CDP, Telegram, screenshots — manual smoke tests). Then orchestration (lock + jitter at script entry). Then fire-side coordination (lock-write + trap + park). Then plist + bootstrap. Documentation + validation last.

This order means **the keepalive script becomes runnable in `KEEPALIVE_SELFTEST=1` mode after Task 4**, runnable as a live one-shot after Task 8, and fully wired into launchd after Task 11.

---

## Task 1: Scaffold `cards-keepalive.sh` with config block + selftest harness

**Files:**
- Create: `cards/bin/cards-keepalive.sh`

- [ ] **Step 1: Create the script with hardcoded paths + selftest harness**

Write the following to `cards/bin/cards-keepalive.sh`:

```bash
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
STALE_LOCK_SEC=1800       # 30 min
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
```

- [ ] **Step 2: Make executable**

Run:
```bash
chmod +x cards/bin/cards-keepalive.sh
```

- [ ] **Step 3: Verify bash syntax**

Run:
```bash
bash -n cards/bin/cards-keepalive.sh
```
Expected: silent exit 0.

- [ ] **Step 4: Run the selftest harness — verify it passes**

Run:
```bash
KEEPALIVE_SELFTEST=1 cards/bin/cards-keepalive.sh
```
Expected output:
```
  ok   harness sanity

selftest: 1/1 passed
```
Exit code 0.

- [ ] **Step 5: Commit**

```bash
git add cards/bin/cards-keepalive.sh
git commit -m "cards-keepalive: scaffold script with selftest harness

Hardcoded paths (launchd has minimal PATH), config constants, and an
assert_eq selftest harness gated by KEEPALIVE_SELFTEST=1. Main flow is
a stub; pure-function helpers and CDP wiring land in subsequent commits.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Implement and test `cooldown_should_send`

**Files:**
- Modify: `cards/bin/cards-keepalive.sh` (add helper function + selftest assertions)

The cooldown gate: given a "last sent" ISO timestamp (or empty/null) and an interval-seconds value, decide whether enough time has passed to send a new Telegram.

- [ ] **Step 1: Add the failing selftest assertions**

In `cards/bin/cards-keepalive.sh`, find the comment block "Pure-function selftests will be added in subsequent tasks." and insert these assertions immediately above it (and below the `assert_eq "harness sanity"` line):

```bash
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
```

- [ ] **Step 2: Run selftest — verify it fails with "command not found"**

Run:
```bash
KEEPALIVE_SELFTEST=1 cards/bin/cards-keepalive.sh
```
Expected: 5 FAIL lines mentioning `cooldown_should_send: command not found`. Exit code 1.

- [ ] **Step 3: Implement `cooldown_should_send`**

In `cards/bin/cards-keepalive.sh`, immediately above the selftest harness block (just below the `# Telegram destination` line), add:

```bash
# ----------------------------------------------------------------------------
# Pure helpers (selftest-covered).
# ----------------------------------------------------------------------------

# cooldown_should_send LAST_ISO NOW_ISO WINDOW_SEC → "yes" | "no"
# LAST_ISO may be empty string; returns "yes" if window elapsed (or never sent).
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
last = datetime.fromisoformat(last_iso)
now = datetime.fromisoformat(now_iso)
diff = (now - last).total_seconds()
print("yes" if diff >= window_s else "no")
PY
}
```

- [ ] **Step 4: Run selftest — verify it passes**

Run:
```bash
KEEPALIVE_SELFTEST=1 cards/bin/cards-keepalive.sh
```
Expected: 6 `ok` lines, `selftest: 6/6 passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add cards/bin/cards-keepalive.sh
git commit -m "cards-keepalive: add cooldown_should_send helper

Pure function gated by KEEPALIVE_SELFTEST=1 assertions. Treats empty last-sent
as immediate yes (never-sent case). Boundary tests cover ±1s of the 6h window.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Implement and test `state_diff_is_notifiable`

**Files:**
- Modify: `cards/bin/cards-keepalive.sh` (add helper + selftest assertions)

State diff: given a prev state and a new state, decide whether the transition is notifiable (worth sending a Telegram, subject to cooldown). Notifiable kinds: `auth-wall`, `tab-missing`, `daemon-down`. Non-notifiable: same-state, `vis-error`, `dom-error`, `*→authed` (recovery is silent), `unknown→authed` (first-observation).

- [ ] **Step 1: Add the failing selftest assertions**

In `cards/bin/cards-keepalive.sh`, append these assertions to the selftest block (after the cooldown assertions):

```bash
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
```

- [ ] **Step 2: Run selftest — verify failure**

Run:
```bash
KEEPALIVE_SELFTEST=1 cards/bin/cards-keepalive.sh
```
Expected: 9 FAIL lines for `state_diff_is_notifiable: command not found`.

- [ ] **Step 3: Implement `state_diff_is_notifiable`**

In the "Pure helpers" block in `cards/bin/cards-keepalive.sh`, add (below `cooldown_should_send`):

```bash
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
```

- [ ] **Step 4: Run selftest — verify all pass**

Run:
```bash
KEEPALIVE_SELFTEST=1 cards/bin/cards-keepalive.sh
```
Expected: 15/15 passed.

- [ ] **Step 5: Commit**

```bash
git add cards/bin/cards-keepalive.sh
git commit -m "cards-keepalive: add state_diff_is_notifiable helper

Encodes the per-OD8 transition table: only INTO auth-wall, tab-missing, or
daemon-down notifies. Recovery (→authed) and informational kinds (vis-error,
dom-error) are silent. Same-state is no-op.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Implement and test `lock_is_stale`

**Files:**
- Modify: `cards/bin/cards-keepalive.sh`

- [ ] **Step 1: Add the failing selftest assertions**

In `cards/bin/cards-keepalive.sh`, append to the selftest block:

```bash
  # lock_is_stale(now_epoch, lock_mtime_epoch, stale_sec) → "yes" or "no"
  assert_eq "lock: 0s old" \
    "no" "$(lock_is_stale 1700000000 1700000000 1800)"
  assert_eq "lock: 29:59 old (just under cap)" \
    "no" "$(lock_is_stale 1700001799 1700000000 1800)"
  assert_eq "lock: 30:01 old (just over cap)" \
    "yes" "$(lock_is_stale 1700001801 1700000000 1800)"
  assert_eq "lock: 7d old" \
    "yes" "$(lock_is_stale 1700604800 1700000000 1800)"
```

- [ ] **Step 2: Run selftest — verify failure**

Run:
```bash
KEEPALIVE_SELFTEST=1 cards/bin/cards-keepalive.sh
```
Expected: 4 FAIL lines for `lock_is_stale: command not found`.

- [ ] **Step 3: Implement `lock_is_stale`**

Add below `state_diff_is_notifiable` in the "Pure helpers" block:

```bash
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
```

- [ ] **Step 4: Run selftest — verify all pass**

Run:
```bash
KEEPALIVE_SELFTEST=1 cards/bin/cards-keepalive.sh
```
Expected: 19/19 passed.

- [ ] **Step 5: Commit**

```bash
git add cards/bin/cards-keepalive.sh
git commit -m "cards-keepalive: add lock_is_stale helper

Pure bash arithmetic over epoch timestamps. Boundary tests cover ±1s of the
30-minute stale-lock cap (OD6).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Implement CDP tab discovery (find tracked tabs by URL substring)

**Files:**
- Modify: `cards/bin/cards-keepalive.sh`

Discovery is impure (talks to a local HTTP socket), so it's smoke-tested rather than selftest-asserted. The function `discover_tabs` should print to stdout one line per tracked issuer: `<issuer>|<webSocketDebuggerUrl-or-empty>|<url>`.

- [ ] **Step 1: Implement `discover_tabs`**

In `cards/bin/cards-keepalive.sh`, add after the "Pure helpers" block (and above the selftest harness):

```bash
# ----------------------------------------------------------------------------
# CDP I/O (impure; smoke-tested via Rung 2 of the validation ladder).
# ----------------------------------------------------------------------------

# discover_tabs → prints "<issuer>|<ws_url>|<page_url>" lines, one per issuer.
# ws_url is empty if no matching tab is found. Daemon-unreachable returns
# exit 2 with no output.
discover_tabs() {
  local json
  if ! json=$(curl --max-time "$CDP_TIMEOUT_SEC" -fsS "http://127.0.0.1:$DAEMON_PORT/json" 2>/dev/null); then
    return 2
  fi
  "$PYTHON_BIN" - "$json" <<'PY'
import json, sys
tabs = json.loads(sys.argv[1])
tracked = [
    ("amex",  "americanexpress.com"),
    ("chase", "chase.com"),
]
page_tabs = [t for t in tabs if t.get("type") == "page"]
for issuer, needle in tracked:
    match = next((t for t in page_tabs if needle in (t.get("url") or "")), None)
    ws_url = match["webSocketDebuggerUrl"] if match else ""
    page_url = match.get("url") if match else ""
    print(f"{issuer}|{ws_url}|{page_url}")
PY
}
```

- [ ] **Step 2: Smoke-test (daemon up)**

Run:
```bash
cards/bin/cards-keepalive.sh discover_tabs 2>/dev/null || true
# (function is internal; smoke-test by sourcing instead:)
( source cards/bin/cards-keepalive.sh 2>/dev/null; discover_tabs )
```

Note: sourcing the script triggers its main-flow stub. For a clean smoke test, run discovery directly via:

```bash
curl -fsS "http://127.0.0.1:19223/json" | /usr/bin/python3 -c "
import json, sys
tabs = json.load(sys.stdin)
for t in tabs:
    if t.get('type') == 'page':
        print(t.get('url'))
"
```

Expected: one or more URLs printed. If `americanexpress.com` and/or `chase.com` tabs are open, they should appear.

- [ ] **Step 3: Smoke-test (daemon down)**

Run:
```bash
# Temporarily stop the daemon
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
sleep 2

# Run a stripped discover_tabs test:
curl --max-time 5 -fsS "http://127.0.0.1:19223/json" 2>/dev/null
echo "exit: $?"
# Expected exit non-zero (typically 7 for connection refused).

# Restart daemon
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
sleep 5
```

Expected: daemon-down case returns non-zero from curl, which the script will translate to its own exit 2.

- [ ] **Step 4: Commit**

```bash
git add cards/bin/cards-keepalive.sh
git commit -m "cards-keepalive: add discover_tabs (CDP /json enumeration)

Returns one line per tracked issuer (amex, chase) with ws_url and page_url
(or empty ws_url if no match). Exit 2 propagates daemon-down upward.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: Implement per-tab websocket probe (`Page.bringToFront` + scroll + probe)

**Files:**
- Modify: `cards/bin/cards-keepalive.sh`

Per-tab work uses Python + websocket-client (same pattern as the existing `activate-amex.sh` / `activate-chase.sh` helpers). The function emits a JSON line on stdout describing the probed state.

- [ ] **Step 1: Add `probe_tab` function**

In `cards/bin/cards-keepalive.sh`, add after `discover_tabs`:

```bash
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
```

- [ ] **Step 2: Smoke-test against an Amex tab**

Prerequisite: cards-bot Chrome is up, an Amex tab is open and logged in.

Run:
```bash
WS=$(curl -fsS http://127.0.0.1:19223/json | /usr/bin/python3 -c "
import json, sys
tabs = json.load(sys.stdin)
for t in tabs:
    if t.get('type') == 'page' and 'americanexpress.com' in (t.get('url') or ''):
        print(t['webSocketDebuggerUrl']); break
")
echo "WS=$WS"
# Source the script to make probe_tab available, then call it
( source cards/bin/cards-keepalive.sh 2>/dev/null; probe_tab "$WS" )
```

Expected JSON line like:
```json
{"vis": "visible", "hasPwInput": false, "url": "https://global.americanexpress.com/offers/eligible", "err": ""}
```
or with `hasPwInput: true` if logged out.

- [ ] **Step 3: Smoke-test `probe_tab_to_state`**

Run:
```bash
( source cards/bin/cards-keepalive.sh 2>/dev/null; \
  probe_tab_to_state '{"vis":"visible","hasPwInput":false,"url":"x","err":""}' )
# Expected: authed

( source cards/bin/cards-keepalive.sh 2>/dev/null; \
  probe_tab_to_state '{"vis":"visible","hasPwInput":true,"url":"x","err":""}' )
# Expected: auth-wall

( source cards/bin/cards-keepalive.sh 2>/dev/null; \
  probe_tab_to_state '{"err":"ws connect: refused"}' )
# Expected: dom-error
```

- [ ] **Step 4: Commit**

```bash
git add cards/bin/cards-keepalive.sh
git commit -m "cards-keepalive: add probe_tab and probe_tab_to_state

Per-tab CDP: Page.bringToFront, 1-3 px random forward scroll, 250ms wait,
counter-scroll, then a probe returning {vis, hasPwInput, url}. Classifier
maps probe output to one of: authed | auth-wall | vis-error | dom-error.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: Implement event-log read/append + cooldown read/write

**Files:**
- Modify: `cards/bin/cards-keepalive.sh`

- [ ] **Step 1: Add `last_state_for` (read prev state from jsonl tail)**

In `cards/bin/cards-keepalive.sh`, add after `probe_tab_to_state`:

```bash
# ----------------------------------------------------------------------------
# State persistence — append-only JSONL events + atomic cooldown JSON.
# ----------------------------------------------------------------------------

# last_state_for ISSUER → prints "unknown" if no entry, else the latest "new".
last_state_for() {
  local issuer="$1"
  if [[ ! -f "$EVENTS_FILE" ]]; then
    echo "unknown"
    return
  fi
  "$PYTHON_BIN" - "$EVENTS_FILE" "$issuer" <<'PY'
import json, sys
path, issuer = sys.argv[1], sys.argv[2]
last = "unknown"
try:
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("issuer") == issuer:
                last = e.get("new", "unknown")
except FileNotFoundError:
    pass
print(last)
PY
}
```

- [ ] **Step 2: Add `append_event`**

Add below:

```bash
# append_event ISSUER PREV NEW NOTE [SCREENSHOT_PATH]
# Appends a single JSON line. Caller has already ensured STATE_DIR exists.
append_event() {
  local issuer="$1" prev="$2" new="$3" note="$4" screenshot="${5:-}"
  "$PYTHON_BIN" - "$EVENTS_FILE" "$issuer" "$prev" "$new" "$note" "$screenshot" <<'PY'
import json, sys, os
from datetime import datetime, timezone
path, issuer, prev, new, note, screenshot = sys.argv[1:7]
entry = {
    "ts": datetime.now(timezone.utc).isoformat(),
    "issuer": issuer,
    "prev": prev,
    "new": new,
    "note": note,
}
if screenshot:
    entry["screenshot"] = screenshot
line = json.dumps(entry) + "\n"
# Append is line-atomic at <4KB under POSIX.
with open(path, "a") as f:
    f.write(line)
PY
}
```

- [ ] **Step 3: Add `cooldown_get` and `cooldown_set`**

Add below:

```bash
# cooldown_get KEY → prints last-sent ISO timestamp or empty string.
cooldown_get() {
  local key="$1"
  if [[ ! -f "$COOLDOWN_FILE" ]]; then
    echo ""
    return
  fi
  "$PYTHON_BIN" - "$COOLDOWN_FILE" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except (FileNotFoundError, json.JSONDecodeError):
    d = {}
v = d.get(key)
print(v if isinstance(v, str) else "")
PY
}

# cooldown_set KEY ISO_TS — atomic-write (tmp + rename).
cooldown_set() {
  local key="$1" ts="$2"
  "$PYTHON_BIN" - "$COOLDOWN_FILE" "$key" "$ts" <<'PY'
import json, os, sys
path, key, ts = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(path))
except (FileNotFoundError, json.JSONDecodeError):
    d = {}
d[key] = ts
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w") as f:
    json.dump(d, f)
os.replace(tmp, path)
PY
}
```

- [ ] **Step 4: Smoke-test event log + cooldown**

Run:
```bash
# Ensure a clean state dir for this test
mkdir -p "$HOME/.claude/skills/credit-card-offers/state"

# Source the script to expose the functions
source cards/bin/cards-keepalive.sh 2>/dev/null
# (the stub main-flow will print "main flow not yet implemented" — ignore)

# Initial read — should be "unknown"
last_state_for amex
# Expected: unknown

# Append an event
append_event amex unknown authed first-observation
last_state_for amex
# Expected: authed

# Append another
append_event amex authed auth-wall "detected by keepalive"
last_state_for amex
# Expected: auth-wall

# Cooldown
cooldown_get amex
# Expected: <empty>

cooldown_set amex "2026-05-14T09:15:00+00:00"
cooldown_get amex
# Expected: 2026-05-14T09:15:00+00:00

# Inspect the files
cat "$HOME/.claude/skills/credit-card-offers/state/keepalive-events.jsonl"
cat "$HOME/.claude/skills/credit-card-offers/state/auth-notify-cooldown.json"

# Clean up the test entries (these are fake)
rm "$HOME/.claude/skills/credit-card-offers/state/keepalive-events.jsonl"
rm "$HOME/.claude/skills/credit-card-offers/state/auth-notify-cooldown.json"
```

Expected: events appended correctly, cooldown stored as JSON, files removed cleanly.

- [ ] **Step 5: Commit**

```bash
git add cards/bin/cards-keepalive.sh
git commit -m "cards-keepalive: add event-log + cooldown persistence

last_state_for reads the jsonl tail to determine prev state per issuer.
append_event writes a single line atomically (<4KB POSIX append guarantee).
cooldown_get/set use tmp+rename for atomic JSON updates.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: Implement Telegram notification + screenshot capture

**Files:**
- Modify: `cards/bin/cards-keepalive.sh`

- [ ] **Step 1: Add `capture_screenshot`**

In `cards/bin/cards-keepalive.sh`, add after `cooldown_set`:

```bash
# ----------------------------------------------------------------------------
# Telegram + screenshots (impure; smoke-tested manually).
# ----------------------------------------------------------------------------

# capture_screenshot WS_URL ISSUER LABEL → prints absolute screenshot path
# on success, empty string on failure (best-effort).
capture_screenshot() {
  local ws_url="$1" issuer="$2" label="$3"
  mkdir -p "$SCREENSHOT_DIR"
  local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
  local path="$SCREENSHOT_DIR/keepalive-${label}-${issuer}-${ts}.png"
  if "$PYTHON_BIN" - "$ws_url" "$path" <<'PY' 2>/dev/null
import json, sys, base64
try:
    import websocket
except ImportError:
    sys.exit(1)
ws_url, out = sys.argv[1], sys.argv[2]
try:
    ws = websocket.create_connection(ws_url, suppress_origin=True, timeout=5)
    ws.send(json.dumps({"id": 1, "method": "Page.captureScreenshot", "params": {"format": "png"}}))
    while True:
        r = json.loads(ws.recv())
        if r.get("id") == 1:
            break
    b64 = r.get("result", {}).get("data")
    ws.close()
    if not b64:
        sys.exit(1)
    with open(out, "wb") as f:
        f.write(base64.b64decode(b64))
except Exception:
    sys.exit(1)
PY
  then
    echo "$path"
  else
    echo ""
  fi
}
```

- [ ] **Step 2: Add `send_telegram_notify`**

Add below:

```bash
# send_telegram_notify ISSUER PREV NEW SCREENSHOT_PATH
# Returns 0 on Telegram OK, non-zero on send failure.
# HTML body, escaped per CLAUDE.md (& < > applied last).
send_telegram_notify() {
  local issuer="$1" prev="$2" new="$3" screenshot="$4"
  local now; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local issuer_label
  case "$issuer" in
    amex)   issuer_label="Amex" ;;
    chase)  issuer_label="Chase" ;;
    both)   issuer_label="Both issuers" ;;
    daemon) issuer_label="Daemon Chrome" ;;
    *)      issuer_label="$issuer" ;;
  esac

  local emoji
  case "$new" in
    auth-wall)   emoji="🔐" ;;
    tab-missing) emoji="🗂️"  ;;
    daemon-down) emoji="💥" ;;
    *)           emoji="ℹ️"  ;;
  esac

  local body_html
  body_html=$(cat <<EOF
$emoji <b>Cards keepalive — $issuer_label</b>

<b>State:</b> $prev → $new
<b>At:</b> $now
<b>Screenshot:</b> $screenshot

<b>Recovery:</b> VNC into Mac mini → cards-bot Chrome (port 19223) → re-login.
No code change needed; next keepalive iteration will record recovery.
EOF
)
  # Apply HTML escape pipeline LAST so <b> tags survive.
  local body_escaped
  body_escaped=$(printf '%s' "$body_html" \
    | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  # Restore the few tags we want to use.
  body_escaped=$(printf '%s' "$body_escaped" \
    | sed 's|\&lt;b\&gt;|<b>|g; s|\&lt;/b\&gt;|</b>|g')

  local plain
  plain=$(printf '%s' "$body_html" | sed 's/<[^>]*>//g')

  local run_dir="$STATE_DIR/.keepalive-tg-tmp"
  mkdir -p "$run_dir"
  printf '%s' "$body_escaped" > "$run_dir/digest.html"
  printf '%s' "$plain"        > "$run_dir/digest.txt"

  TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
  TELEGRAM_MESSAGE_FILE="$run_dir/digest.html" \
  TELEGRAM_MESSAGE_PLAIN_FILE="$run_dir/digest.txt" \
  RUN_DIR="$run_dir" \
    "$TELEGRAM_HELPER"
}
```

- [ ] **Step 3: Smoke-test the Telegram path (sends real message)**

Run:
```bash
# Build a test message and send it
source cards/bin/cards-keepalive.sh 2>/dev/null

# Use a benign label so the operator knows this is a manual test
send_telegram_notify amex authed auth-wall "/tmp/no-screenshot.png"
echo "exit: $?"
```

Expected: exit 0, and a Telegram message arrives in the cards chat (id 7953915703) saying "Cards keepalive — Amex" with state authed → auth-wall. Verify by checking your phone or Telegram client.

- [ ] **Step 4: Smoke-test screenshot capture**

Run:
```bash
source cards/bin/cards-keepalive.sh 2>/dev/null
WS=$(curl -fsS http://127.0.0.1:19223/json | /usr/bin/python3 -c "
import json, sys
for t in json.load(sys.stdin):
    if t.get('type') == 'page':
        print(t.get('webSocketDebuggerUrl')); break
")
PATH_OUT=$(capture_screenshot "$WS" test auth)
echo "Path: $PATH_OUT"
ls -la "$PATH_OUT"
file "$PATH_OUT"
rm "$PATH_OUT"
```

Expected: a real PNG file (file output mentions `PNG image data`), then cleaned up.

- [ ] **Step 5: Commit**

```bash
git add cards/bin/cards-keepalive.sh
git commit -m "cards-keepalive: add capture_screenshot and send_telegram_notify

Screenshot via CDP Page.captureScreenshot, base64-decoded to disk.
Telegram via the twitter package's hardened helper (HTML body, escape
pipeline applied last, plain-text fallback file). Cooldown is enforced
at the call site, not here.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: Wire the main flow (lock check + jitter + per-issuer loop + state diff)

**Files:**
- Modify: `cards/bin/cards-keepalive.sh`

- [ ] **Step 1: Replace the main-flow stub**

In `cards/bin/cards-keepalive.sh`, replace these two lines:

```bash
echo "cards-keepalive: main flow not yet implemented" >&2
exit 0
```

with:

```bash
# ----------------------------------------------------------------------------
# Main flow — one shot per launchd invocation.
# ----------------------------------------------------------------------------

mkdir -p "$STATE_DIR" || {
  echo "cards-keepalive: cannot create state dir $STATE_DIR" >&2
  exit 1
}

# 1. Jitter sleep (breaks perfect-cadence pattern).
sleep $((RANDOM % (JITTER_MAX_SEC + 1)))

# 2. Lock check.
if [[ -f "$LOCK_FILE" ]]; then
  now_epoch=$(date +%s)
  lock_mtime=$(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)
  if [[ "$(lock_is_stale "$now_epoch" "$lock_mtime" "$STALE_LOCK_SEC")" == "no" ]]; then
    # Active fire in progress — defer.
    exit 0
  fi
  # Stale; log and proceed.
  printf "%s stale-lock proceed (lock mtime=%s now=%s)\n" \
    "$(date -u +%FT%TZ)" "$lock_mtime" "$now_epoch" >> "$LOG_FILE"
fi

# 3. Discover tabs.
if ! tabs_out=$(discover_tabs); then
  # Daemon unreachable.
  now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  prev_daemon=$(last_state_for both)
  if [[ "$prev_daemon" != "daemon-down" ]]; then
    append_event both "$prev_daemon" daemon-down "curl /json failed"
    last_sent=$(cooldown_get daemon)
    if [[ "$(cooldown_should_send "$last_sent" "$now_iso" "$COOLDOWN_SEC")" == "yes" ]]; then
      if send_telegram_notify daemon "$prev_daemon" daemon-down ""; then
        cooldown_set daemon "$now_iso"
        printf "%s daemon %s→daemon-down telegram-sent\n" "$now_iso" "$prev_daemon" >> "$LOG_FILE"
      else
        printf "%s daemon %s→daemon-down telegram-failed\n" "$now_iso" "$prev_daemon" >> "$LOG_FILE"
      fi
    else
      printf "%s daemon %s→daemon-down throttled\n" "$now_iso" "$prev_daemon" >> "$LOG_FILE"
    fi
  fi
  exit 2
fi

# 4. Per-tab work.
while IFS='|' read -r issuer ws_url page_url; do
  [[ -z "$issuer" ]] && continue
  prev=$(last_state_for "$issuer")

  # 4a. tab-missing → no probe, transition immediately.
  if [[ -z "$ws_url" ]]; then
    new="tab-missing"
  else
    probe=$(probe_tab "$ws_url")
    new=$(probe_tab_to_state "$probe")
  fi

  # 4b. Diff.
  if [[ "$prev" == "$new" ]]; then
    continue
  fi

  # 4c. Capture screenshot for notifiable transitions only.
  screenshot=""
  if [[ "$(state_diff_is_notifiable "$prev" "$new")" == "yes" && -n "$ws_url" ]]; then
    screenshot=$(capture_screenshot "$ws_url" "$issuer" "$new")
  fi

  # 4d. Record the transition.
  note="detected by keepalive"
  if [[ "$prev" == "unknown" ]]; then
    note="first-observation"
  elif [[ "$new" == "authed" ]]; then
    note="operator-relogin (inferred)"
  fi
  append_event "$issuer" "$prev" "$new" "$note" "$screenshot"

  # 4e. Telegram if notifiable, subject to cooldown.
  if [[ "$(state_diff_is_notifiable "$prev" "$new")" == "yes" ]]; then
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    last_sent=$(cooldown_get "$issuer")
    if [[ "$(cooldown_should_send "$last_sent" "$now_iso" "$COOLDOWN_SEC")" == "yes" ]]; then
      if send_telegram_notify "$issuer" "$prev" "$new" "$screenshot"; then
        cooldown_set "$issuer" "$now_iso"
        printf "%s %s %s→%s telegram-sent\n" "$now_iso" "$issuer" "$prev" "$new" >> "$LOG_FILE"
      else
        printf "%s %s %s→%s telegram-failed\n" "$now_iso" "$issuer" "$prev" "$new" >> "$LOG_FILE"
      fi
    else
      printf "%s %s %s→%s throttled\n" "$now_iso" "$issuer" "$prev" "$new" >> "$LOG_FILE"
    fi
  else
    printf "%s %s %s→%s silent\n" "$(date -u +%FT%TZ)" "$issuer" "$prev" "$new" >> "$LOG_FILE"
  fi
done <<< "$tabs_out"

exit 0
```

- [ ] **Step 2: Syntax check**

Run:
```bash
bash -n cards/bin/cards-keepalive.sh
```
Expected: silent exit 0.

- [ ] **Step 3: Run a live one-shot iteration against the bot Chrome**

Prerequisite: cards-bot Chrome up, Amex + Chase tabs open (logged-in or not).

Run:
```bash
KEEPALIVE_SELFTEST= cards/bin/cards-keepalive.sh
echo "exit: $?"
ls -la "$HOME/.claude/skills/credit-card-offers/state/keepalive-events.jsonl"
cat "$HOME/.claude/skills/credit-card-offers/state/keepalive-events.jsonl"
```

Expected:
- exit 0 (or 2 if daemon is unreachable).
- jsonl file exists with one event per issuer (transitions from `unknown` to `authed`/`auth-wall`/`tab-missing`).
- If any issuer transitioned into a notifiable state, a Telegram arrived AND `auth-notify-cooldown.json` was created.

- [ ] **Step 4: Run a second iteration — verify silence on stable state**

Run:
```bash
KEEPALIVE_SELFTEST= cards/bin/cards-keepalive.sh
echo "exit: $?"
wc -l "$HOME/.claude/skills/credit-card-offers/state/keepalive-events.jsonl"
```

Expected: exit 0, jsonl line count unchanged (state didn't transition, so no new event).

- [ ] **Step 5: Commit**

```bash
git add cards/bin/cards-keepalive.sh
git commit -m "cards-keepalive: wire main flow (jitter, lock, discover, probe, diff, notify)

One-shot per invocation. Stale-lock cap (30 min) handled with logging.
Daemon-down path uses 'both' issuer for cooldown bucket 'daemon'.
Per-issuer loop: probe, diff against last-known, append event on change,
screenshot + Telegram + cooldown only on notifiable transitions.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: Modify `cards-fire.sh` — add lock-write + trap-cleanup + park-on-offers

**Files:**
- Modify: `cards/bin/cards-fire.sh`

- [ ] **Step 1: Read the current fire script**

Run:
```bash
cat cards/bin/cards-fire.sh
```

Identify three insertion points:
1. After the `shlock`/flock acquisition (or at the start of the body if there's no separate shlock block).
2. The exit/cleanup path (existing `trap` or just before `exit`).
3. After the fire body completes (before exit), where we'll park tabs.

- [ ] **Step 2: Add the lock-write block**

In `cards/bin/cards-fire.sh`, immediately after the line that ACQUIRES the flock (the line that runs `flock` or `shlock` for the `.cards-fire.lock` file), insert:

```bash
# fire-in-progress sentinel: tells cards-keepalive.sh to skip iterations
# while we own the bot Chrome. Cleaned up by the trap below.
FIRE_IN_PROGRESS_LOCK="$HOME/.claude/skills/credit-card-offers/state/fire-in-progress.lock"
mkdir -p "$(dirname "$FIRE_IN_PROGRESS_LOCK")"
echo "$$ $(date -u +%FT%TZ)" > "$FIRE_IN_PROGRESS_LOCK"
trap 'rm -f "$FIRE_IN_PROGRESS_LOCK"' EXIT INT TERM
```

If `cards-fire.sh` already has a `trap` registered, **append** the `rm -f` to it rather than overwriting. (Multiple traps for the same signal stomp on each other in bash.) If unsure, read the existing trap and combine.

- [ ] **Step 3: Add the park-on-offers block (just before script exit)**

Identify the last statement before the script exits successfully (after the `claude -p` invocation and any post-claude cleanup). Insert this block immediately before the exit:

```bash
# Park Amex and Chase tabs on their offers URLs so the next keepalive
# iteration finds them in a stable location. Bounded; best-effort.
park_offers_tabs() {
  /usr/bin/python3 - <<'PY'
import json, time, urllib.request
import websocket  # type: ignore

try:
    tabs = json.loads(
        urllib.request.urlopen("http://127.0.0.1:19223/json", timeout=3).read()
    )
except Exception as e:
    print(f"park_offers_tabs: cannot list tabs: {e}", file=__import__("sys").stderr)
    return

targets = [
    ("americanexpress.com", "https://global.americanexpress.com/offers/eligible"),
    ("chase.com",           "https://secure.chase.com/web/auth/dashboard#/dashboard/offers/offerHub"),
]
for needle, url in targets:
    tab = next((t for t in tabs
                if t.get("type") == "page" and needle in (t.get("url") or "")), None)
    if not tab:
        continue
    try:
        ws = websocket.create_connection(tab["webSocketDebuggerUrl"],
                                         suppress_origin=True, timeout=5)
        ws.send(json.dumps({"id": 1, "method": "Page.navigate", "params": {"url": url}}))
        # Drain one response so the send actually completes.
        ws.settimeout(5)
        try:
            ws.recv()
        except Exception:
            pass
        ws.close()
    except Exception as e:
        print(f"park_offers_tabs: nav {needle} failed: {e}", file=__import__("sys").stderr)
    time.sleep(2)  # bounded wait for page settle
PY
}

park_offers_tabs || true   # never fail the fire because of parking
```

Wait — the snippet above uses a Python heredoc with a Python `return` outside a function. Replace with:

```bash
park_offers_tabs() {
  /usr/bin/python3 - <<'PY'
import json, sys, time, urllib.request
try:
    import websocket
except ImportError:
    print("park_offers_tabs: websocket-client missing", file=sys.stderr); sys.exit(0)
try:
    tabs = json.loads(urllib.request.urlopen("http://127.0.0.1:19223/json", timeout=3).read())
except Exception as e:
    print(f"park_offers_tabs: cannot list tabs: {e}", file=sys.stderr); sys.exit(0)
targets = [
    ("americanexpress.com", "https://global.americanexpress.com/offers/eligible"),
    ("chase.com",           "https://secure.chase.com/web/auth/dashboard#/dashboard/offers/offerHub"),
]
for needle, url in targets:
    tab = next((t for t in tabs if t.get("type") == "page" and needle in (t.get("url") or "")), None)
    if not tab:
        continue
    try:
        ws = websocket.create_connection(tab["webSocketDebuggerUrl"], suppress_origin=True, timeout=5)
        ws.send(json.dumps({"id": 1, "method": "Page.navigate", "params": {"url": url}}))
        ws.settimeout(5)
        try:
            ws.recv()
        except Exception:
            pass
        ws.close()
    except Exception as e:
        print(f"park_offers_tabs: nav {needle} failed: {e}", file=sys.stderr)
    time.sleep(2)
PY
}

park_offers_tabs || true
```

- [ ] **Step 4: Syntax check**

Run:
```bash
bash -n cards/bin/cards-fire.sh
```
Expected: silent exit 0.

- [ ] **Step 5: Smoke-test the lock + trap**

Run:
```bash
# Manually source-and-trap-test by calling the fire script in dry-run.
~/dotfiles/cards/bin/cards-fire.sh credit-card-offers --dry-run &
SLEEP_PID=$!
sleep 3   # give fire a moment to start and write the lock
ls -la "$HOME/.claude/skills/credit-card-offers/state/fire-in-progress.lock"
# Expected: file exists, content starts with the fire's PID.

wait $SLEEP_PID
# After fire completes, trap should have fired.
ls "$HOME/.claude/skills/credit-card-offers/state/fire-in-progress.lock" 2>&1
# Expected: "No such file or directory" — trap cleaned up.
```

- [ ] **Step 6: Smoke-test park-on-offers**

Manually open the bot Chrome's Amex tab on some non-offers URL (e.g. amex.com home). Run:

```bash
~/dotfiles/cards/bin/cards-fire.sh credit-card-offers --dry-run
# Wait for it to complete, then check the bot Chrome's Amex tab URL via CDP:
curl -fsS http://127.0.0.1:19223/json | /usr/bin/python3 -c "
import json, sys
for t in json.load(sys.stdin):
    if t.get('type') == 'page' and 'americanexpress.com' in (t.get('url') or ''):
        print(t.get('url'))
"
```
Expected: URL ends with `/offers/eligible`.

- [ ] **Step 7: Commit**

```bash
git add cards/bin/cards-fire.sh
git commit -m "cards-fire: write fire-in-progress.lock + trap + park-on-offers

Three additive changes to support the new cards-keepalive job:
- Lock file at fire start (PID + ISO ts).
- trap EXIT INT TERM removes the lock.
- After fire body, park Amex + Chase tabs on their offers URLs so the
  keepalive iteration that runs ~5 min later finds them stable.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 11: Create the launchd plist and bootstrap it

**Files:**
- Create: `cards/Library/LaunchAgents/com.pattybot.cards-keepalive.plist`

- [ ] **Step 1: Create the plist**

Write to `cards/Library/LaunchAgents/com.pattybot.cards-keepalive.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pattybot.cards-keepalive</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/pattybot/dotfiles/cards/bin/cards-keepalive.sh</string>
    </array>

    <key>StartInterval</key>
    <integer>300</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>StandardOutPath</key>
    <string>/Users/pattybot/Library/Logs/cards-keepalive.out.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/pattybot/Library/Logs/cards-keepalive.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/pattybot</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 2: Validate plist syntax**

Run:
```bash
plutil -lint cards/Library/LaunchAgents/com.pattybot.cards-keepalive.plist
```
Expected: `... : OK`.

- [ ] **Step 3: Run stow to refresh symlinks**

Run:
```bash
cd ~/dotfiles && stow -t ~ -R cards
ls -la ~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist
ls -la ~/bin/cards-keepalive.sh
```
Expected: both are symlinks pointing into `~/dotfiles/.claude/worktrees/cards-keepalive-spec-v2/cards/...` (or into the merged location once merged to main).

Note: this worktree's branch is `worktree-cards-keepalive-spec-v2`. Stow operates from `~/dotfiles/cards`, not the worktree. If `~/dotfiles/cards/Library/LaunchAgents/` doesn't yet contain the plist (because it's in the worktree branch), the symlink target won't exist. **The merge-to-main step is required before stow can link the new files.** See Task 14 for the merge.

Until the merge: run keepalive manually for testing, but don't `launchctl bootstrap` against a non-existent target.

- [ ] **Step 4: Commit the plist**

```bash
git add cards/Library/LaunchAgents/com.pattybot.cards-keepalive.plist
git commit -m "cards-keepalive: add launchd plist (5-min cadence, RunAtLoad)

StartInterval=300, RunAtLoad=true so first iteration fires immediately on
bootstrap (no 5-min wait). ProcessType=Interactive matches the other cards
plists. Stdout/stderr go to ~/Library/Logs/cards-keepalive.{out,err}.log.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 12: Update CLAUDE.md (two-job → three-job architecture)

**Files:**
- Modify: `cards/CLAUDE.md`

- [ ] **Step 1: Update the symlink table**

In `cards/CLAUDE.md`, the table under "What this repo is" lists the package's symlinks. Add a row for the keepalive script and plist (alphabetical / colocated with other bin and Library entries):

```markdown
| `bin/cards-keepalive.sh` | `~/bin/cards-keepalive.sh` |
| `Library/LaunchAgents/com.pattybot.cards-keepalive.plist` | `~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist` |
```

- [ ] **Step 2: Rename and rewrite the architecture section**

Find the `## Two-job architecture` heading. Rename to `## Three-job architecture`. Replace the section body with:

```markdown
Mirrors the twitter package's two-job pattern, extended to three. Three launchd jobs cooperate:

1. **`com.pattybot.cards-bot-chrome`** — `KeepAlive: true`, runs `Google Chrome.app` with `--user-data-dir=~/Library/Application Support/cards-bot-chrome --remote-debugging-port=19223`. **Always running.** This is the only Chrome the offers skill ever talks to — its persistent profile holds the Chase + Amex session cookies. Coexists with the twitter bot Chrome (9222) and the user's daily Chrome because Chromium's process singleton is keyed on `--user-data-dir`.
2. **`com.pattybot.credit-card-offers`** — `StartCalendarInterval` at 03:00 local time daily, fires `bin/cards-fire.sh credit-card-offers`. `RunAtLoad=false` so a fresh launchctl-bootstrap doesn't trigger a mid-day fire against bank sites — only the next 03:00.
3. **`com.pattybot.cards-keepalive`** — `StartInterval: 300` (every 5 min), `RunAtLoad: true`. Fires `bin/cards-keepalive.sh`. Pokes the daemon Chrome's Amex/Chase tabs with `Page.bringToFront` + 1–3 px scroll to reset bank-side idle timers, and observes session state. Telegrams the operator on auth-wall transitions (per-issuer 6h cooldown). See `docs/superpowers/specs/2026-05-13-cards-session-keepalive-design.md`.

The fire wrapper is split into two pieces, structurally identical to twitter:

- **`bin/cards-prefire.sh`** — OS plumbing only. Health-checks `http://127.0.0.1:19223/json/version` for up to 12s; disambiguates the cards bot Chrome from the twitter bot Chrome and the user's daily Chrome via `lsof -iTCP:19223 -sTCP:LISTEN -t`; CDP-unminimizes bot Chrome windows; pre-warms System Events; PID-activates the bot Chrome with a 30s timeout; bounded-polls activation settlement. Emits `SAVED_FRONTMOST_PID=<pid>` as its final stdout line. Does NOT invoke claude or touch Telegram.
- **`bin/cards-fire.sh <skill-name>`** — orchestrator. Acquires shared shlock at `~/.claude/skills/.cards-fire.lock` (exits 3 with `kind:busy` on conflict); writes `state/fire-in-progress.lock` for the keepalive to honor; calls prefire; runs `claude -p` against the named skill's SKILL.md; parks Amex + Chase tabs on their offers URLs after the fire body; restores prior frontmost only if bot Chrome is still frontmost at restore time; trap removes `state/fire-in-progress.lock` on exit. One wrapper, room for multiple skills under the `cards` package umbrella.

The keepalive wrapper is a separate one-shot:

- **`bin/cards-keepalive.sh`** — one iteration per launchd invocation. Reads `state/fire-in-progress.lock` and skips if a fire is active (with a 30-min stale-lock cap so a crashed fire can't permanently deadlock the keepalive). Otherwise: discover tracked tabs via CDP, per-tab `Page.bringToFront` + 1–3 px scroll + counter-scroll + probe, diff against `state/keepalive-events.jsonl` tail, append event on state change, Telegram on notifiable transitions (subject to per-issuer 6h cooldown). Does not log in, type, click, retry, navigate, or open/close tabs. See spec for full taxonomy.

The skill (`.claude/skills/credit-card-offers/SKILL.md`) is the actual work: CDP-attach, navigate to Chase Offers hub + Amex Offers, click "Add to card" on every unactivated offer, dedup against `state/{chase,amex}-activated.json`, deliver summary to Telegram.
```

- [ ] **Step 3: Add keepalive control commands to "Common commands"**

Find the `## Common commands` section. Below the `# Daemon Chrome control (NEVER use Cmd-Q ...)` block, add:

```bash
# Keepalive control (5-min cadence, RunAtLoad=true so first iteration is
# immediate on bootstrap; safe to bootout/bootstrap any time).
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist

# Manual one-shot keepalive iteration (no plist needed; useful for debugging)
~/dotfiles/cards/bin/cards-keepalive.sh

# Self-test mode (runs pure-function assertions; safe to run anytime)
KEEPALIVE_SELFTEST=1 ~/dotfiles/cards/bin/cards-keepalive.sh

# Inspect keepalive activity
tail -50 ~/Library/Logs/cards-keepalive.log
tail -20 ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl | python3 -m json.tool
```

- [ ] **Step 4: Add log path to the Logs list**

Find the "Logs:" bulleted list. Add:

```markdown
- `~/Library/Logs/cards-keepalive.log` — state-change events from the 5-min keepalive (silent on healthy iterations)
- `~/Library/Logs/cards-keepalive.{out,err}.log` — keepalive stdout/stderr (launchd-level)
```

- [ ] **Step 5: Verify CLAUDE.md still renders cleanly**

Run:
```bash
grep -c '^## ' cards/CLAUDE.md
```
Spot-check by reading: `less cards/CLAUDE.md`.

- [ ] **Step 6: Commit**

```bash
git add cards/CLAUDE.md
git commit -m "cards: update CLAUDE.md for three-job architecture

Adds cards-keepalive to the symlink table, renames the architecture section,
documents the keepalive wrapper alongside the fire wrapper, adds bootout/
bootstrap commands and log paths. Existing two-job content is preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 13: Update SKILL.md and runbook.md cross-references

**Files:**
- Modify: `cards/.claude/skills/credit-card-offers/SKILL.md`
- Modify: `cards/.claude/skills/credit-card-offers/references/runbook.md`

- [ ] **Step 1: Add keepalive cross-reference in SKILL.md "What this skill does NOT do"**

In `cards/.claude/skills/credit-card-offers/SKILL.md`, find the section `## What this skill does NOT do`. At the end of that section, add:

```markdown
- **Does not run the session keepalive inline.** Session-keepalive is a separate launchd job (`com.pattybot.cards-keepalive`, every 5 min) that maintains the bot Chrome's Amex/Chase session liveness between fires via `Page.bringToFront` + small scroll. The fire's only interaction with the keepalive is via `state/fire-in-progress.lock` (written at fire start, removed on exit) — the keepalive honors that lock and skips iterations during fires. Don't invoke `bin/cards-keepalive.sh` from this skill. See `docs/superpowers/specs/2026-05-13-cards-session-keepalive-design.md`.
```

- [ ] **Step 2: Add keepalive note to SKILL.md "What NOT to do"**

In the `## What NOT to do` list, add at the end:

```markdown
- **Do not write to `state/keepalive-events.jsonl`, `state/auth-notify-cooldown.json`, or `state/fire-in-progress.lock`.** Those are owned by `cards-keepalive.sh` and `cards-fire.sh`'s wrapper layer respectively. The skill's writes go to `state/last-success.json`, `state/last-failure.json`, `state/pending.json`, and the dedup files only. Strict file ownership is part of the keepalive's defensive design.
```

- [ ] **Step 3: Update the runbook with a "session died" recovery section**

In `cards/.claude/skills/credit-card-offers/references/runbook.md`, find an appropriate section (e.g. after the failure-kind table). Add a new section:

```markdown
## Session-died recovery (keepalive Telegram path)

When you receive a Telegram from `cards-keepalive` saying "State: authed → auth-wall" (or "→ tab-missing", "→ daemon-down"), the bot Chrome's session for that issuer has died and the next 03:00 fire will hit a login wall. Recovery:

### auth-wall

1. VNC into the Mac mini.
2. Open the cards-bot Chrome window (port 19223; if you have multiple Chromes running, the cards one is the one with the Amex/Chase tabs).
3. Sign back in on the affected issuer (or both). Complete any MFA challenge presented.
4. **Do nothing else.** Don't navigate, don't close tabs, don't open new ones.
5. The next keepalive iteration (within 5 minutes) will probe and record a `auth-wall → authed` event in `keepalive-events.jsonl`. **No code action needed.** The next 03:00 fire will succeed.

### tab-missing

Same recovery as auth-wall, plus: open a new tab to the issuer's offers URL:
- Amex: `https://global.americanexpress.com/offers/eligible`
- Chase: `https://secure.chase.com/web/auth/dashboard#/dashboard/offers/offerHub`

### daemon-down

The cards-bot Chrome itself is unreachable. Steps:

```bash
launchctl print gui/$(id -u)/com.pattybot.cards-bot-chrome
# Look for last_exit_status, runs, state
```

If the daemon Chrome crashed, `KeepAlive=true` should respawn it. If respawn loop is broken:

```bash
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
```

Then sign in on both issuers (the persistent profile means cookies survive, but a fresh Chrome respawn may need to re-establish session in some cases).

## Keepalive event-log forensics

Useful one-liners for triaging keepalive state:

```bash
# Most-recent state per issuer
tail -50 ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl | \
  python3 -c "
import sys, json
last = {}
for line in sys.stdin:
    e = json.loads(line)
    last[e['issuer']] = e
for k, e in last.items():
    print(f\"{k}: {e['new']} (since {e['ts']}, note: {e.get('note', '')})\")
"

# All auth-wall events in the last day
grep auth-wall ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl | \
  python3 -c "
import sys, json
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(days=1)
for line in sys.stdin:
    e = json.loads(line)
    if datetime.fromisoformat(e['ts']) >= cutoff:
        print(line.strip())
"

# Median session lifetime (auth-wall - prior authed timestamp)
# Useful for tracking against the spec's 7-day soak metric.
python3 <<'PY'
import json
from datetime import datetime
events = []
with open(__import__('os').path.expanduser('~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl')) as f:
    for line in f:
        events.append(json.loads(line))
durations = {}
for issuer in ("amex", "chase"):
    issuer_events = [e for e in events if e['issuer'] == issuer]
    spans = []
    last_authed = None
    for e in issuer_events:
        if e['new'] == 'authed':
            last_authed = datetime.fromisoformat(e['ts'])
        elif e['new'] == 'auth-wall' and last_authed:
            spans.append((datetime.fromisoformat(e['ts']) - last_authed).total_seconds())
            last_authed = None
    if spans:
        spans.sort()
        print(f"{issuer}: n={len(spans)}, median={spans[len(spans)//2]/3600:.1f}h, p95={spans[int(len(spans)*0.95)]/3600:.1f}h")
PY
```
```

- [ ] **Step 4: Commit both edits**

```bash
git add cards/.claude/skills/credit-card-offers/SKILL.md \
        cards/.claude/skills/credit-card-offers/references/runbook.md
git commit -m "cards-skill: document keepalive boundary + recovery runbook

SKILL.md gains a 'does not run keepalive inline' note and a file-ownership
reminder. runbook.md gets a 'session-died recovery' section keyed off the
keepalive Telegram path, plus event-log forensics one-liners (current
state per issuer, recent auth-walls, session-lifetime histogram).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 14: Merge worktree branch to main, stow-refresh, launchctl bootstrap

**Files:**
- (No file changes in this task — merge + stow + launchctl.)

This task transfers the implementation from the worktree branch to your live working copy and activates the keepalive.

- [ ] **Step 1: Verify the worktree branch is clean and tests pass**

Run from inside the worktree:
```bash
git status              # expect "nothing to commit, working tree clean"
git log --oneline -15   # confirm the planned commits are all here

# Last selftest pass
KEEPALIVE_SELFTEST=1 cards/bin/cards-keepalive.sh
# Expected: 19/19 passed
```

- [ ] **Step 2: Exit the worktree (keep, don't remove — we want the branch on disk for merge)**

Run:
```bash
# This step is performed by the orchestrator (Claude), not the engineer:
# ExitWorktree(action="keep")
```

The session returns to `/Users/pattybot/dotfiles`. The branch `worktree-cards-keepalive-spec-v2` remains.

- [ ] **Step 3: Merge to main (or whatever the active branch is)**

Run from `~/dotfiles`:
```bash
cd ~/dotfiles
git branch -v             # check current branch (likely main or similar)
git merge --no-ff worktree-cards-keepalive-spec-v2 -m "Merge cards-keepalive design + implementation"
git log --oneline -5
```

If the merge has conflicts (unlikely — the files are mostly new), resolve them by preferring the worktree branch's versions for new files and merging the modifications manually.

- [ ] **Step 4: Run stow to refresh symlinks**

```bash
cd ~/dotfiles && stow -t ~ -R cards
ls -la ~/bin/cards-keepalive.sh
ls -la ~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist
```
Expected: both are symlinks resolving into `~/dotfiles/cards/bin/cards-keepalive.sh` and `~/dotfiles/cards/Library/LaunchAgents/com.pattybot.cards-keepalive.plist`.

- [ ] **Step 5: Bootstrap the launchd job**

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist
launchctl print gui/$(id -u)/com.pattybot.cards-keepalive
```
Expected: `state = running` or `state = waiting` (job idle until next StartInterval), `last_exit_status = 0`.

Because `RunAtLoad=true`, the first iteration kicks off immediately:

```bash
sleep 90   # wait past the jitter + first iteration
ls -la "$HOME/.claude/skills/credit-card-offers/state/keepalive-events.jsonl"
tail -20  "$HOME/.claude/skills/credit-card-offers/state/keepalive-events.jsonl"
```
Expected: at least one event per issuer (transitions from `unknown` to whatever the current state is).

- [ ] **Step 6: Delete the now-merged worktree branch (optional)**

```bash
cd ~/dotfiles
git worktree remove .claude/worktrees/cards-keepalive-spec-v2 --force
git branch -d worktree-cards-keepalive-spec-v2
```

- [ ] **Step 7: Commit (none) — this task only changes infrastructure state.**

No git changes in this task; the merge commit was the actual git work. The bootstrap is persistent across reboots because the plist is in `~/Library/LaunchAgents/`.

---

## Task 15: Run validation Rungs 1–6 from the spec

**Files:**
- (No file changes — validation only.)

Per `docs/superpowers/specs/2026-05-13-cards-session-keepalive-design.md` §8, run the validation ladder against the live deployment.

- [ ] **Step 1: Rung 1 — Static checks**

```bash
bash -n ~/dotfiles/cards/bin/cards-keepalive.sh && echo "syntax ok"
plutil -lint ~/dotfiles/cards/Library/LaunchAgents/com.pattybot.cards-keepalive.plist
test -x /usr/bin/python3 && echo "python3 ok"
/usr/bin/python3 -c "import websocket" && echo "websocket-client ok"
test -x /Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh && echo "tg helper ok"
shellcheck ~/dotfiles/cards/bin/cards-keepalive.sh 2>&1 | head -30 || echo "(shellcheck not installed; skip)"
```
Expected: all checks ok.

- [ ] **Step 2: Rung 2 — about:blank smoke (no banks)**

Open a non-bank tab in the bot Chrome (any URL that doesn't match `americanexpress.com` or `chase.com`). Run:

```bash
~/dotfiles/cards/bin/cards-keepalive.sh
echo "exit: $?"
tail -5 ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl
```

Expected: tab-missing events for both issuers if no matching tab is open. Telegram sent on first observation (per OD8).

- [ ] **Step 3: Rung 3 — Selftest**

```bash
KEEPALIVE_SELFTEST=1 ~/dotfiles/cards/bin/cards-keepalive.sh
```
Expected: 19/19 passed.

- [ ] **Step 4: Rung 4 — Coexistence test**

```bash
echo "99999 $(date -u +%FT%TZ)" > ~/.claude/skills/credit-card-offers/state/fire-in-progress.lock
~/dotfiles/cards/bin/cards-keepalive.sh
echo "fresh-lock exit: $?  (expected 0, silent skip)"

touch -t $(date -v-35M +%Y%m%d%H%M) ~/.claude/skills/credit-card-offers/state/fire-in-progress.lock
~/dotfiles/cards/bin/cards-keepalive.sh
echo "stale-lock exit: $? (expected 0 or 2, proceeds normally)"

rm -f ~/.claude/skills/credit-card-offers/state/fire-in-progress.lock
```
Expected behavior matches the comments.

- [ ] **Step 5: Rung 5 — Failure injection (one kind at a time)**

For each kind, induce → run keepalive → check expected outcome.

```bash
# kind: daemon-down
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
sleep 3
~/dotfiles/cards/bin/cards-keepalive.sh
echo "exit: $?  (expected 2)"
tail -2 ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl
# Expected: daemon-down event, Telegram fired (first time)

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
sleep 10
# Now restore and run again; expect daemon-down → authed/auth-wall transition
~/dotfiles/cards/bin/cards-keepalive.sh

# kind: tab-missing
# Manually close the Amex tab in the bot Chrome via VNC, then:
~/dotfiles/cards/bin/cards-keepalive.sh
tail -2 ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl
# Expected: amex tab-missing event, chase unaffected

# kind: auth-wall
# Manually navigate the Amex tab to https://www.americanexpress.com/en-us/account/login/
# (signs out), then:
~/dotfiles/cards/bin/cards-keepalive.sh
# Expected: amex auth-wall event, Telegram (subject to cooldown from prior tests)

# kind: dom-error
# In the bot Chrome DevTools console on the Amex tab, run:
#   delete window.scrollBy
# Then:
~/dotfiles/cards/bin/cards-keepalive.sh
tail -2 ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl
# Expected: amex dom-error event, NO Telegram (this kind is silent)

# Refresh the Amex tab to restore window.scrollBy.

# kind: config
chmod 000 ~/.claude/skills/credit-card-offers/state
~/dotfiles/cards/bin/cards-keepalive.sh
echo "exit: $?  (expected 1, error on stderr)"
chmod 755 ~/.claude/skills/credit-card-offers/state
```

Verify each transition is documented in the spec's §7.1 taxonomy and Rung 5 expected-outcome table.

- [ ] **Step 6: Rung 6 — Live bootstrap watch**

```bash
# Already bootstrapped in Task 14 — just verify
launchctl print gui/$(id -u)/com.pattybot.cards-keepalive | grep -E '^\s*(state|last exit|runs)'
tail -f ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl &
TAIL_PID=$!
sleep 1800   # watch for 30 min
kill $TAIL_PID 2>/dev/null
```

Expected: silent for 30 min unless something genuinely transitioned. If a Telegram fires during this window against a known-good session, abort and debug.

- [ ] **Step 7: Document validation results**

Append a note to the spec's `## 13. Definition of done` section (or a new `## 14. Validation results` section) recording: which rungs passed, any deviations from expected behavior, screenshots saved during failure injection. Commit with message `cards: record keepalive validation Rungs 1-6 results`.

---

## Self-review

Per the writing-plans skill, fresh-eyes review of the plan against the spec:

**1. Spec coverage**

Walking the spec section-by-section:
- §1 Purpose → covered by overall plan goal.
- §2 Priority ranking → encoded implicitly; D (simplicity) drives the "one script, no helpers split" choice in Tasks 1–9.
- §3 Constraints → respected throughout; reinforced in Task 13 (SKILL.md update).
- §4 Architecture → implemented in Tasks 1+9 (script structure), 10 (fire wrapper), 11 (plist).
- §5 Components → 5.1 keepalive script (Tasks 1–9), 5.2 fire mods (Task 10), 5.3 plist (Task 11), 5.4 state files (created at runtime by Tasks 7+9).
- §6 Data flow → all six sub-flows materialized by the main loop in Task 9.
- §7 Error handling → 7.1 taxonomy encoded in Tasks 3+9; 7.2 "what NOT to do" reflected in absence of retry/click/type code; 7.3 self-protection (no nav, no persistent socket) enforced in Tasks 6+9; 7.4 idempotency natural from Task 7 design; 7.5 file ownership reinforced by Task 13's SKILL.md note.
- §8 Testing → Tasks 2/3/4 cover Rung 3 selftest; Tasks 5/6/7/8/9 each have smoke tests; Task 15 runs Rungs 1–6 systematically.
- §9 What this design does NOT include → no tasks attempt these (no credential storage code, no MFA, no tab management, no Chrome restart, no adaptive cadence). Good.
- §10 Out-of-scope → no tasks venture into these.
- §11 Open implementation decisions → all 10 ODs are encoded as constants at the top of Task 1's script (OD1 INTERVAL implicit via plist StartInterval, OD2 JITTER_MAX_SEC, OD3-7 as constants, OD8 in state_diff_is_notifiable, OD9 in send_telegram_notify, OD10 in printf log format).
- §12 Linked files → all addressed by Tasks 1 (keepalive), 10 (fire), 11 (plist), 12 (CLAUDE.md), 13 (SKILL.md + runbook), and the prior spec commit covered .stow-local-ignore.
- §13 Definition of done → Task 14 (bootstrap) + Task 15 (validation Rungs 1–6) + Task 12/13 (docs).

No gaps.

**2. Placeholder scan**

No "TBD", "TODO", "fill in later" markers. Every code block contains the actual code to write. Every smoke test includes the exact command to run and the exact expected output (or "expected: matches §X of the spec").

**3. Type consistency**

Function names used across tasks:
- `cooldown_should_send` (defined Task 2, used Task 9) ✓
- `state_diff_is_notifiable` (defined Task 3, used Task 9) ✓
- `lock_is_stale` (defined Task 4, used Task 9) ✓
- `discover_tabs` (defined Task 5, used Task 9) ✓
- `probe_tab` / `probe_tab_to_state` (defined Task 6, used Task 9) ✓
- `last_state_for` / `append_event` / `cooldown_get` / `cooldown_set` (defined Task 7, used Task 9) ✓
- `capture_screenshot` / `send_telegram_notify` (defined Task 8, used Task 9) ✓
- `park_offers_tabs` (defined Task 10) ✓

Variable names: `EVENTS_FILE`, `COOLDOWN_FILE`, `LOCK_FILE`, `STATE_DIR`, `LOG_FILE`, `SCREENSHOT_DIR`, `TELEGRAM_HELPER`, `TELEGRAM_CHAT_ID`, `PYTHON_BIN`, `DAEMON_PORT`, `JITTER_MAX_SEC`, `STALE_LOCK_SEC`, `COOLDOWN_SEC`, `CDP_TIMEOUT_SEC` — all defined in Task 1 and used consistently throughout.

State enum (`unknown | authed | auth-wall | tab-missing | vis-error | daemon-down`) — used identically across spec §5.4, Task 3 (assertions), and Task 9 (main loop).

All consistent.

---

## Execution Handoff

Plan complete and saved to `cards/docs/superpowers/plans/2026-05-13-cards-session-keepalive.md`. 15 tasks, ~13 git commits.

Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for this plan because tasks are independent and each is naturally bounded (one helper function, one validation step).

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints. Slower per task but you watch the full flow.

Which approach?
