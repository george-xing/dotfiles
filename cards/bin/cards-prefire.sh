#!/bin/bash
# cards-prefire.sh — OS plumbing for cards-fire.sh.
#
# Direct mirror of twitter-prefire.sh — same six-step contract, only the
# daemon port (19223) and labels differ. Steps:
#   1. Health-check the bot Chrome daemon on 127.0.0.1:19223.
#   2. lsof-disambiguate the bot Chrome's main PID (vs --type= helpers).
#   3. CDP-unminimize all bot Chrome windows.
#   4. Pre-warm System Events (eliminates AppleEvent timeout race on
#      cold launchd-spawned fires; no-op on interactive runs).
#   5. PID-targeted System Events activate (30s timeout, diagnostic capture).
#   6. Bounded 5s poll waiting for activation to settle.
#
# What it doesn't do: invoke Codex, send Telegram, restore prior frontmost.
# Those are cards-fire.sh's job.
#
# Output contract:
#   - stdout/stderr: pre-fire log lines (caller will capture into its own log).
#   - Last stdout line: "SAVED_FRONTMOST_PID=<pid_or_empty>" — caller parses
#     this to know which app to restore after the fire.
#   - Exit codes:
#       0 — activation confirmed OR activation didn't settle (WARN logged)
#       2 — daemon Chrome at 19223 not responding within 12s

set -uo pipefail

DAEMON_PORT=19223
DAEMON_URL="http://127.0.0.1:${DAEMON_PORT}/json/version"
CUA_DRIVER_BIN="${CUA_DRIVER_BIN:-/Users/pattybot/.local/bin/cua-driver}"
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
  echo "  Check: launchctl print gui/\$(id -u)/com.pattybot.cards-bot-chrome" >&2
  echo "  Logs:  ~/Library/Logs/cards-bot-chrome.{out,err}.log" >&2
  exit 2
fi

# Capture prior frontmost so the orchestrator can restore it after the fire.
SAVED_FRONTMOST_PID=$(osascript <<'OSA' 2>/dev/null || true
try
  with timeout of 3 seconds
    tell application "System Events"
      return unix id of first application process whose frontmost is true
    end tell
  end timeout
end try
OSA
)

# Find the bot Chrome MAIN process via lsof on the 19223 LISTEN socket. The
# bound listener is always the main browser process, not a --type= helper.
BOT_CHROME_PID=""
for pid in $(lsof -nP -iTCP:${DAEMON_PORT} -sTCP:LISTEN -t 2>/dev/null); do
  cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
  [ -n "$cmd" ] || continue
  if [[ "$cmd" != *"--type="* ]]; then
    BOT_CHROME_PID="$pid"
    break
  fi
done

if [ -z "$BOT_CHROME_PID" ]; then
  echo "  pre-fire: WARN bot Chrome main PID not found; skipping activation"
  echo "SAVED_FRONTMOST_PID=${SAVED_FRONTMOST_PID:-}"
  exit 0
fi

echo "  pre-fire: activating bot Chrome PID=$BOT_CHROME_PID, will restore frontmost PID=${SAVED_FRONTMOST_PID:-<unknown>}"

# Un-minimize bot Chrome windows via CDP. Pin /usr/bin/python3 (has
# websocket-client via user-site); homebrew python3 typically doesn't.
# Best-effort: skipped silently if missing module or no page targets.
UNMINIMIZE_RESULT=$(DAEMON_PORT="$DAEMON_PORT" "$PYTHON_BIN" - <<'PY' 2>&1
import json, os, urllib.request, sys
try:
    import websocket
except ImportError:
    print("skip: websocket-client not installed in /usr/bin/python3"); sys.exit(0)
port = os.environ["DAEMON_PORT"]
try:
    v = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=3).read())
    tt = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=3).read())
    pages = [t for t in tt if t.get("type") == "page"]
    if not pages:
        print("skip: no page targets"); sys.exit(0)
    ws = websocket.create_connection(v["webSocketDebuggerUrl"], suppress_origin=True, timeout=3)
    def call(id_, method, params):
        ws.send(json.dumps({"id": id_, "method": method, "params": params}))
        while True:
            r = json.loads(ws.recv())
            if r.get("id") == id_:
                return r
    seen_windows = set()
    for page in pages:
        r = call(len(seen_windows)*2+1, "Browser.getWindowForTarget", {"targetId": page["id"]})
        if "result" not in r: continue
        wid = r["result"]["windowId"]
        if wid in seen_windows: continue
        seen_windows.add(wid)
        call(len(seen_windows)*2, "Browser.setWindowBounds", {"windowId": wid, "bounds": {"windowState": "normal"}})
    ws.close()
    print(f"un-minimized {len(seen_windows)} window(s)")
