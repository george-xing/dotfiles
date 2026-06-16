#!/bin/bash
# twitter-prefire.sh — OS plumbing for twitter-fire.sh.
#
# What this does:
#   1. Health-check the bot Chrome daemon on 127.0.0.1:9222.
#   2. lsof-disambiguate the bot Chrome's main PID.
#   3. Uptime-gated recycle: if the bot Chrome process has run longer than
#      BOT_CHROME_RECYCLE_AFTER_SECS (default 3d), launchctl bootout+bootstrap
#      it so the fire runs on a fresh, non-drifted process.
#   4. CDP-unminimize all bot Chrome windows.
#   5. Pre-warm System Events.
#   6. PID-targeted System Events activate (30s timeout, diagnostic capture).
#   7. Bounded 5s poll waiting for activation to settle.
#   8. Reactive recycle: if the window is still vis:hidden after activation and
#      we have NOT already recycled this run, recycle once (a fresh process
#      starts vis:visible).
#
# Why the recycle steps exist: a long-lived bot Chrome accumulates stuck
# window-occlusion state and begins reporting document.visibilityState:"hidden"
# even when nothing covers the window — empirically around 5 days of uptime.
# See project_twitter_digest_macmini_arch.md. Recycling well before that
# threshold keeps every fire on a clean process; X session cookies persist on
# disk in the profile dir, so the fresh Chrome stays signed in.
#
# What it doesn't do: invoke claude, send Telegram, restore prior frontmost.
# Those are twitter-fire.sh's job.
#
# Output contract:
#   - stdout/stderr: pre-fire log lines (caller will capture into its own log).
#   - "BOT_CHROME_PID=<pid_or_empty>" — the FINAL bot Chrome main PID (after any
#     recycle); caller parses this for its post-fire frontmost-restore logic.
#   - Last stdout line: "SAVED_FRONTMOST_PID=<pid_or_empty>" — caller parses this
#     to know which app to restore after the fire.
#   - Exit codes:
#       0 — activation confirmed OR activation didn't settle (WARN logged)
#       2 — daemon Chrome at 9222 not responding within 12s (incl. after a recycle)

set -uo pipefail

# launchd's default env is minimal; export HOME before referencing it.
export HOME="/Users/pattybot"
export PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

DAEMON_PORT=9222
DAEMON_URL="http://127.0.0.1:${DAEMON_PORT}/json/version"
BOT_CHROME_PLIST="$HOME/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist"

# Recycle the bot Chrome when its uptime exceeds this. Default 3 days — a safe
# margin under the ~5-day empirical occlusion-drift threshold. Overridable via
# env so the recycle path can be exercised in testing without waiting days.
BOT_CHROME_RECYCLE_AFTER_SECS="${BOT_CHROME_RECYCLE_AFTER_SECS:-$(( 3 * 86400 ))}"

BOT_CHROME_PID=""
RECYCLED=false

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

