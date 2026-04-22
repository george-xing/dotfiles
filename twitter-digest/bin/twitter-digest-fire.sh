#!/bin/bash
# twitter-digest-fire.sh — launchd entry point for the twice-daily X digest.
#
# What this does:
#   1. Health-check the bot Chrome daemon on 127.0.0.1:9222 (12s retry window
#      with JSON parse validation, so we don't false-fail on a transient
#      KeepAlive respawn gap).
#   2. Invoke `claude -p` with the twitter-digest skill prompt.
#   3. Append a dated block to the log; exit non-zero on failure so launchd
#      surfaces it.
#
# What this deliberately doesn't do:
#   - Quit/launch Chrome. The bot Chrome is owned by launchctl
#     (com.pattybot.twitter-bot-chrome). We never touch it directly. Quitting
#     it would just trigger KeepAlive respawn and lose tab state.
#   - browser-use close --all. Same reason — the daemon Chrome's CDP session
#     must persist; the skill attaches via --cdp-url, doesn't spawn anything.
#   - `tell application "Google Chrome" to ...`. Two Chrome.app instances
#     are indistinguishable to bundle-name targeting; that command would
#     hit the wrong instance. We DO target by Unix ID via System Events
#     for the foreground activation below — that disambiguates.
#
# First-run note (TCC):
#   The pre-fire foreground step uses System Events. macOS's TCC requires
#   Automation permission for the calling process (bash, in launchd's
#   spawn) before scripting System Events succeeds. The first run will
#   produce a permission prompt visible to the user; granting it once
#   persists the permission. Activation calls are wrapped with
#   `with timeout of 5 seconds` so a hung prompt cannot block the wrapper
#   indefinitely (script silently skips activation if permission isn't
#   granted; the SKILL.md visibility check then hard-fails as before, so
#   no worse than today's behavior on TCC denial).
#
# Usage:
#   twitter-digest-fire.sh            # live — sends digest to Telegram
#   twitter-digest-fire.sh --dry-run  # composes digest, prints to log, no Telegram

set -uo pipefail

# Absolute paths baked at install time — launchd's default PATH is minimal.
CLAUDE_BIN="/Users/pattybot/.local/bin/claude"
BROWSER_USE_BIN="/Users/pattybot/.local/bin/browser-use"
NODE_BIN="/opt/homebrew/bin/node"
DAEMON_PORT=9222
DAEMON_URL="http://127.0.0.1:${DAEMON_PORT}/json/version"

# PATH covers the dirs the above binaries live in, plus the usual system dirs
# so anything the skill shells out to (curl, python3) is reachable.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/Users/pattybot/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export HOME="/Users/pattybot"

LOG="$HOME/Library/Logs/twitter-digest.log"
mkdir -p "$(dirname "$LOG")"

# Wait up to 12s (wall-clock) for the daemon Chrome to be reachable AND return
# a valid JSON /json/version response. KeepAlive can momentarily produce
# ECONNREFUSED during a respawn (e.g. Chrome auto-update); we don't want to
# fail on that. A parseable {"Browser": "..."} body is required — a 200 alone
# isn't enough.
#
# Deadline-based, not iteration-based: each curl can take up to 2s and we sleep
# 1s between attempts, so 12 attempts would be up to ~36s. We want a hard 12s
# ceiling so launchd doesn't see the wrapper hanging past its expected window.
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