except Exception as e:
    print(f"skip: {e}")
PY
)
echo "  pre-fire: cdp un-minimize: $UNMINIMIZE_RESULT"

# Pre-warm System Events. From a launchd-spawned context System Events isn't
# normally running — the first AppleEvent triggers macOS's on-demand auto-launch,
# and the subsequent activation call races against that launch, failing with
# -1712 (AppleEvent timeout) or -609. A trivial pre-warm completes after the
# launch settles, so the real activation hits a warm process. Interactive runs
# already have System Events warm; the pre-warm is a sub-second no-op there.
osascript >/dev/null 2>&1 <<'OSA' || true
with timeout of 10 seconds
  tell application "System Events" to return version
end timeout
OSA

# Activate by PID with diagnostic capture. Timeout is 30s (not 5s) because
# cold launchd fires hit AppleEvent timeout (-1712) with smaller budgets
# (the May 2026 twitter incident series confirmed this).
if [ "${CARDS_PREFIRE_FORCE_CUA:-0}" = "1" ]; then
  OSASCRIPT_EXIT=1
  OSASCRIPT_ERR="skipped by CARDS_PREFIRE_FORCE_CUA test hook"
else
  OSASCRIPT_ERR_FILE=$(mktemp -t cards-prefire-osa.XXXXXX)
  osascript >/dev/null 2>"$OSASCRIPT_ERR_FILE" <<OSA
with timeout of 30 seconds
  tell application "System Events"
    set frontmost of (first process whose unix id is $BOT_CHROME_PID) to true
  end tell
end timeout
OSA
  OSASCRIPT_EXIT=$?
  OSASCRIPT_ERR=$(cat "$OSASCRIPT_ERR_FILE" 2>/dev/null || true)
  rm -f "$OSASCRIPT_ERR_FILE"
fi
if [ "$OSASCRIPT_EXIT" -ne 0 ] || [ -n "$OSASCRIPT_ERR" ]; then
  echo "  pre-fire: osascript activation exit=$OSASCRIPT_EXIT stderr=${OSASCRIPT_ERR:-<empty>}"
fi

# Bounded 5s poll for activation to settle.
ACTIVATION_CONFIRMED=false
if [ "${CARDS_PREFIRE_FORCE_CUA:-0}" != "1" ]; then
  for _ in 1 2 3 4 5; do
    CURRENT_FRONTMOST=$(osascript <<OSA 2>/dev/null
try
  with timeout of 1 seconds
    tell application "System Events"
      return unix id of first application process whose frontmost is true
    end tell
  end timeout
end try
OSA
)
    if [ "$CURRENT_FRONTMOST" = "$BOT_CHROME_PID" ]; then
      ACTIVATION_CONFIRMED=true
      break
    fi
    sleep 1
  done
fi
if [ "$ACTIVATION_CONFIRMED" = true ]; then
  echo "  pre-fire: activation confirmed (bot Chrome is frontmost)"