# Convert a ps etime string ([[DD-]HH:]MM:SS) to total seconds. Echoes the
# integer; returns non-zero (and echoes nothing) if it doesn't parse — callers
# treat an unparseable age as "unknown" and skip the recycle.
etime_to_secs() {
  local et="$1" days=0 hh=0 mm=0 rest
  [ -n "$et" ] || return 1
  if [[ "$et" == *-* ]]; then
    days="${et%%-*}"
    rest="${et#*-}"
  else
    rest="$et"
  fi
  local IFS=:
  local -a p=($rest)
  case ${#p[@]} in
    3) hh="${p[0]}"; mm="${p[1]}"; rest="${p[2]}" ;;
    2) mm="${p[0]}"; rest="${p[1]}" ;;
    *) return 1 ;;
  esac
  # 10# forces base-10 so zero-padded fields (e.g. "08") aren't read as octal.
  echo $(( 10#$days * 86400 + 10#$hh * 3600 + 10#$mm * 60 + 10#$rest ))
}

# Resolve the bot Chrome MAIN process via lsof on the 9222 LISTEN socket — the
# bound listener is always the main browser process, not a --type= helper.
# Sets the global BOT_CHROME_PID; returns non-zero if not found.
resolve_bot_chrome_pid() {
  local pid cmd
  BOT_CHROME_PID=""
  for pid in $(lsof -nP -iTCP:${DAEMON_PORT} -sTCP:LISTEN -t 2>/dev/null); do
    cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
    [ -n "$cmd" ] || continue
    if [[ "$cmd" != *"--type="* ]]; then
      BOT_CHROME_PID="$pid"
      return 0
    fi
  done
  return 1
}

# Probe document.visibilityState of the bot Chrome window via CDP. Echoes
# "visible", "hidden", or "unknown" (the last on any error — best-effort).
probe_visibility() {
  /usr/bin/python3 - <<'PY' 2>/dev/null
import json, urllib.request, sys
try:
    import websocket
except ImportError:
    print("unknown"); sys.exit(0)
try:
    tt = json.loads(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=3).read())
    pages = [t for t in tt if t.get("type") == "page"]
    if not pages:
        print("unknown"); sys.exit(0)
    states = []
    for page in pages:
        ws = websocket.create_connection(page["webSocketDebuggerUrl"], suppress_origin=True, timeout=3)
        ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                            "params": {"expression": "document.visibilityState", "returnByValue": True}}))
        while True:
            r = json.loads(ws.recv())
            if r.get("id") == 1:
                break
        ws.close()
        v = r.get("result", {}).get("result", {}).get("value")
        if v:
            states.append(v)
    print("visible" if "visible" in states else ("hidden" if "hidden" in states else "unknown"))
except Exception:
    print("unknown")
PY
}

# bootout + bootstrap the bot Chrome daemon for a fresh process. Session cookies
# live on disk in the profile dir, so the new Chrome stays signed in to X.
# Returns 0 once :9222 is responding again, non-zero otherwise.
recycle_bot_chrome() {
  local reason="${1:-recycle}" uid
  uid=$(id -u)
  echo "  pre-fire: recycling bot Chrome — ${reason}"
  if [ ! -f "$BOT_CHROME_PLIST" ]; then
    echo "  pre-fire: WARN bot-chrome plist missing at $BOT_CHROME_PLIST; cannot recycle"
    return 1
  fi
  launchctl bootout   "gui/${uid}" "$BOT_CHROME_PLIST" 2>/dev/null
  sleep 3
  launchctl bootstrap "gui/${uid}" "$BOT_CHROME_PLIST" 2>/dev/null
  if wait_for_daemon; then
    echo "  pre-fire: recycle complete — fresh bot Chrome up on :${DAEMON_PORT}"
    return 0
  fi
  echo "  pre-fire: WARN recycle — :${DAEMON_PORT} did not respond within 12s"
  return 1
}

activate_bot_chrome_pid() {
  local err_file osa_exit osa_err current_frontmost
  [ -n "$BOT_CHROME_PID" ] || {
    echo "  pre-fire: WARN bot Chrome PID empty; cannot activate"
    return 1
  }

  # Pre-warm System Events. From a launchd-spawned context, System Events isn't
  # normally running; the first AppleEvent can race against auto-launch.
  osascript >/dev/null 2>&1 <<'OSA' || true
with timeout of 10 seconds
  tell application "System Events" to return version
end timeout
OSA

  err_file=$(mktemp -t tw-prefire-osa.XXXXXX)
  osascript >/dev/null 2>"$err_file" <<OSA
with timeout of 30 seconds
  tell application "System Events"
    set frontmost of (first process whose unix id is $BOT_CHROME_PID) to true
  end tell
end timeout
OSA
  osa_exit=$?
  osa_err=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
  if [ "$osa_exit" -ne 0 ] || [ -n "$osa_err" ]; then
    echo "  pre-fire: osascript activation exit=$osa_exit stderr=${osa_err:-<empty>}"
  fi

  ACTIVATION_CONFIRMED=false
  for _ in 1 2 3 4 5; do
    current_frontmost=$(osascript <<OSA 2>/dev/null
try
  with timeout of 1 seconds
    tell application "System Events"
      return unix id of first application process whose frontmost is true
    end tell
  end timeout
end try
OSA
)
    if [ "$current_frontmost" = "$BOT_CHROME_PID" ]; then
      ACTIVATION_CONFIRMED=true
      break
    fi
    sleep 1
  done
  if [ "$ACTIVATION_CONFIRMED" = true ]; then
    echo "  pre-fire: activation confirmed (bot Chrome is frontmost)"
    return 0
  fi
  echo "  pre-fire: WARN activation didn't settle within 5s; SKILL.md visibility check may hard-fail"
  return 1
}