{
  echo "===== fire $(date -Iseconds) ====="

  # Sanity: baked-in binaries still where we expect.
  for bin in "$CLAUDE_BIN" "$BROWSER_USE_BIN" "$NODE_BIN"; do
    if [ ! -x "$bin" ]; then
      echo "ERROR: missing binary $bin — reinstall or update wrapper paths" >&2
      exit 127
    fi
  done

  # Daemon health check. If the daemon isn't responding within 12s, abort —
  # don't waste a claude -p turn that will fail at step 2 anyway.
  if ! wait_for_daemon; then
    echo "ERROR: daemon Chrome at $DAEMON_URL not responding after 12s" >&2
    echo "  Check: launchctl print gui/\$(id -u)/com.pattybot.twitter-bot-chrome" >&2
    echo "  Logs:  ~/Library/Logs/twitter-bot-chrome.{out,err}.log" >&2
    exit 2
  fi

  # === Pre-fire: bring bot Chrome window to foreground ===
  #
  # Required because document.visibilityState only reports "visible" when
  # the OS-level window is actually frontmost (or at least not minimized
  # / hidden / on a different Space). The skill HARD-FAILS rather than
  # faking active state via CDP `setWebLifecycleState` — that mismatch is
  # itself a detection signal.
  #
  # Disambiguation: we have two Chrome.app instances (user's daily +
  # bot daemon). System Events is the only AppleScript path that targets
  # by Unix ID (PID), which uniquely identifies the bot regardless of
  # bundle name collision.

  # Save the prior frontmost app's PID for restore after the fire.
  # If TCC permission isn't granted yet, this returns empty silently
  # (the `try` swallows errors; the timeout caps the wait).
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

  # Find the bot Chrome MAIN process. Two filters in series:
  #   1. argv contains the bot's user-data-dir (excludes user's daily Chrome)
  #   2. argv lacks --type= (excludes renderer/gpu/utility helpers that
  #      inherit user-data-dir from the parent)
  #   3. process actually owns the LISTEN socket on 9222 (defends against
  #      stale instances or a respawned-but-different PID returned by pgrep
  #      before lsof's view catches up)
  BOT_CHROME_PID=""
  for pid in $(pgrep -u "$(id -u)" -f 'user-data-dir=.*twitter-bot-chrome' 2>/dev/null); do
    cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
    [ -n "$cmd" ] || continue
    [[ "$cmd" == *"--type="* ]] && continue
    if lsof -nP -p "$pid" -iTCP:${DAEMON_PORT} -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
      BOT_CHROME_PID="$pid"
      break
    fi
  done

  if [ -z "$BOT_CHROME_PID" ]; then
    echo "  pre-fire: WARN bot Chrome main PID not found; skipping activation"
    # Don't exit — daemon health check already passed, so something with
    # only-helpers-no-main is unexpected but the visibility check in
    # SKILL.md will surface it cleanly.
  else
    echo "  pre-fire: activating bot Chrome PID=$BOT_CHROME_PID, will restore frontmost PID=${SAVED_FRONTMOST_PID:-<unknown>}"

    # Un-minimize the bot Chrome window via CDP (no-op if already normal).
    # AppleScript's activate raises hidden apps but does NOT un-minimize
    # individual windows from the dock — CDP Browser.setWindowBounds does.
    #
    # Pin /usr/bin/python3 explicitly: the wrapper's PATH puts homebrew
    # first, where `python3` resolves to a different interpreter that
    # doesn't have websocket-client installed. The system python3 (3.9)
    # has it via user-site at ~/Library/Python/3.9/site-packages.
    #
    # Best-effort: skipped silently if websocket-client missing, the
    # CDP call errors, or there's no page target. Activation alone (below)
    # handles the common "behind another window" case; the un-minimize
    # is only needed for the "minimized to dock" case.
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
    # Iterate every page (a single bot Chrome can have multiple windows).
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

    # Activate by PID. `with timeout` caps the AppleEvent dispatch so a
    # hung TCC permission prompt can't block us indefinitely. `try` swallows
    # the timeout error — we proceed regardless, and the visibility check
    # in SKILL.md will hard-fail cleanly if activation didn't take.
    osascript <<OSA 2>/dev/null || true
try
  with timeout of 5 seconds
    tell application "System Events"
      set frontmost of (first process whose unix id is $BOT_CHROME_PID) to true
    end tell
  end timeout
end try
OSA

    # Bounded poll: wait up to 5s for the activation to actually settle.
    # Window activation is async on macOS; a fixed sleep is empirically thin
    # under load or during a Space-switch animation.
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
  fi

  # Explicit skill path in the prompt — under launchd with no interactive
  # context, name-based skill resolution is less deterministic than giving
  # `claude -p` the exact SKILL.md location to work from.
  SKILL_PATH="$HOME/.claude/skills/twitter-digest/SKILL.md"
  PROMPT="Run the twitter-digest skill defined in $SKILL_PATH — execute it as described there."
  if [[ "${1:-}" == "--dry-run" ]]; then
    PROMPT="Run the twitter-digest skill defined in $SKILL_PATH in dry-run mode — execute it as described there but skip the Telegram send and state-file writes."
  fi

  cd "$HOME"
  "$CLAUDE_BIN" -p "$PROMPT" --output-format text
  STATUS=$?

  # === Post-fire: restore prior frontmost app ===
  # Only restore if ALL three hold:
  #   1. We have a valid prior PID
  #   2. Prior PID isn't the bot Chrome itself (would be no-op)
  #   3. Bot Chrome is STILL frontmost — i.e. user hasn't manually switched
  #      to another app during the 5-8 min scrape. If they have, restoring
  #      would clobber their current focus choice.
  if [ -n "$SAVED_FRONTMOST_PID" ] && [ "$SAVED_FRONTMOST_PID" != "$BOT_CHROME_PID" ]; then
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

  echo "----- exit $STATUS at $(date -Iseconds) -----"
  exit $STATUS
} >> "$LOG" 2>&1
