# Twitter Bookmarks + Shared-Infra Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add on-demand X bookmark summarization triggered from Telegram, reusing the existing twitter-digest anti-bot Chrome infrastructure. Refactor along the way so both skills share genuinely-duplicated infrastructure (OS-plumbing wrapper, Telegram send, dedup append) without coupling workflow logic.

**Architecture:** Stow package `twitter-digest/` is renamed to `twitter/`. The existing 333-line `twitter-digest-fire.sh` is split into `twitter-prefire.sh` (OS plumbing) + `twitter-fire.sh <skill-name>` (orchestrator with flock). Two shared bash helpers (`bin/lib/telegram-send.sh`, `bin/lib/dedup-append.sh`) hold the curl-pattern and dedup logic both skills use. A new `twitter-bookmarks` skill scrapes `x.com/i/bookmarks`; a new `twitter-bookmarks-dispatch` skill activates in the paired Claude Code session on Telegram trigger phrases and launches a background `Agent` to run the scrape.

**Tech Stack:** bash, macOS launchd plists, AppleScript via osascript (System Events), CDP (Chrome DevTools Protocol) via browser-use + websocket-client, curl for Telegram delivery, `flock` for bot-Chrome mutex, Telegram MCP plugin's `reply` tool for the dispatch path, Anthropic `Agent` tool with `run_in_background: true` for fire-and-forget background work.

**Validation philosophy:** This codebase has no automated test suite (per CLAUDE.md: "no build, lint, or test step"). The TDD discipline adapts to: "define the manual gate command + expected output → verify the gap exists → make the change → re-verify against the same command → commit." Each task has explicit gates.

---

## File Structure

**Renamed:**
- `~/dotfiles/twitter-digest/` → `~/dotfiles/twitter/`

**Created:**
- `~/dotfiles/twitter/bin/twitter-prefire.sh` — OS plumbing only (~210 lines extracted from existing wrapper)
- `~/dotfiles/twitter/bin/twitter-fire.sh` — orchestrator that takes `<skill-name>`, acquires flock, calls prefire, runs `claude -p`, restores frontmost (~90 lines new)
- `~/dotfiles/twitter/bin/lib/telegram-send.sh` — hardened curl wrapper (~75 lines new)
- `~/dotfiles/twitter/bin/lib/dedup-append.sh` — atomic JSON array append (~50 lines new)
- `~/dotfiles/twitter/.claude/skills/twitter-bookmarks/SKILL.md` — bookmark scrape workflow (~350 lines, modeled on digest)
- `~/dotfiles/twitter/.claude/skills/twitter-bookmarks/references/runbook.md` — operational notes (~80 lines)
- `~/dotfiles/twitter/.claude/skills/twitter-bookmarks-dispatch/SKILL.md` — paired-session DM→subagent dispatcher (~60 lines)

**Renamed (preserved as rollback escape hatch):**
- `bin/twitter-digest-fire.sh` → `bin/twitter-digest-fire.legacy.sh` (deletable after one week of clean Phase A fires)

**Modified:**
- `~/dotfiles/twitter/Library/LaunchAgents/com.pattybot.twitter-digest.plist` — `ProgramArguments` to call `twitter-fire.sh twitter-digest`
- `~/dotfiles/twitter/.claude/skills/twitter-digest/SKILL.md` — replace inline Telegram curl + dedup append with helper-script calls
- `~/dotfiles/twitter/CLAUDE.md` — updated paths after rename + dual-skill description
- `~/dotfiles/twitter/.claude/skills/twitter-digest/references/runbook.md` — updated paths and log file name

---

## Pre-flight

### Task P.1: Commit or stash existing WIP

The repo currently has uncommitted modifications to `twitter-digest/bin/twitter-digest-fire.sh` (+57/-14) and `twitter-digest/.claude/skills/twitter-digest/SKILL.md` (+70/-17). These files are about to be refactored. The WIP must land first so the refactor is a clean diff on a known base.

**Files:**
- Inspect: `~/dotfiles/twitter-digest/bin/twitter-digest-fire.sh`
- Inspect: `~/dotfiles/twitter-digest/.claude/skills/twitter-digest/SKILL.md`

- [ ] **Step 1: View current WIP and decide**

```bash
cd ~/dotfiles
git diff --stat HEAD -- twitter-digest/
git diff HEAD -- twitter-digest/ | head -200
```

Decide with the operator: commit as-is, or stash. **Default is commit** — the WIP looks like System Events activation hardening (pre-warm + diagnostic capture + timeout bump from 5s→30s), which is exactly the kind of fix that should land before a refactor uses this code as its base.

- [ ] **Step 2: Commit WIP (default path)**

```bash
cd ~/dotfiles
git add twitter-digest/bin/twitter-digest-fire.sh twitter-digest/.claude/skills/twitter-digest/SKILL.md
git commit -m "$(cat <<'EOF'
twitter-digest: wip hardening before bookmarks refactor

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Confirm clean state**

Run: `cd ~/dotfiles && git status --short`
Expected: empty output (no modified or untracked files in `twitter-digest/`).

---

## Phase 0 — Rename stow package

### Task 0.1: Rename `twitter-digest/` → `twitter/` and re-stow

The stow package name appears in:
- The on-disk directory: `~/dotfiles/twitter-digest/`
- CLAUDE.md prose throughout (paths, commands)
- Internal references in `references/runbook.md`
- The stow command `stow -t ~ -R twitter-digest`

The renamed dir's contents (`bin/`, `Library/`, `.claude/`) keep mirroring back to the same `$HOME` paths because stow looks at directory structure under the package root, not the package name. So `~/Library/LaunchAgents/com.pattybot.twitter-digest.plist` and `~/bin/twitter-digest-fire.sh` paths are unaffected by this rename.

**Files:**
- Rename: `~/dotfiles/twitter-digest/` → `~/dotfiles/twitter/`
- Modify: `~/dotfiles/twitter/CLAUDE.md`
- Modify: `~/dotfiles/twitter/.claude/skills/twitter-digest/references/runbook.md` (only if it references "twitter-digest/" package paths — most refs are to `~/...` targets, not repo-internal)

- [ ] **Step 1: Define the manual gate (pre-state)**

Run: `ls -la ~/bin/twitter-digest-fire.sh ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist`

Expected: both symlinks resolve into `~/dotfiles/twitter-digest/...` (note the source path inside the symlink target).

- [ ] **Step 2: Un-stow old, rename, re-stow**

```bash
cd ~/dotfiles
stow -t ~ -D twitter-digest         # remove old symlinks
git mv twitter-digest twitter       # rename + git history preserved
stow -t ~ -R twitter                # create new symlinks
```

- [ ] **Step 3: Verify symlinks now point inside `twitter/`**

Run: `ls -la ~/bin/twitter-digest-fire.sh ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist`
Expected: both symlinks resolve into `~/dotfiles/twitter/...` (same files via a different package path).

Run: `~/bin/twitter-digest-fire.sh --dry-run 2>&1 | tail -3`
Expected: log block ending with `----- exit 0 -----` (the existing wrapper still works pre-refactor; this validates the rename didn't break anything).

- [ ] **Step 4: Update CLAUDE.md package-name references**

```bash
sed -i '' 's|twitter-digest/|twitter/|g; s|stow -t ~ -R twitter-digest|stow -t ~ -R twitter|g' ~/dotfiles/twitter/CLAUDE.md
```

Re-read it manually to spot any false-positives where "twitter-digest" was the skill name not the package name. The skill is still named `twitter-digest` — DO NOT rename the skill. Only the stow package.

Re-read the file at `~/dotfiles/twitter/CLAUDE.md` end-to-end and hand-fix any prose that needs to distinguish "the twitter package" (now containing both skills) from "the twitter-digest skill" (still its own skill).

- [ ] **Step 5: Commit the rename**

```bash
cd ~/dotfiles
git add -A
git status --short
```
Expected output (shape, not exact paths): a long list of `R  twitter-digest/... -> twitter/...` and one `M twitter/CLAUDE.md`.

```bash
git commit -m "$(cat <<'EOF'
twitter: rename stow package from twitter-digest to twitter

Prep for adding the twitter-bookmarks skill alongside twitter-digest.
Stow targets unchanged ($HOME path) — only the dotfiles-side dir name.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: Confirm digest still fires after rename**

Run: `~/bin/twitter-digest-fire.sh --dry-run 2>&1 | tail -10`
Expected: `pre-fire: activation confirmed` line, no errors, `----- exit 0 -----`.

If this fails: the rename broke something. Investigate before continuing.

---

## Phase A — Prefire/fire split

### Task A.1: Create `bin/twitter-prefire.sh`