# ---- main ----------------------------------------------------------------

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

if ! resolve_bot_chrome_pid; then
  echo "  pre-fire: WARN bot Chrome main PID not found; skipping activation"
  echo "BOT_CHROME_PID="
  echo "SAVED_FRONTMOST_PID=${SAVED_FRONTMOST_PID:-}"
  exit 0
fi

# Uptime-gated recycle. A bot Chrome process past the occlusion-drift threshold
# reports vis:hidden even when nothing covers it; recycle for a fresh process
# before that can happen.
CHROME_ETIME=$(ps -p "$BOT_CHROME_PID" -o etime= 2>/dev/null | tr -d ' ')
CHROME_AGE_SECS=$(etime_to_secs "$CHROME_ETIME" || true)
if [[ "$CHROME_AGE_SECS" =~ ^[0-9]+$ ]] && [ "$CHROME_AGE_SECS" -gt "$BOT_CHROME_RECYCLE_AFTER_SECS" ]; then
  echo "  pre-fire: bot Chrome uptime ${CHROME_AGE_SECS}s exceeds ${BOT_CHROME_RECYCLE_AFTER_SECS}s threshold"
  if recycle_bot_chrome "uptime ${CHROME_AGE_SECS}s > ${BOT_CHROME_RECYCLE_AFTER_SECS}s threshold"; then
    RECYCLED=true
    resolve_bot_chrome_pid || echo "  pre-fire: WARN bot Chrome PID not found after recycle"
  else
    echo "ERROR: bot Chrome recycle failed; daemon may be down" >&2
    exit 2
  fi
else
  echo "  pre-fire: bot Chrome uptime ${CHROME_AGE_SECS:-unknown}s (under ${BOT_CHROME_RECYCLE_AFTER_SECS}s threshold; no recycle)"
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

# Activate by PID with diagnostic capture. Timeout is generous (30s, not 5s)
# because launchd-fired runs historically hit AppleEvent timeouts with shorter
# budgets.
activate_bot_chrome_pid || true

# Reactive recycle. If we already recycled on the uptime gate the process is
# fresh — just log its visibility. Otherwise, if the window is still hidden
# after activation, the process may have drifted faster than the uptime gate
# expects: recycle once (a fresh process starts vis:visible).
if [ "$RECYCLED" = true ]; then
  echo "  pre-fire: visibilityState after recycle: $(probe_visibility)"
else
  VIS=$(probe_visibility)
  if [ "$VIS" = "hidden" ]; then
    echo "  pre-fire: visibilityState=hidden after activation — reactive recycle"
    if recycle_bot_chrome "reactive: vis=hidden below uptime threshold"; then
      RECYCLED=true
      resolve_bot_chrome_pid || echo "  pre-fire: WARN bot Chrome PID not found after reactive recycle"
      echo "  pre-fire: activating recycled bot Chrome PID=${BOT_CHROME_PID:-<unknown>}"
      activate_bot_chrome_pid || true
      echo "  pre-fire: visibilityState after reactive recycle: $(probe_visibility)"
    else
      echo "ERROR: bot Chrome reactive recycle failed; daemon may be down" >&2
      exit 2
    fi
  else
    echo "  pre-fire: visibilityState check: ${VIS}"
  fi
fi

echo "BOT_CHROME_PID=${BOT_CHROME_PID:-}"
echo "SAVED_FRONTMOST_PID=${SAVED_FRONTMOST_PID:-}"
exit 0