else
  echo "  pre-fire: System Events activation didn't settle; trying CuaDriver fallback"

  if [ -x "$CUA_DRIVER_BIN" ]; then
    if ! "$CUA_DRIVER_BIN" status >/dev/null 2>&1; then
      /usr/bin/open -n -g -a CuaDriver --args serve >/dev/null 2>&1 || true
      for _ in 1 2 3 4 5; do
        "$CUA_DRIVER_BIN" status >/dev/null 2>&1 && break
        sleep 1
      done
    fi

    CUA_SCALE=$(
      "$CUA_DRIVER_BIN" call get_screen_size '{}' 2>/dev/null |
        "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("scale_factor", 1.0))' 2>/dev/null
    )
    CUA_WINDOWS=$("$CUA_DRIVER_BIN" call list_windows "{\"pid\":${BOT_CHROME_PID}}" 2>/dev/null)
    CUA_WINDOW_META=$(
      printf '%s' "$CUA_WINDOWS" |
        "$PYTHON_BIN" -c '
import json, sys
scale = float(sys.argv[1] or 1)
data = json.load(sys.stdin)
windows = [
    w for w in data.get("windows", [])
    if w.get("is_on_screen")
    and w.get("bounds", {}).get("width", 0) > 400
    and w.get("bounds", {}).get("height", 0) > 300
]
if windows:
    w = max(windows, key=lambda x: x["bounds"]["width"] * x["bounds"]["height"])
    b = w["bounds"]
    print(w["window_id"], round((b["x"] + 40) * scale), round((b["y"] + 20) * scale))
' "${CUA_SCALE:-1}" 2>/dev/null
    )
    read -r CUA_WINDOW_ID CUA_CLICK_X CUA_CLICK_Y <<< "${CUA_WINDOW_META:-}"

    CUA_EXIT=1
    if [ -n "${CUA_WINDOW_ID:-}" ] && [ -n "${CUA_CLICK_X:-}" ] && [ -n "${CUA_CLICK_Y:-}" ]; then
      CUA_RESULT=$(
        "$CUA_DRIVER_BIN" call bring_to_front \
          "{\"pid\":${BOT_CHROME_PID},\"window_id\":${CUA_WINDOW_ID}}" 2>&1
      )
      CUA_EXIT=$?
      if [ "$CUA_EXIT" -eq 0 ]; then
        "$CUA_DRIVER_BIN" call click \
          "{\"scope\":\"desktop\",\"x\":${CUA_CLICK_X},\"y\":${CUA_CLICK_Y}}" \
          >/dev/null 2>&1
        CUA_EXIT=$?
      fi
      echo "  pre-fire: CuaDriver foreground window=$CUA_WINDOW_ID click=${CUA_CLICK_X},${CUA_CLICK_Y} exit=$CUA_EXIT result=${CUA_RESULT:-<empty>}"
    else
      echo "  pre-fire: CuaDriver could not resolve a visible bot Chrome window"
    fi

    if [ "$CUA_EXIT" -eq 0 ]; then
      sleep 1
      CDP_VIS=$(
        DAEMON_PORT="$DAEMON_PORT" "$PYTHON_BIN" -c '
import json, os, sys, urllib.request
try:
    import websocket
    targets = json.loads(urllib.request.urlopen(
        "http://127.0.0.1:{}/json".format(os.environ.get("DAEMON_PORT")), timeout=3
    ).read())
    target = next(t for t in targets if t.get("type") == "page")
    ws = websocket.create_connection(target["webSocketDebuggerUrl"], suppress_origin=True, timeout=3)
    ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": "document.visibilityState"}}))
    while True:
        reply = json.loads(ws.recv())
        if reply.get("id") == 1:
            print(reply["result"]["result"].get("value", "unknown"))
            break
    ws.close()
except Exception:
    print("unknown")
' 2>/dev/null
      )
      if [ "$CDP_VIS" = "visible" ] || [ "$CDP_VIS" = "unknown" ]; then
        ACTIVATION_CONFIRMED=true
      fi
      echo "  pre-fire: post-CuaDriver CDP visibility=${CDP_VIS:-unknown}"
    fi
  fi

  if [ "$ACTIVATION_CONFIRMED" = true ]; then
    echo "  pre-fire: activation confirmed through CuaDriver fallback"
  else
    echo "  pre-fire: WARN activation still failed; issuer DOM checks may be unreliable"
  fi
fi

echo "SAVED_FRONTMOST_PID=${SAVED_FRONTMOST_PID:-}"
exit 0