Extract the foreground/TCC/un-minimize block (lines ~99-282 of the existing wrapper) into a standalone script. It performs daemon health check, lsof PID disambiguation, CDP un-minimize, System Events pre-warm + activate, and bounded activation-settle poll. Exits 0 if activation confirmed (or with WARN if it didn't settle), exit 2 if daemon health check failed. **Does NOT** invoke `claude`, send Telegram, or restore prior frontmost.

The `SAVED_FRONTMOST_PID` capture also lives here, but the script needs a way to communicate that PID back to `twitter-fire.sh` for post-fire restore. We do this via stdout: the script's last line is `SAVED_FRONTMOST_PID=<pid>` which `twitter-fire.sh` greps.

**Files:**
- Create: `~/dotfiles/twitter/bin/twitter-prefire.sh`

- [ ] **Step 1: Write the new script**

Create `~/dotfiles/twitter/bin/twitter-prefire.sh` with this exact content:

```bash
#!/bin/bash
# twitter-prefire.sh — OS plumbing for twitter-fire.sh.
#
# What this does:
#   1. Health-check the bot Chrome daemon on 127.0.0.1:9222.
#   2. lsof-disambiguate the bot Chrome's main PID.
#   3. CDP-unminimize all bot Chrome windows.
#   4. Pre-warm System Events.
#   5. PID-targeted System Events activate.
#   6. Bounded 5s poll waiting for activation to settle.
#
# What it doesn't do: invoke claude, send Telegram, restore prior frontmost.
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

osascript >/dev/null 2>&1 <<'OSA' || true
with timeout of 10 seconds
  tell application "System Events" to return version
end timeout
OSA

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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x ~/dotfiles/twitter/bin/twitter-prefire.sh
```

- [ ] **Step 3: Manual gate — run prefire standalone**

Run: `~/dotfiles/twitter/bin/twitter-prefire.sh`
Expected: log lines including `pre-fire: activating bot Chrome PID=<pid>`, `pre-fire: cdp un-minimize: ...`, `pre-fire: activation confirmed`, last line `SAVED_FRONTMOST_PID=<pid_or_empty>`. Exit 0.

- [ ] **Step 4: Commit**

```bash
cd ~/dotfiles
git add twitter/bin/twitter-prefire.sh
git commit -m "$(cat <<'EOF'
twitter: extract twitter-prefire.sh from fire wrapper

OS plumbing only: daemon health check, lsof PID disambiguation, CDP
un-minimize, System Events pre-warm + activate, bounded settle poll.
Communicates prior frontmost PID via final stdout line for the
orchestrator's post-fire restore.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task A.2: Create `bin/twitter-fire.sh`

The new orchestrator. Takes `<skill-name>` as first arg, optional `--dry-run` as second. Acquires the shared flock, calls prefire, parses `SAVED_FRONTMOST_PID` from prefire stdout, invokes `claude -p`, restores frontmost if bot Chrome still frontmost, exits with claude's exit code.

**Files:**
- Create: `~/dotfiles/twitter/bin/twitter-fire.sh`

- [ ] **Step 1: Write the new script**

Create `~/dotfiles/twitter/bin/twitter-fire.sh` with this content:

```bash
#!/bin/bash
# twitter-fire.sh — orchestrator for a single fire of one twitter skill.
#
# Usage:
#   twitter-fire.sh <skill-name>            # live fire
#   twitter-fire.sh <skill-name> --dry-run  # dry-run mode

set -uo pipefail

export HOME="/Users/pattybot"
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/pattybot/.local/bin:/Users/pattybot/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

CLAUDE_BIN="/Users/pattybot/.local/bin/claude"
BROWSER_USE_BIN="/Users/pattybot/.local/bin/browser-use"
NODE_BIN="/opt/homebrew/bin/node"
PREFIRE_BIN="$(dirname "$(realpath "$0")")/twitter-prefire.sh"
LOCK_FILE="$HOME/.claude/skills/.twitter-fire.lock"

LOG="$HOME/Library/Logs/twitter-fire.log"
mkdir -p "$(dirname "$LOG")"

SKILL_NAME="${1:-}"
DRY_RUN_FLAG="${2:-}"

if [ -z "$SKILL_NAME" ]; then
  echo "usage: twitter-fire.sh <skill-name> [--dry-run]" >&2
  exit 64
fi

SKILL_PATH="$HOME/.claude/skills/${SKILL_NAME}/SKILL.md"
if [ ! -f "$SKILL_PATH" ]; then
  echo "ERROR: skill not found at $SKILL_PATH" >&2
  exit 65
fi

for bin in "$CLAUDE_BIN" "$BROWSER_USE_BIN" "$NODE_BIN" "$PREFIRE_BIN"; do
  if [ ! -x "$bin" ]; then
    echo "ERROR: missing binary $bin — reinstall or update wrapper paths" >&2
    exit 127
  fi
done

mkdir -p "$(dirname "$LOCK_FILE")"

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  HOLDER_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "?")
  mkdir -p "$HOME/.claude/skills/${SKILL_NAME}/state" 2>/dev/null || true
  echo "{\"kind\":\"busy\",\"at\":\"$(date -Iseconds)\",\"message\":\"another twitter-fire in progress (PID $HOLDER_PID)\"}" \
    > "$HOME/.claude/skills/${SKILL_NAME}/state/last-failure.json" 2>/dev/null || true
  {
    echo "===== fire $(date -Iseconds) skill=${SKILL_NAME} BUSY ====="
    echo "  another twitter-fire is holding the lock; holder PID=$HOLDER_PID"
    echo "----- exit 3 at $(date -Iseconds) -----"
  } >> "$LOG"
  exit 3
fi
echo $$ > "$LOCK_FILE"

{
  echo "===== fire $(date -Iseconds) skill=${SKILL_NAME} ====="

  PREFIRE_OUT=$("$PREFIRE_BIN" 2>&1)
  PREFIRE_EXIT=$?
  echo "$PREFIRE_OUT"
  if [ "$PREFIRE_EXIT" -ne 0 ]; then
    echo "----- exit $PREFIRE_EXIT (prefire failed) at $(date -Iseconds) -----"
    exit $PREFIRE_EXIT
  fi

  SAVED_FRONTMOST_PID=$(echo "$PREFIRE_OUT" | grep '^SAVED_FRONTMOST_PID=' | tail -1 | cut -d= -f2)
  BOT_CHROME_PID=$(echo "$PREFIRE_OUT" | grep -oE 'activating bot Chrome PID=[0-9]+' | head -1 | cut -d= -f2)

  if [[ "$DRY_RUN_FLAG" == "--dry-run" ]]; then
    PROMPT="Run the ${SKILL_NAME} skill defined in $SKILL_PATH in dry-run mode — execute it as described there but skip the Telegram send and state-file writes."
  else
    PROMPT="Run the ${SKILL_NAME} skill defined in $SKILL_PATH — execute it as described there."
  fi

  cd "$HOME"
  "$CLAUDE_BIN" -p "$PROMPT" --output-format text
  STATUS=$?

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

  echo "----- exit $STATUS at $(date -Iseconds) -----"
  exit $STATUS
} >> "$LOG" 2>&1
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x ~/dotfiles/twitter/bin/twitter-fire.sh
```

- [ ] **Step 3: Manual gate — dry-run against existing digest skill**

Run: `~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest --dry-run`

Expected: exit 0. Tail the log:
```bash
tail -30 ~/Library/Logs/twitter-fire.log
```
Expected lines: `===== fire <iso> skill=twitter-digest =====`, `pre-fire: activation confirmed`, claude's dry-run skill output, `----- exit 0 -----`.

- [ ] **Step 4: Manual gate — flock contention test**

Terminal 1: `~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest --dry-run` (let run).
Terminal 2: `~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest --dry-run; echo "exit=$?"`.
Expected: terminal 2 exits 3 immediately, log shows `BUSY` block.

- [ ] **Step 5: Commit**

```bash
cd ~/dotfiles
git add twitter/bin/twitter-fire.sh
git commit -m "$(cat <<'EOF'
twitter: add twitter-fire.sh orchestrator

Takes <skill-name> + optional --dry-run, acquires shared flock on
~/.claude/skills/.twitter-fire.lock to prevent bot Chrome contention,
calls twitter-prefire.sh, runs claude -p against the named skill,
restores prior frontmost if bot Chrome is still frontmost. Exits 3
on flock conflict.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task A.3: Rename legacy wrapper + update plist + reload + smoke test

The plist's `ProgramArguments` currently points at `/Users/pattybot/bin/twitter-digest-fire.sh`. Rename the source file to `twitter-digest-fire.legacy.sh`, point the plist at the new wrapper, reload.

**Files:**
- Rename: `~/dotfiles/twitter/bin/twitter-digest-fire.sh` → `~/dotfiles/twitter/bin/twitter-digest-fire.legacy.sh`
- Modify: `~/dotfiles/twitter/Library/LaunchAgents/com.pattybot.twitter-digest.plist`

