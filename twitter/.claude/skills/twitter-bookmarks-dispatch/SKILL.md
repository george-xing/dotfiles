---
name: twitter-bookmarks-dispatch
description: Dispatch a twitter-bookmarks fire in response to a Telegram DM. Use ONLY when a Telegram message arrives in this paired session matching trigger phrases like "/bookmarks", "read my bookmarks", "summarize my bookmarks", "bookmark digest", or "bookmark recap". Does NOT run the scrape itself — launches it as a background Agent so this session stays responsive.
---

# Twitter Bookmarks Dispatch

Runs in your paired Claude Code session. When a Telegram DM matches a bookmark-trigger phrase, fire this skill to kick off the scrape in the background without blocking the live conversation. The actual scrape runs through `~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks` so it inherits the orchestrator's flock + post-fire frontmost restore invariants.

## Trigger phrases (case-insensitive, matched against DM text)

- `/bookmarks`
- `read my bookmarks`
- `summarize my bookmarks`
- `bookmark digest`
- `bookmark recap`

## Dispatch workflow

### 1. Record dispatch start timestamp

Capture an ISO timestamp NOW. Step 5 uses this to distinguish a failure caused by THIS dispatch run from a stale `last-failure.json` left over from a previous run.

```bash
DISPATCH_AT_ISO=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())")
echo "dispatch started at: $DISPATCH_AT_ISO"
```

Hold `$DISPATCH_AT_ISO` somewhere you can reference after the Agent completes (a `TodoWrite` task description, an in-session variable, etc.).

### 2. Fast-fail lock check (UX optimization)

`twitter-fire.sh` uses `shlock(1)` for mutual exclusion — the lock file at `~/.claude/skills/.twitter-fire.lock` contains the PID of the holder. To check whether the lock is currently held by a live process:

```bash
LOCK=~/.claude/skills/.twitter-fire.lock
if [ -f "$LOCK" ]; then
  HOLDER_PID=$(cat "$LOCK" 2>/dev/null || echo "")
  if [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "BUSY: holder PID=$HOLDER_PID"
  else
    echo "FREE (stale lock file; twitter-fire.sh will clean it via shlock)"
  fi
else
  echo "FREE"
fi
```

If `BUSY`: use the Telegram `reply` MCP tool to send `"Bot Chrome busy with another fire (PID <pid>) — try again in ~5 min."` and STOP. Don't launch the Agent.

This is an early-exit UX optimization. `twitter-fire.sh` would also exit 3 with `kind: busy` if launched against a held lock — but ack'ing "busy" upfront is faster than waiting for the Agent to land and report it.

### 3. Ack the trigger

Use the Telegram `reply` MCP tool. Pass `chat_id` from the inbound `<channel>` block. Message text:

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

Do not call any other tools. Do not narrate progress. One sentence at the end.
```

The Agent's body is essentially a single Bash call with a synchronous `twitter-fire.sh` invocation. Cheap on inference tokens (one tool call, one final sentence), but truly fire-and-forget from the parent session's perspective.

### 5. On Agent completion notification

When the background Agent finishes, the parent session is notified with the Agent's final sentence. Check whether a failure was written by THIS dispatch:

```bash
LAST_FAILURE=~/.claude/skills/twitter-bookmarks/state/last-failure.json

if [ -f "$LAST_FAILURE" ]; then
  FAILURE_AT=$(python3 -c "import json; print(json.load(open('$LAST_FAILURE')).get('at',''))" 2>/dev/null)
  if [ -n "$FAILURE_AT" ] && [ "$FAILURE_AT" \> "$DISPATCH_AT_ISO" ]; then
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

Use ISO-8601 lexicographic comparison (`"$FAILURE_AT" \> "$DISPATCH_AT_ISO"`) — ISO timestamps sort correctly as strings.

If `RELAY: ...`: use the MCP `reply` tool to send:

```
❌ Bookmark fire failed: <kind> — <message>
```

Keep it one line. The user can ask for more detail.

If `ok: ...`: nothing further — the user already received the digest in Telegram via the Agent's own delivery, OR the run ended in `kind: empty` (sent "Nothing new in bookmarks 🥱" — already user-visible).

## What NOT to do

- **Don't run the scrape inline.** Blocks the session for minutes; user can't chat with you during that.
- **Don't call `twitter-prefire.sh` or the skill directly.** Always go through `twitter-fire.sh` so the flock and post-fire restore invariants apply. Bypassing them breaks the bot Chrome contention guarantee.
- **Don't have the Agent acquire its own flock.** `twitter-fire.sh` does that. Adding another lock layer would deadlock or race.
- **Don't relay successful runs back to Telegram.** The digest message itself is the success signal.
- **Don't retry on Agent failure.** The failure-kind is informational; retry is the operator's choice.
- **Don't use file mtime for failure detection.** Use the `at` field inside `last-failure.json` compared against the dispatch start timestamp. A stale failure file's mtime can be confusing; the JSON's own `at` is what the skill wrote.
- **Don't try to handle the case where no paired session exists.** This skill only runs WHEN a paired session is active. If the user DMs `/bookmarks` and no session is paired, the Telegram plugin queues the notification with no consumer — that's a documented limitation in the bookmark runbook, not something this skill can address.
