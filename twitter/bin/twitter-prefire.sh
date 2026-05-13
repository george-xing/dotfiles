#!/bin/bash
# twitter-prefire.sh — OS plumbing for twitter-fire.sh.
#
# What this does:
#   1. Health-check the bot Chrome daemon on 127.0.0.1:9222.
#   2. lsof-disambiguate the bot Chrome's main PID.
#   3. CDP-unminimize all bot Chrome windows.
#   4. Pre-warm System Events.
#   5. PID-targeted System Events activate (30s timeout, diagnostic capture).
#   6. Bounded 5s poll waiting for activation to settle.
#
# What it doesn't do: invoke claude, send Telegram, restore prior frontmost.
# Those are twitter-fire.sh's job.
#
# Output contract:
#   - stdout/stderr: pre-fire log lines (caller will capture into its own log).
#   - Last stdout line: "SAVED_FRONTMOST_PID=<pid_or_empty>" — caller parses this
#     to know which app to restore after the fire.
#   - Exit codes:
#       0 — activation confirmed OR activation didn't settle (WARN logged)
#       2 — daemon Chrome at 9222 not responding within 12s

set -uo pipefail

DAEMON_PORT=9222
DAEMON_URL="http://127.0.0.1:${DAEMON_PORT}/json/version"

export PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

wait_for_daemon() {
  local deadline response
  deadline=$(( $(date +%s) + 12 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    response=$(curl -fsS --max-time 2 "$DAEMON_URL" 2>/dev/null) || { sleep 1; continue; }
    if echo "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "Browser" in d else 1)' 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! wait_for_daemon; then
  echo "ERROR: daemon Chrome at $DAEMON_URL not responding after 12s" >&2
  echo "  Check: launchctl print gui/\$(id -u)/com.pattybot.twitter-bot-chrome" >&2
  echo "  Logs:  ~/Library/Logs/twitter-bot-chrome.{out,err}.log" >&2
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

# Find the bot Chrome MAIN process via lsof on the 9222 LISTEN socket. The
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
UNMINIMIZE_RESULT=$(/usr/bin/python3 - <<'PY' 2>&1
import json, urllib.request, sys
try:
    import websocket
except ImportError:
    print("skip: websocket-client not installed in /usr/bin/python3"); sys.exit(0)
try:
    v = json.loads(urllib.request.urlopen("http://127.0.0.1:9222/json/version", timeout=3).read())
    tt = json.loads(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=3).read())
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

# Pre-warm System Events. From a launchd-spawned context, System Events isn't
# normally running — the first AppleEvent triggers macOS's on-demand auto-launch,
# and the subsequent real activation call races against that launch, failing
# with -1712 (AppleEvent timeout) or -609. A trivial pre-warm completes after
# the launch settles, so the real activation hits a warm process. On interactive
# runs System Events is already warm and the pre-warm is a sub-second no-op.
osascript >/dev/null 2>&1 <<'OSA' || true
with timeout of 10 seconds
  tell application "System Events" to return version
end timeout
OSA

# Activate by PID with diagnostic capture. Timeout is generous (30s, not 5s)
# because launchd-fired runs hit AppleEvent timeout (-1712) on every fire from
# 2026-05-01 to 2026-05-09 with the 5s budget. Interactive runs settle in
# under a second; only unattended ones hit the timeout.
OSASCRIPT_ERR_FILE=$(mktemp -t tw-prefire-osa.XXXXXX)
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
if [ "$OSASCRIPT_EXIT" -ne 0 ] || [ -n "$OSASCRIPT_ERR" ]; then
  echo "  pre-fire: osascript activation exit=$OSASCRIPT_EXIT stderr=${OSASCRIPT_ERR:-<empty>}"
fi

# Bounded 5s poll for activation to settle.
ACTIVATION_CONFIRMED=false
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
if [ "$ACTIVATION_CONFIRMED" = true ]; then
  echo "  pre-fire: activation confirmed (bot Chrome is frontmost)"
else
  echo "  pre-fire: WARN activation didn't settle within 5s; SKILL.md visibility check may hard-fail"
fi

echo "SAVED_FRONTMOST_PID=${SAVED_FRONTMOST_PID:-}"
exit 0