- [ ] **Step 1: Rename legacy wrapper**

```bash
cd ~/dotfiles
git mv twitter/bin/twitter-digest-fire.sh twitter/bin/twitter-digest-fire.legacy.sh
```

- [ ] **Step 2: Re-stow**

```bash
cd ~/dotfiles
stow -t ~ -R twitter
ls -la ~/bin/twitter-digest-fire*
```
Expected: `~/bin/twitter-digest-fire.sh` is gone; `~/bin/twitter-digest-fire.legacy.sh` resolves into `~/dotfiles/twitter/...`.

- [ ] **Step 3: Update plist ProgramArguments**

Edit `~/dotfiles/twitter/Library/LaunchAgents/com.pattybot.twitter-digest.plist`. Replace:

```xml
    <key>ProgramArguments</key>
    <array>
        <string>/Users/pattybot/bin/twitter-digest-fire.sh</string>
    </array>
```

with:

```xml
    <key>ProgramArguments</key>
    <array>
        <string>/Users/pattybot/dotfiles/twitter/bin/twitter-fire.sh</string>
        <string>twitter-digest</string>
    </array>
```

Each `<string>` in `ProgramArguments` is one argv element — argv[0] is the wrapper, argv[1] is the skill name. No shell wrapper needed.

- [ ] **Step 4: Reload the plist**

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl print gui/$(id -u)/com.pattybot.twitter-digest | grep -E 'program|arguments' | head -5
```

Expected: `program = /Users/pattybot/dotfiles/twitter/bin/twitter-fire.sh` and `arguments = { twitter-fire.sh, twitter-digest }`.

- [ ] **Step 5: Manual gate — launchctl kickstart smoke test**

```bash
launchctl kickstart -p gui/$(id -u)/com.pattybot.twitter-digest
tail -F ~/Library/Logs/twitter-fire.log
```

Expected within ~5 min: full live digest fire via launchd path, Telegram delivery, clean `----- exit 0 -----`.

- [ ] **Step 6: Commit plist change + legacy rename**

```bash
cd ~/dotfiles
git add twitter/Library/LaunchAgents/com.pattybot.twitter-digest.plist twitter/bin/twitter-digest-fire.legacy.sh
git commit -m "$(cat <<'EOF'
twitter: point digest plist at twitter-fire.sh; preserve legacy wrapper

Phase A complete: cron-fired digest now goes through the new
prefire+fire split. Legacy wrapper preserved for one-week rollback
window before deletion.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task A.4: Update CLAUDE.md and digest runbook for new paths

**Files:**
- Modify: `~/dotfiles/twitter/CLAUDE.md`
- Modify: `~/dotfiles/twitter/.claude/skills/twitter-digest/references/runbook.md`

- [ ] **Step 1: Update CLAUDE.md**

In `~/dotfiles/twitter/CLAUDE.md`:
- Replace mentions of `bin/twitter-digest-fire.sh` with `bin/twitter-fire.sh twitter-digest`.
- Replace `~/Library/Logs/twitter-digest.log` with `~/Library/Logs/twitter-fire.log`.
- In "Common commands", update manual fire commands to `~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest [--dry-run]`.

- [ ] **Step 2: Update digest runbook**

Same find/replace in `~/dotfiles/twitter/.claude/skills/twitter-digest/references/runbook.md`.

- [ ] **Step 3: Spot-check**

```bash
grep -RnE 'twitter-digest-fire\.sh|Logs/twitter-digest\.log' ~/dotfiles/twitter/ --include='*.md' --include='*.sh' --include='*.plist'
```
Expected: only matches inside `twitter-digest-fire.legacy.sh` itself, or as historical references in the legacy wrapper's leading comment.

- [ ] **Step 4: Commit**

```bash
cd ~/dotfiles
git add twitter/CLAUDE.md twitter/.claude/skills/twitter-digest/references/runbook.md
git commit -m "$(cat <<'EOF'
twitter: update docs for Phase A path changes

CLAUDE.md and digest runbook now reference twitter-fire.sh and
~/Library/Logs/twitter-fire.log.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Phase A unattended gate

Before starting Phase B, **wait for the next 08:00 ET or 22:00 ET cron fire** and verify the digest arrives in Telegram. Wrapper launchd-context bugs historically only manifest in unattended runs; this gate is non-skippable.

---

## Phase B — Shared bash helpers

### Task B.1: Write `bin/lib/telegram-send.sh` and isolation-test it

**Files:**
- Create: `~/dotfiles/twitter/bin/lib/telegram-send.sh`

- [ ] **Step 1: Write the helper**

```bash
mkdir -p ~/dotfiles/twitter/bin/lib
```

Create `~/dotfiles/twitter/bin/lib/telegram-send.sh`:

```bash
#!/bin/bash
# telegram-send.sh — hardened curl-pattern Telegram delivery.
#
# Reads:
#   TELEGRAM_CHAT_ID            — target chat
#   TELEGRAM_MESSAGE_FILE       — HTML message body path
#   TELEGRAM_MESSAGE_PLAIN_FILE — plain-text fallback path
#   ~/.claude/channels/telegram/.env — TELEGRAM_BOT_TOKEN
#
# Writes:
#   $RUN_DIR/tg_response.json — Telegram's response
#
# Exit codes:
#   0 — sent successfully (HTML or plain-text fallback)
#   1 — Telegram returned ok:false even after plain-text retry
#   2 — curl/network/local parse failure (no retry)
#
# Critical: payload routed via --data-urlencode "text@<file>" from file,
# NEVER from shell $(...). Multi-byte UTF-8 in emoji content can be mangled
# by shell interpolation → spurious retry → DUPLICATE MESSAGE bug.

set -uo pipefail

: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"
: "${TELEGRAM_MESSAGE_FILE:?TELEGRAM_MESSAGE_FILE is required}"
: "${TELEGRAM_MESSAGE_PLAIN_FILE:?TELEGRAM_MESSAGE_PLAIN_FILE is required}"

for f in "$TELEGRAM_MESSAGE_FILE" "$TELEGRAM_MESSAGE_PLAIN_FILE"; do
  [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 2; }
done

TOKEN_FILE="$HOME/.claude/channels/telegram/.env"
TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$TOKEN_FILE" | cut -d= -f2-)
if [ -z "$TOKEN" ]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN not found in $TOKEN_FILE" >&2
  exit 2
fi

RUN_DIR="${RUN_DIR:-/tmp/twitter-tg-resp-$$}"
mkdir -p "$RUN_DIR"
RESPONSE_FILE="$RUN_DIR/tg_response.json"

curl -sS "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text@${TELEGRAM_MESSAGE_FILE}" \
  -d "parse_mode=HTML" \
  -d "disable_web_page_preview=true" \
  -o "$RESPONSE_FILE"
CURL_EXIT=$?
if [ "$CURL_EXIT" -ne 0 ]; then
  echo "telegram-send: curl exited $CURL_EXIT (no retry on network errors)" >&2
  exit 2
fi

OK=$(python3 -c "
import json, sys
try:
    r = json.load(open('$RESPONSE_FILE'))
    print(r.get('ok', False))
except Exception as e:
    print('parse_error:' + str(e), file=sys.stderr)
    print(False)
" 2>&1)

if [ "$OK" = "True" ]; then
  exit 0
fi

if echo "$OK" | grep -q 'parse_error'; then
  echo "telegram-send: local parse error on response (no retry): $OK" >&2
  exit 2
fi

DESC=$(python3 -c "
import json
r = json.load(open('$RESPONSE_FILE'))
print(r.get('description', '<no description>'))
")
echo "telegram-send: HTML send returned ok:false ($DESC); retrying with plain text" >&2

curl -sS "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text@${TELEGRAM_MESSAGE_PLAIN_FILE}" \
  -d "disable_web_page_preview=true" \
  -o "$RESPONSE_FILE"
CURL_EXIT=$?
if [ "$CURL_EXIT" -ne 0 ]; then
  echo "telegram-send: plain-text retry curl exited $CURL_EXIT" >&2
  exit 1
fi

OK=$(python3 -c "
import json, sys
try:
    r = json.load(open('$RESPONSE_FILE'))
    print(r.get('ok', False))
except Exception:
    print(False)
")

if [ "$OK" = "True" ]; then
  exit 0
fi

DESC=$(python3 -c "
import json
r = json.load(open('$RESPONSE_FILE'))
print(r.get('description', '<no description>'))
")
echo "telegram-send: plain-text retry also returned ok:false ($DESC)" >&2
exit 1
```

- [ ] **Step 2: Make executable**

```bash
chmod +x ~/dotfiles/twitter/bin/lib/telegram-send.sh
```

- [ ] **Step 3: Isolation test — successful send**

```bash
TMPDIR=$(mktemp -d -t tg-send-test.XXXXXX)
echo '<b>telegram-send.sh isolation test (HTML)</b>' > "$TMPDIR/msg.html"
echo 'telegram-send.sh isolation test (plain)' > "$TMPDIR/msg.txt"
TELEGRAM_CHAT_ID=7953915703 \
TELEGRAM_MESSAGE_FILE="$TMPDIR/msg.html" \
TELEGRAM_MESSAGE_PLAIN_FILE="$TMPDIR/msg.txt" \
RUN_DIR="$TMPDIR" \
  ~/dotfiles/twitter/bin/lib/telegram-send.sh
echo "exit=$?"
cat "$TMPDIR/tg_response.json"
```
Expected: exit 0; response shows `"ok":true`; one message in Telegram.

- [ ] **Step 4: Duplicate-message regression check**

Re-run step 3's command. Expected: exit 0, ONE additional message (not two).

- [ ] **Step 5: HTML failure → plain-text retry**

```bash
echo '<b>broken html' > "$TMPDIR/msg.html"
TELEGRAM_CHAT_ID=7953915703 \
TELEGRAM_MESSAGE_FILE="$TMPDIR/msg.html" \
TELEGRAM_MESSAGE_PLAIN_FILE="$TMPDIR/msg.txt" \
RUN_DIR="$TMPDIR" \
  ~/dotfiles/twitter/bin/lib/telegram-send.sh
echo "exit=$?"
```
Expected: exit 0; stderr shows the retry; one plain-text message in Telegram.

- [ ] **Step 6: Commit**

```bash
cd ~/dotfiles
git add twitter/bin/lib/telegram-send.sh
git commit -m "$(cat <<'EOF'
twitter: add bin/lib/telegram-send.sh

Hardened curl-pattern Telegram delivery. Preserves the file-payload
rule (no shell substitution on multi-byte UTF-8) and the retry-only-
on-ok:false rule that prevents duplicate sends.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B.2: Write `bin/lib/dedup-append.sh` and isolation-test it

**Files:**
- Create: `~/dotfiles/twitter/bin/lib/dedup-append.sh`

- [ ] **Step 1: Write the helper**

Create `~/dotfiles/twitter/bin/lib/dedup-append.sh`:

```bash
#!/bin/bash
# dedup-append.sh — atomic JSON array append for the twitter skills.
#
# Reads:
#   DEDUP_FILE       — path to JSON file (array of {url, digestedAt})
#   DEDUP_URLS_JSON  — JSON array of URL strings to add
#   DEDUP_TTL_DAYS   — optional; prune entries older than N days before append
#
# Writes the merged file atomically (tmp + os.replace).
# Idempotent: duplicate URLs are NOT re-added.
# Preserves entry order. Prints final count to stdout.

set -uo pipefail

: "${DEDUP_FILE:?DEDUP_FILE is required}"
: "${DEDUP_URLS_JSON:?DEDUP_URLS_JSON is required (JSON array of URL strings)}"

mkdir -p "$(dirname "$DEDUP_FILE")"

DEDUP_TTL_DAYS="${DEDUP_TTL_DAYS:-}" python3 - <<PY
import json, os, sys
from datetime import datetime, timedelta, timezone

path = os.environ["DEDUP_FILE"]
new_urls = json.loads(os.environ["DEDUP_URLS_JSON"])
ttl_days_str = os.environ.get("DEDUP_TTL_DAYS", "")
ttl_days = int(ttl_days_str) if ttl_days_str else None

now = datetime.now(timezone.utc)

existing = []
if os.path.exists(path) and os.path.getsize(path):
    with open(path) as f:
        existing = json.load(f)

if ttl_days is not None:
    cutoff = now - timedelta(days=ttl_days)
    existing = [e for e in existing if datetime.fromisoformat(e["digestedAt"]) >= cutoff]

seen = {e["url"] for e in existing}
for u in new_urls:
    if u and u not in seen:
        existing.append({"url": u, "digestedAt": now.isoformat()})
        seen.add(u)

# PID-suffixed tmp to avoid races if two writers ever touch the same file
# (shouldn't happen under flock, but cheap insurance against future regressions).
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w") as f:
    json.dump(existing, f)
os.replace(tmp, path)
print(len(existing))
PY
```

- [ ] **Step 2: Make executable**

```bash
chmod +x ~/dotfiles/twitter/bin/lib/dedup-append.sh
```

- [ ] **Step 3: Isolation test — fresh file**

```bash
TMP=$(mktemp -t dedup-test.XXXXXX)
rm "$TMP"
DEDUP_FILE="$TMP" \
DEDUP_URLS_JSON='["https://x.com/foo/status/1","https://x.com/foo/status/2"]' \
  ~/dotfiles/twitter/bin/lib/dedup-append.sh
cat "$TMP"
```
Expected: stdout `2`; file contains two entries.

- [ ] **Step 4: Isolation test — dedup**

```bash
DEDUP_FILE="$TMP" \
DEDUP_URLS_JSON='["https://x.com/foo/status/1","https://x.com/foo/status/3"]' \
  ~/dotfiles/twitter/bin/lib/dedup-append.sh
cat "$TMP"
```
Expected: stdout `3`; file contains exactly three entries; status/1 not duplicated.

- [ ] **Step 5: Isolation test — TTL prune**

```bash
python3 -c "
import json
from datetime import datetime, timezone, timedelta
path = '$TMP'
d = json.load(open(path))
d[1]['digestedAt'] = (datetime.now(timezone.utc) - timedelta(days=8)).isoformat()
json.dump(d, open(path, 'w'))
"
DEDUP_FILE="$TMP" DEDUP_URLS_JSON='[]' DEDUP_TTL_DAYS=7 \
  ~/dotfiles/twitter/bin/lib/dedup-append.sh
cat "$TMP"
```
Expected: stdout `2`; status/2 pruned.

- [ ] **Step 6: Commit**

```bash
cd ~/dotfiles
git add twitter/bin/lib/dedup-append.sh
git commit -m "$(cat <<'EOF'
twitter: add bin/lib/dedup-append.sh

Atomic JSON array append with optional TTL prune. Idempotent on
duplicates, preserves order, tmp + os.replace for crash safety.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B.3: Rewire digest SKILL.md to call helpers

**Files:**
- Modify: `~/dotfiles/twitter/.claude/skills/twitter-digest/SKILL.md` (sections 7 and 8)

- [ ] **Step 1: Replace section 7 (deliver to Telegram)**

In `~/dotfiles/twitter/.claude/skills/twitter-digest/SKILL.md`, find `### 7. Deliver to Telegram`. Replace the section body (the curl block + retry logic prose) with:

````markdown
Compose the HTML digest into `$RUN_DIR/digest.html` and a plain-text fallback into `$RUN_DIR/digest.txt`. Send via the shared helper:

```bash
RUN_DIR=/tmp/twitter-digest-run
mkdir -p "$RUN_DIR"

# $DIGEST_HTML and $DIGEST_PLAIN are composed in earlier steps.
printf '%s' "$DIGEST_HTML"  > "$RUN_DIR/digest.html"
printf '%s' "$DIGEST_PLAIN" > "$RUN_DIR/digest.txt"

TELEGRAM_CHAT_ID=7953915703 \
TELEGRAM_MESSAGE_FILE="$RUN_DIR/digest.html" \
TELEGRAM_MESSAGE_PLAIN_FILE="$RUN_DIR/digest.txt" \
RUN_DIR="$RUN_DIR" \
  /Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh
TG_EXIT=$?
```

The helper enforces the file-payload rule (no shell substitution → no UTF-8 mangling → no duplicate-send retry path) and the retry-only-on-ok:false rule. Both are load-bearing — inspect the helper at that path for the full failure-mode reference.

**On `$TG_EXIT`:**
- `0` — sent (HTML or plain-text fallback). Proceed to step 8.
- `1` — Telegram returned `ok: false` even after plain-text retry. Write `state/last-failure.json` with `kind: telegram` (description from `$RUN_DIR/tg_response.json`). STOP. Do NOT send another Telegram message about the failure.
- `2` — curl/network/local-parse failure. Same handling as `kind: telegram` but with a network-error message.
````

- [ ] **Step 2: Replace section 8 (atomic finalize)**

Find `### 8. On success: atomic finalize + persist digested URLs`. Replace the inline Python heredoc that appends to digested-urls.json with a helper call:

````markdown
### 8. On success: atomic finalize + persist digested URLs

```bash
PENDING=~/.claude/skills/twitter-digest/state/pending.json
LAST_SUCCESS=~/.claude/skills/twitter-digest/state/last-success.json
DIGESTED_URLS=~/.claude/skills/twitter-digest/state/digested-urls.json

python3 -c "
import json
d = json.load(open('$PENDING'))
d['telegramOk'] = True
json.dump(d, open('$PENDING.tmp', 'w'))
" && mv "$PENDING.tmp" "$LAST_SUCCESS" && rm -f "$PENDING"

# Append summarized URLs, prune entries older than 7 days.
# $SUMMARIZED_URLS_JSON is the JSON array of statusUrls that shipped.
DEDUP_FILE="$DIGESTED_URLS" \
DEDUP_URLS_JSON="$SUMMARIZED_URLS_JSON" \
DEDUP_TTL_DAYS=7 \
  /Users/pattybot/dotfiles/twitter/bin/lib/dedup-append.sh
```
````

- [ ] **Step 3: Manual gate — live digest fire**

```bash
launchctl kickstart -p gui/$(id -u)/com.pattybot.twitter-digest
tail -F ~/Library/Logs/twitter-fire.log
```

Expected: live digest fires, Telegram delivered, no parse_error or duplicate symptoms.

- [ ] **Step 4: Commit**

```bash
cd ~/dotfiles
git add twitter/.claude/skills/twitter-digest/SKILL.md
git commit -m "$(cat <<'EOF'
twitter-digest: rewire SKILL.md to call shared helpers

Sections 7 (Telegram send) and 8 (dedup append) now invoke
bin/lib/telegram-send.sh and bin/lib/dedup-append.sh.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task B.4: Phase B unattended gate

Wait for the next 08:00 or 22:00 ET cron fire. Phase B is "done" only after one unattended fire succeeds end-to-end with the helpers in the loop.

---

## Phase C — Bookmark skill + dispatch

### Task C.1: DOM probe — verify bookmarks-page selectors

**Files:** none modified.

- [ ] **Step 1: Navigate bot Chrome to bookmarks manually**

In the bot Chrome window, navigate to `https://x.com/i/bookmarks`. Confirm visually you see your bookmarks list.

- [ ] **Step 2: Run digest's extraction eval against bookmarks**

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "
  Array.from(document.querySelectorAll('article[data-testid=\"tweet\"]')).slice(0, 10).map(a => {
    const author = a.querySelector('[data-testid=\"User-Name\"]')?.innerText || '';
    const text = a.querySelector('[data-testid=\"tweetText\"]')?.innerText || '';
    const timeEl = a.querySelector('time');
    const timeISO = timeEl?.getAttribute('datetime') || null;
    const statusHref = timeEl?.closest('a')?.getAttribute('href')
      || a.querySelector('a[href*=\"/status/\"]')?.getAttribute('href')
      || null;
    const statusUrl = statusHref ? ('https://x.com' + statusHref) : null;
    const articleAnchor = a.querySelector('a[href*=\"/article/\"], a[href*=\"/i/article/\"]');
    const articleLink = articleAnchor ? ('https://x.com' + articleAnchor.getAttribute('href')) : null;
    return {author: author.slice(0,40), textLen: text.length, timeISO, statusUrl, articleLink};
  })
"
```

Expected: JSON array of 10 entries, each with non-empty `author`, `textLen > 0`, valid ISO `timeISO`, `statusUrl` starting with `https://x.com/`.

**If selectors differ**: note the difference and adapt Task C.2's skill content. Likely cases: `data-testid="bookmark"` wrapping or article-specific containers.

- [ ] **Step 3: Confirm scroll behavior**

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "window.scrollBy(0, 1500); 'scrolled'"
sleep 2
browser-use --cdp-url http://127.0.0.1:9222 eval "document.querySelectorAll('article[data-testid=\"tweet\"]').length"
```
Expected: count increases after scroll.

- [ ] **Step 4: Note findings**

Capture any DOM differences in `/tmp/bookmarks-dom-notes.md`. If none, proceed to Task C.2 with the digest's exact selectors.

### Task C.2: Create twitter-bookmarks SKILL.md

**Files:**
- Create: `~/dotfiles/twitter/.claude/skills/twitter-bookmarks/SKILL.md`

- [ ] **Step 1: Create dir and write SKILL.md**

```bash
mkdir -p ~/dotfiles/twitter/.claude/skills/twitter-bookmarks/references
```

Create `~/dotfiles/twitter/.claude/skills/twitter-bookmarks/SKILL.md`:

````markdown
---
name: twitter-bookmarks
description: Generate an X bookmark digest — attaches via CDP to the long-running bot Chrome daemon (launchctl-managed, persistent profile, debug port 9222), navigates to x.com/i/bookmarks, scrolls until ~150 substantive bookmarks accumulated OR a ~2-month tweet-age heuristic trips OR plateau, summarizes new bookmarks since last fire (with persistent URL dedup — no TTL), separately summarizes any long-form X Articles, and delivers to Telegram. Use when the user asks for "bookmarks digest", "summarize my bookmarks", "/bookmarks", "read my bookmarks", or when fired by the paired-session dispatch skill.
---

# Twitter Bookmarks Digest

On-demand job: attach to the persistent bot Chrome on `127.0.0.1:9222`, navigate to `x.com/i/bookmarks`, scrape new bookmarks since the last fire, summarize them + any X Articles, deliver to Telegram. Persistent dedup means each bookmark is summarized exactly once, forever. The first fire uses a ~2-month tweet-age heuristic to bound the initial backlog; subsequent fires only surface newly-saved bookmarks via URL dedup.

**Important: the bookmarks page DOM exposes the tweet's authored date (`time[datetime]`), NOT the bookmark save date.** The heuristic uses tweet age as an approximation of save age — it works because the bookmarks page is sorted reverse-chronologically by save date, AND because most bookmarks are saved within a short window of the tweet's posting. Edge case: someone who recently bookmarks a very old tweet (e.g., a 2-year-old essay) will see that bookmark trip the heuristic prematurely. Accepted tradeoff — the first-fire seeds dedup against everything visible, so a re-fire isn't catastrophic. The 150-item count cap is the primary stop; tweet-age is the backup.

## Inputs (from environment / state)

- **Browser**: same daemon Chrome as the twitter-digest skill, listening on `http://127.0.0.1:9222` for CDP. Persistent user-data-dir at `$HOME/Library/Application Support/twitter-bot-chrome`. Auth state (X cookies) lives in that profile. **Never spawn a new browser-use Chrome — always attach via `--cdp-url`.**
- **URL dedup**: `~/.claude/skills/twitter-bookmarks/state/digested-urls.json` is an array of `{url, digestedAt}`. At extract time, drop any bookmark whose `statusUrl` is in this set. After a successful run, append summarized URLs via the shared helper. **No TTL.**
- **Telegram bot token**: parse from `~/.claude/channels/telegram/.env` (key `TELEGRAM_BOT_TOKEN`). Delivery uses `~/dotfiles/twitter/bin/lib/telegram-send.sh`.
- **Telegram chat_id**: `7953915703`.

## Workflow

### 1. Load digested-URL dedup set

```bash
DIGESTED_URLS=~/.claude/skills/twitter-bookmarks/state/digested-urls.json
mkdir -p "$(dirname "$DIGESTED_URLS")"
DIGESTED_COUNT=$(python3 -c "
import json, os
p = '$DIGESTED_URLS'
n = len(json.load(open(p))) if os.path.exists(p) and os.path.getsize(p) else 0
print(n)
")
echo "digested-urls in dedup set: $DIGESTED_COUNT"
```

If `DIGESTED_COUNT == 0` this is the first (seed) fire — apply the 2-month tweet-age heuristic to bound the initial backlog. (See top-of-file note on why tweet-age is an approximation of save-age, not a precise mapping.)

### 2. Attach to daemon Chrome, navigate to bookmarks, verify

```bash
browser-use --cdp-url http://127.0.0.1:9222 open https://x.com/i/bookmarks
sleep 4
browser-use --cdp-url http://127.0.0.1:9222 eval "
  JSON.stringify({
    title: document.title,
    vis: document.visibilityState,
    iw: innerWidth,
    ih: innerHeight,
    hasBookmarkList: !!document.querySelector('[aria-label*=\"Bookmark\"], [data-testid=\"primaryColumn\"]'),
    hasLoginWall: !!document.querySelector('a[href=\"/login\"]') || !!document.querySelector('a[href=\"/i/flow/login\"]')
  })
"
```

Expected: `vis === "visible"`, `iw > 0`, `ih > 0`, `title` includes "Bookmark", `hasBookmarkList === true`, `hasLoginWall === false`.

**Failure semantics**: identical to twitter-digest step 2 — same `visibility` / `auth` / `dom` kinds, same `Page.bringToFront` self-recovery. See `~/.claude/skills/twitter-digest/SKILL.md` step 2 for the failure handling reference.

### 3. Gather bookmarks

**Stop on whichever first**:

1. **~150 substantive bookmarks** in `seen` accumulator (primary stop).
2. **~10 consecutive bookmarks whose tweet authored date is older than 2 months ago** (tweet-age heuristic on first fire only — when `DIGESTED_COUNT == 0`; backup stop).
3. **URL dedup**: 5+ consecutive already-summarized URLs (you've scrolled past everything new since last fire).
4. **Wall budget**: 5 minutes elapsed.
5. **Plateau**: 3 consecutive zero-new scroll iterations.
6. **Hard-fail kind**: `auth`, `dom`, `visibility`, `stall`.

#### Sanctioned tactic toolkit

Identical to twitter-digest's toolkit MINUS the Home-tab refresh click (no equivalent on bookmarks) and the For-You tab ensure (no such tab on bookmarks):

| Tactic | When | Cap |
|---|---|---|
| `window.scrollBy(0, 1500)` | Default scroll | unlimited |
| `tweets[last].scrollIntoView({block:'end'})` | After scrollBy plateaus | unlimited |
| `window.scrollTo(0, 0)` | Refresh / feed feels frozen | 3 |
| `Escape` keystroke (native via `browser-use keys "Escape"`) | Modal/dialog interstitials | 3 |
| Hard-fail with categorized `kind` | On auth/dom/visibility/stall | 1 |

**Forbidden**: button clicks beyond visibility recovery, typing, form submission, `location.reload()`, navigation away from `x.com/i/bookmarks` (article URLs in step 4 are the only sanctioned exception).

#### Scroll-extract loop

Alternate `window.scrollBy(0, 1500)` and extraction eval. Pause 1-2s after each scroll.

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "
  Array.from(document.querySelectorAll('article[data-testid=\\"tweet\\"]')).slice(0, 80).map(a => {
    const author = a.querySelector('[data-testid=\\"User-Name\\"]')?.innerText || '';
    const text = a.querySelector('[data-testid=\\"tweetText\\"]')?.innerText || '';
    const timeEl = a.querySelector('time');
    const timeISO = timeEl?.getAttribute('datetime') || null;
    const statusHref = timeEl?.closest('a')?.getAttribute('href')
      || a.querySelector('a[href*=\\"/status/\\"]')?.getAttribute('href')
      || null;
    const statusUrl = statusHref ? ('https://x.com' + statusHref) : null;
    const articleAnchor = a.querySelector('a[href*=\\"/article/\\"], a[href*=\\"/i/article/\\"]');
    const articleLink = articleAnchor ? ('https://x.com' + articleAnchor.getAttribute('href')) : null;
    return {author, text: text.slice(0, 800), timeISO, statusUrl, articleLink};
  })
"
```

Dedupe by `(author, text)`. Drop entries already in `digested-urls.json` and entries with no `timeISO`.

#### 2-month tweet-age heuristic (first fire only)

After each extraction, check the trailing 10 substantive bookmarks. If 10 consecutive have `timeISO` (the tweet's authored date) older than 60 days ago, stop scrolling — we've likely scrolled into older save-date territory. The "10 consecutive" check makes a single bookmarked-old-tweet not trip this; only a sustained run does.

This is intentionally approximate. The DOM doesn't expose bookmark save date directly; we use tweet age as a proxy because (a) the page is reverse-chronological by save date, and (b) most bookmarks are saved soon after the tweet's posting. The 150-item count cap is the primary defense — this heuristic just keeps a low-volume bookmarker's first fire from running forever.

### 3a. Stall handling

Identical to twitter-digest 3a. Screenshots persist to `state/stalls/` (last 10 kept). See twitter-digest's SKILL.md 3a for the classification table.

### 4. Pull long-form X Articles

For each unique `articleLink`:

```bash
browser-use --cdp-url http://127.0.0.1:9222 open "$ARTICLE_URL"
sleep 3
browser-use --cdp-url http://127.0.0.1:9222 eval "
  const bodyEl = document.querySelector('[data-testid=\\"longformText\\"]')
              || document.querySelector('[data-testid=\\"article-body\\"]')
              || document.querySelector('article')
              || document.body;
  ({
    title: document.querySelector('h1')?.innerText
        || document.querySelector('[data-testid=\\"article-title\\"]')?.innerText
        || document.title,
    author: document.querySelector('[data-testid=\\"User-Name\\"]')?.innerText
         || document.querySelector('[data-testid=\\"article-author\\"]')?.innerText
         || '',
    body: bodyEl.innerText.slice(0, 12000),
    bodyLen: bodyEl.innerText.length
  })
"
```

If `bodyLen < 500`, screenshot and emit a "📰 extraction failed" entry. After each article, navigate back: `browser-use --cdp-url http://127.0.0.1:9222 open https://x.com/i/bookmarks`.

Summarize each article in 2-3 sentences.

### 5. Theme and compose

Organize bookmarks into:
- **🔖 Posts** — substantive tweet bookmarks (attribution-linked bullets)
- **📰 Saved articles** — X Articles (bold title + 2-3 sentence summary)

Omit empty sections. If literally no bookmarks shipped after dedup, send `Nothing new in bookmarks 🥱`.

Header: `🔖 <b>Bookmark recap — <date></b>` (no AM/PM variants — bookmarks fire on-demand, not on a clock).

```html
🔖 <b>Bookmark recap — <date></b>

🔖 <b>Posts</b>
• <a href="<statusUrl>">@author posted</a>: <one-line summary>
• <a href="<statusUrl>">@author tweeted</a>: <one-line summary>

📰 <b>Saved articles</b>
• <b>&lt;title&gt;</b> — <a href="<articleLink>">@author</a>
  &lt;2-3 sentence summary&gt;

—
<N> bookmarks scanned · <M> minutes scrolled · <K> articles read

<i>Summaries of items you saved on X; positions are the posters', not verified.</i>
```

Same HTML-escape rules: `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, applied last. Same Telegram HTML whitelist.

### 6. Pre-send: write pending state

```bash
PENDING=~/.claude/skills/twitter-bookmarks/state/pending.json
mkdir -p "$(dirname "$PENDING")"
NOW=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
cat > "$PENDING" <<EOF
{"runAt": "$NOW", "scrolledFor": $SCROLL_SECONDS, "bookmarkCount": $BOOKMARK_COUNT, "articleCount": $ARTICLE_COUNT, "telegramOk": null}
EOF
```

### 7. Deliver to Telegram

```bash
RUN_DIR=/tmp/twitter-bookmarks-run
mkdir -p "$RUN_DIR"

printf '%s' "$DIGEST_HTML"  > "$RUN_DIR/bookmarks.html"
printf '%s' "$DIGEST_PLAIN" > "$RUN_DIR/bookmarks.txt"

TELEGRAM_CHAT_ID=7953915703 \
TELEGRAM_MESSAGE_FILE="$RUN_DIR/bookmarks.html" \
TELEGRAM_MESSAGE_PLAIN_FILE="$RUN_DIR/bookmarks.txt" \
RUN_DIR="$RUN_DIR" \
  /Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh
TG_EXIT=$?
```

`$TG_EXIT` handling: 0 → proceed to step 8. 1 → `kind: telegram` failure, STOP. 2 → same, with network-error message.

### 8. On success: atomic finalize + persist digested URLs

```bash
PENDING=~/.claude/skills/twitter-bookmarks/state/pending.json
LAST_SUCCESS=~/.claude/skills/twitter-bookmarks/state/last-success.json
DIGESTED_URLS=~/.claude/skills/twitter-bookmarks/state/digested-urls.json

python3 -c "
import json
d = json.load(open('$PENDING'))
d['telegramOk'] = True
json.dump(d, open('$PENDING.tmp', 'w'))
" && mv "$PENDING.tmp" "$LAST_SUCCESS" && rm -f "$PENDING"

# Persistent dedup — DEDUP_TTL_DAYS deliberately omitted.
# $SUMMARIZED_URLS_JSON includes statusUrls AND articleLinks that shipped.
DEDUP_FILE="$DIGESTED_URLS" \
DEDUP_URLS_JSON="$SUMMARIZED_URLS_JSON" \
  /Users/pattybot/dotfiles/twitter/bin/lib/dedup-append.sh
```

**Do NOT** call `browser-use close --all`.

## Dry-run mode

If invoked with "dry-run" in the prompt, do everything *except* steps 6-8 — print composed digest HTML to stdout, skip Telegram, skip state writes.

## Failure handling

Same `kind`-taxonomy as twitter-digest: `visibility`, `auth`, `dom`, `telegram`, `empty`, `stall`. `kind: empty` (no new bookmarks since last fire) is treated as success — send `Nothing new in bookmarks 🥱` and advance state. State `last-failure.json` written on hard fail.

`empty` on second-and-later fires is the COMMON case (you may not save bookmarks every day). The dispatch skill does NOT treat it as a problem.

## What NOT to do

- **Don't spawn a fresh browser-use Chrome.** Always `--cdp-url`.
- **Don't `browser-use close --all`.**
- **Don't try to log in programmatically.**
- **Don't fake foreground state via `setWebLifecycleState`.**
- **Stay inside the tactic toolkit.**
- **Don't navigate elsewhere on x.com** except article URLs.
- **Don't summarize non-X external links** from bookmarks — emit as plain URL bullets without summarization.
````

- [ ] **Step 2: Re-stow**

```bash
cd ~/dotfiles
stow -t ~ -R twitter
ls ~/.claude/skills/twitter-bookmarks/
```
Expected: `SKILL.md` and `references/` symlinked.

- [ ] **Step 3: Commit**

```bash
cd ~/dotfiles
git add twitter/.claude/skills/twitter-bookmarks/SKILL.md
git commit -m "$(cat <<'EOF'
twitter-bookmarks: add SKILL.md

On-demand bookmark digest. Same anti-bot Chrome infrastructure as
twitter-digest; persistent URL dedup (no TTL); 2-month save-date
heuristic bounds the first-fire backlog.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task C.3: Create twitter-bookmarks/references/runbook.md

**Files:**
- Create: `~/dotfiles/twitter/.claude/skills/twitter-bookmarks/references/runbook.md`

- [ ] **Step 1: Write the runbook**

Create `~/dotfiles/twitter/.claude/skills/twitter-bookmarks/references/runbook.md`:

```markdown
# twitter-bookmarks runbook

## Architecture

Runs on the same bot Chrome daemon as twitter-digest. No scheduled cron — fires on demand via:
- Telegram DM with `/bookmarks` or similar (the `twitter-bookmarks-dispatch` skill).
- Terminal: `~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks` (or `--dry-run`).
- `claude -p "run the twitter-bookmarks skill"` (skips wrapper's prefire — testing only).

## Manual fire

```bash
~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks            # live
~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks --dry-run  # composed only
```

Wrapper acquires shared flock so bookmarks can't contend with cron digest on bot Chrome.

## State files

- `state/last-success.json` — last successful fire metadata.
- `state/last-failure.json` — `{kind, at, message, screenshot?}` on hard fail.
- `state/digested-urls.json` — persistent URL dedup (NO TTL).
- `state/pending.json` — pre-send forensic crumb.
- `state/stalls/*.png` — last 10 stall screenshots.

## Reset dedup (full re-scrape)

```bash
mv ~/.claude/skills/twitter-bookmarks/state/digested-urls.json /tmp/bookmarks-dedup.bak
```

Next fire re-summarizes everything visible (subject to 2-month heuristic on first fire).

## Telegram trigger phrases

The `twitter-bookmarks-dispatch` skill activates on (case-insensitive):
- `/bookmarks`
- `read my bookmarks`
- `summarize my bookmarks`
- `bookmark digest`
- `bookmark recap`

Dispatch flow: prefire → ack → launch background Agent → relay any failure via MCP reply.

## "No paired session" symptom

If you DM `/bookmarks` and nothing happens, ensure a paired Claude Code session is currently running with the telegram plugin active.

## Failure-kind taxonomy

Same as twitter-digest. See `~/.claude/skills/twitter-digest/references/runbook.md`.

Bookmark-specific:
- `kind: empty` — treated as success ("Nothing new in bookmarks 🥱"). Common on second-and-later fires.
- `kind: busy` — `twitter-fire.sh` couldn't acquire shared flock. Retry in ~5 min.

## Re-auth

Same as twitter-digest. Sign in via the bot Chrome window when `kind: auth` fires.
```

- [ ] **Step 2: Commit**

```bash
cd ~/dotfiles
git add twitter/.claude/skills/twitter-bookmarks/references/runbook.md
git commit -m "$(cat <<'EOF'
twitter-bookmarks: add references/runbook.md

Operational notes — manual fire, trigger phrases, dedup reset,
failure handling, paired-session dependency.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task C.4: Seed fire

The first fire validates the skill end-to-end AND seeds `digested-urls.json` via the 2-month heuristic.

- [ ] **Step 1: Verify no dedup yet**

```bash
ls -la ~/.claude/skills/twitter-bookmarks/state/digested-urls.json 2>&1
```
Expected: file does not exist OR is empty.

- [ ] **Step 2: Run the seed fire**

```bash
~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks
tail -F ~/Library/Logs/twitter-fire.log
```

Expected: ~5-10 min run, `===== fire <iso> skill=twitter-bookmarks =====` header, prefire success, scroll progress, Telegram delivered, `----- exit 0 -----`. A `🔖 Bookmark recap` digest arrives in Telegram.

- [ ] **Step 3: Verify state**

```bash
ls -la ~/.claude/skills/twitter-bookmarks/state/
cat ~/.claude/skills/twitter-bookmarks/state/last-success.json
python3 -c "
import json
d = json.load(open('$HOME/.claude/skills/twitter-bookmarks/state/digested-urls.json'))
print(f'dedup entries: {len(d)}')
print(f'first: {d[0]}'); print(f'last:  {d[-1]}')
"
```
Expected: 50-150 entries.

- [ ] **Step 4: Second-fire no-op gate**

Re-run: `~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks`
Expected: short run (~30s); Telegram receives `Nothing new in bookmarks 🥱` or tiny digest; exit 0.

- [ ] **Step 5: Manual-bookmark + re-fire**

Save one tweet as a bookmark via the bot Chrome window manually. Wait 30s. Re-fire.
Expected: digest with exactly one bullet for that bookmark.

- [ ] **Step 6: No commit needed**

State files are gitignored.

### Task C.5: Create twitter-bookmarks-dispatch skill

**Files:**
- Create: `~/dotfiles/twitter/.claude/skills/twitter-bookmarks-dispatch/SKILL.md`

- [ ] **Step 1: Write the dispatch skill**

```bash
mkdir -p ~/dotfiles/twitter/.claude/skills/twitter-bookmarks-dispatch
```

Create `~/dotfiles/twitter/.claude/skills/twitter-bookmarks-dispatch/SKILL.md`:

````markdown
---
name: twitter-bookmarks-dispatch
description: Dispatch a twitter-bookmarks fire in response to a Telegram DM. Use ONLY when a Telegram message arrives in this paired session matching trigger phrases like "/bookmarks", "read my bookmarks", "summarize my bookmarks", "bookmark digest", or "bookmark recap". Does NOT run the scrape itself — launches it as a background Agent so this session stays responsive.
---

# Twitter Bookmarks Dispatch

Runs in your paired Claude Code session. When a Telegram DM matches a bookmark-trigger phrase, fire this skill to kick off the scrape in the background without blocking the live conversation. The actual scrape runs through `twitter-fire.sh twitter-bookmarks` so it inherits the orchestrator's flock + post-fire frontmost restore invariants.

## Trigger phrases (case-insensitive)

- `/bookmarks`
- `read my bookmarks`
- `summarize my bookmarks`
- `bookmark digest`
- `bookmark recap`

## Dispatch workflow

### 1. Record dispatch start timestamp

For the failure-relay step at the end, we need to know whether any `last-failure.json` was written by THIS dispatch (vs left over from a previous run). Capture an ISO timestamp NOW and remember it for step 5.

```bash
DISPATCH_AT_ISO=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
echo "dispatch started at: $DISPATCH_AT_ISO"
```

### 2. Fast-fail flock check (UX optimization)

```bash
LOCK=~/.claude/skills/.twitter-fire.lock
if [ -f "$LOCK" ] && fuser "$LOCK" >/dev/null 2>&1; then
  HOLDER_PID=$(cat "$LOCK" 2>/dev/null || echo "?")
  echo "BUSY: holder PID=$HOLDER_PID"
else
  echo "FREE"
fi
```

If `BUSY`: reply to Telegram via MCP `reply` tool: `"Bot Chrome busy with another fire (PID <pid>) — try again in ~5 min."` and STOP. (Note: this is an early-exit optimization for UX. `twitter-fire.sh` would also exit 3 with `kind: busy` if launched against a held lock — but ack'ing "busy" upfront is faster than waiting for the Agent to land and report it.)

### 3. Ack the trigger

Use Telegram `reply` MCP tool. Pass `chat_id` from the inbound `<channel>` block. Message:

```
🔖 Kicked off — bookmark digest inbound in a few minutes.
```

### 4. Launch background Agent that runs the orchestrator

Use the `Agent` tool with:
- `subagent_type`: `general-purpose`
- `run_in_background`: `true`
- `description`: `Run twitter-bookmarks via twitter-fire.sh`
- `prompt`:

```
Run the command `/Users/pattybot/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks` via the Bash tool. Wait for it to complete (~5-10 minutes typical). The wrapper handles its own flock acquisition, prefire foregrounding, claude -p invocation against the bookmark skill, Telegram delivery, and post-fire frontmost restore — you do NOT need to do any of those yourself.

When Bash returns, read the last 30 lines of ~/Library/Logs/twitter-fire.log and return a single sentence summary based on the exit code:
- exit 0 → "Bookmark fire delivered; see Telegram."
- exit 3 → "Bookmark fire skipped — flock held by another twitter-fire (busy)."
- other → "Bookmark fire failed with exit <N>; see ~/.claude/skills/twitter-bookmarks/state/last-failure.json."

Do not call any other tools. Do not narrate progress — one line at the end.
```

The Agent's body is a single Bash call with the synchronous `twitter-fire.sh` invocation. Cheap on inference tokens (one tool call, one final sentence), but fire-and-forget from the parent session's perspective.

### 5. On Agent completion notification

When the background Agent finishes:

```bash
LAST_FAILURE=~/.claude/skills/twitter-bookmarks/state/last-failure.json

# Compare last-failure.json's `at` field against the dispatch start timestamp
# captured in step 1. Only relay failures written AFTER dispatch started.
# This is robust even if a stale last-failure.json exists from a prior run.
if [ -f "$LAST_FAILURE" ]; then
  FAILURE_AT=$(python3 -c "import json; print(json.load(open('$LAST_FAILURE')).get('at',''))" 2>/dev/null)
  if [ -n "$FAILURE_AT" ] && [ "$FAILURE_AT" \> "$DISPATCH_AT_ISO" ]; then
    # Failure is from this dispatch run. Read kind + message for relay.
    KIND=$(python3 -c "import json; print(json.load(open('$LAST_FAILURE')).get('kind','unknown'))")
    MSG=$(python3 -c "import json; print(json.load(open('$LAST_FAILURE')).get('message','no message'))")
    echo "RELAY: kind=$KIND msg=$MSG"
  else
    echo "ok: failure file is stale (from prior run)"
  fi
else
  echo "ok"
fi
```

If `RELAY:`: use MCP `reply` to send:

```
❌ Bookmark fire failed: <kind> — <message>
```

One line. User can ask for more.

If `ok:`: nothing further — user got the digest in Telegram already.

## What NOT to do

- **Don't run inline** — blocks the session for minutes.
- **Don't call prefire or the skill directly** — always go through `twitter-fire.sh` so the flock and post-fire restore invariants apply.
- **Don't relay successful runs** — the digest message itself is the signal.
- **Don't retry on Agent failure.**
- **Don't use file mtime for failure detection** — use the `at` field inside `last-failure.json`. A stale failure file's mtime can be confusing; the timestamp inside the JSON is what the skill itself wrote.
````

- [ ] **Step 2: Re-stow**

```bash
cd ~/dotfiles
stow -t ~ -R twitter
ls ~/.claude/skills/twitter-bookmarks-dispatch/
```

- [ ] **Step 3: Commit**

```bash
cd ~/dotfiles
git add twitter/.claude/skills/twitter-bookmarks-dispatch/SKILL.md
git commit -m "$(cat <<'EOF'
twitter-bookmarks-dispatch: paired-session DM trigger

Activates on bookmark trigger phrases. Runs prefire, acks via Telegram
MCP, launches a background Agent to run the scrape. On Agent completion,
relays any failure to Telegram via MCP reply.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task C.6: Live Telegram trigger test

- [ ] **Step 1: Ensure paired CC session is running**

Start a Claude Code session (or use your existing paired one). Confirm telegram MCP is loaded.

- [ ] **Step 2: DM the bot**

From Telegram: `/bookmarks`

- [ ] **Step 3: Verify ack**

Expected within ~6s: `🔖 Kicked off — bookmark digest inbound in a few minutes.`

In CC session: `twitter-bookmarks-dispatch` activates, background Agent launches.

- [ ] **Step 4: Wait for digest**

Expected within ~5 min: full `🔖 Bookmark recap` digest in Telegram. Since previous run dedup'd, expect `Nothing new in bookmarks 🥱` or tiny digest.

- [ ] **Step 5: Verify parent saw completion**

Parent session receives Agent completion notification. Dispatch step 5 logic runs; `ok` since no fresh failure.

- [ ] **Step 6: No commit needed**

Pure verification.

### Task C.7: Failure-relay + concurrency verification

- [ ] **Step 1: Failure-relay test**

```bash
mv ~/.claude/channels/telegram/.env ~/.claude/channels/telegram/.env.bak
```

DM the bot `/bookmarks`.

Expected: ack arrives (MCP `reply`, not curl). Agent runs, scrape proceeds, fails at `telegram-send.sh` (no token). Writes `kind: telegram` to `last-failure.json`. Parent reads and sends MCP-relayed error: `❌ Bookmark fire failed: telegram — TELEGRAM_BOT_TOKEN not found...`

Restore:
```bash
mv ~/.claude/channels/telegram/.env.bak ~/.claude/channels/telegram/.env
```

- [ ] **Step 2: Concurrency test**

Terminal 1: `~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks` (let run).
Terminal 2 (within 30s): `~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest`.
Expected: terminal 2 exits 3 immediately. Log shows `BUSY` block for digest naming terminal 1's PID.

Terminal 1's bookmark fire completes normally.

- [ ] **Step 3: Telegram busy-on-trigger test**

Start terminal: `~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks`
Immediately DM the bot `/bookmarks`.
Expected: Telegram reply within ~6s: `Bot Chrome busy with another fire (PID <pid>) — try again in ~5 min.` No background Agent.

- [ ] **Step 4: No commit needed**

Final verification. After this passes, the plan is complete.

---

## Self-Review

### Spec coverage check

| Spec requirement | Plan task |
|---|---|
| Rename stow package to `twitter/` | Task 0.1 |
| Extract `twitter-prefire.sh` | Task A.1 |
| Write `twitter-fire.sh <skill>` with flock | Task A.2 |
| Preserve legacy wrapper | Task A.3 |
| Update digest plist | Task A.3 |
| Update CLAUDE.md + runbook | Task A.4 |
| Phase A unattended gate | end of Phase A |
| `bin/lib/telegram-send.sh` | Task B.1 |
| `bin/lib/dedup-append.sh` | Task B.2 |
| Rewire digest SKILL.md | Task B.3 |
| Phase B unattended gate | Task B.4 |
| DOM probe | Task C.1 |
| `twitter-bookmarks/SKILL.md` | Task C.2 |
| `twitter-bookmarks/references/runbook.md` | Task C.3 |
| Seed fire + no-op gate | Task C.4 |
| `twitter-bookmarks-dispatch/SKILL.md` | Task C.5 |
| Live Telegram trigger | Task C.6 |
| Failure relay via MCP | Task C.7 step 1 |
| Concurrency flock test | Task C.7 steps 2-3 |

All spec sections covered. No gaps.

### Placeholder scan

No "TBD", "TODO", or "fill in later" placeholders. Helper scripts and skill files have complete content. Task C.1 (DOM probe) is intentionally a verification step with no code generation.

### Consistency check

- `telegram-send.sh` env vars: `TELEGRAM_CHAT_ID`, `TELEGRAM_MESSAGE_FILE`, `TELEGRAM_MESSAGE_PLAIN_FILE`, `RUN_DIR` — consistent across B.1, B.3, C.2.
- `dedup-append.sh` env vars: `DEDUP_FILE`, `DEDUP_URLS_JSON`, `DEDUP_TTL_DAYS` — consistent across B.2, B.3, C.2.
- Skill names: `twitter-digest`, `twitter-bookmarks`, `twitter-bookmarks-dispatch` — consistent throughout.
- Lock file: `~/.claude/skills/.twitter-fire.lock` — A.2, C.5, C.7.
- Chat ID `7953915703` — consistent.
- Log path `~/Library/Logs/twitter-fire.log` — A.2, A.3, A.4, B.3, C.4.

No inconsistencies.

### Risk callouts for the executor

1. **Phase A and B each have an unattended-cron gate** with 12-24h wait. Wrapper bugs historically only manifest in launchd-context fires.
2. **Bookmark skill section 5** does NOT use `references/themes.md` — bookmarks organized into Posts + Articles, not by topic. Intentional.
3. **Dispatch's `general-purpose` Agent** runs full Claude inference. Token usage scales.
4. **2-month tweet-age heuristic is a save-age approximation.** The DOM exposes the tweet's authored date, NOT the bookmark save date. The bookmark page's reverse-chronological save order + the "10 consecutive" check make this work in practice, but a power user who bookmarks many old essays in a short window could see the heuristic trip prematurely. 150-item count cap is the primary defense.
5. **Test Telegram messages WILL arrive** in chat 7953915703. Set expectations or use a test chat.
