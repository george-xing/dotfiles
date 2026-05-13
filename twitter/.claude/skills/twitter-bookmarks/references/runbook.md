# twitter-bookmarks runbook

## Architecture

Runs on the same bot Chrome daemon as twitter-digest. No scheduled cron — fires on demand via:

- **Telegram**: DM the bot with `/bookmarks` or similar (the `twitter-bookmarks-dispatch` skill activates in your paired CC session and launches a background Agent that invokes `twitter-fire.sh twitter-bookmarks`).
- **Terminal**: `~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks` (or `--dry-run`).
- **From a CC session directly**: `claude -p "run the twitter-bookmarks skill"` (skips the wrapper's prefire — only use for testing).

The wrapper acquires the shared flock at `~/.claude/skills/.twitter-fire.lock` so a bookmark fire and a cron digest fire can't contend for bot Chrome's foreground state.

## Manual fire

```bash
~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks            # live
~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks --dry-run  # composed digest to stdout, no Telegram, no state writes
```

## State files

- `state/last-success.json` — last successful fire's metadata. Used for forensics only (no time-cutoff carryover — URL dedup is the stop signal).
- `state/last-failure.json` — `{kind, at, message, screenshot?}` on hard fail.
- `state/digested-urls.json` — persistent URL dedup. **NO TTL** — bookmark URLs are kept forever. Includes both statusUrls and articleLinks that shipped.
- `state/pending.json` — pre-send forensic crumb; removed on success.
- `state/stalls/*.png` — last 10 stall-handling screenshots.

## Reset the dedup (force re-scrape)

```bash
mv ~/.claude/skills/twitter-bookmarks/state/digested-urls.json /tmp/bookmarks-dedup.bak
```

Next fire will re-summarize everything visible on the bookmarks page (subject to the 2-month tweet-age heuristic on first fire). Keep the backup until you're sure the re-fire produced acceptable output.

## Telegram trigger phrases

The `twitter-bookmarks-dispatch` skill (lives at `~/.claude/skills/twitter-bookmarks-dispatch/SKILL.md`) activates in your paired CC session on these (case-insensitive) phrases:

- `/bookmarks`
- `read my bookmarks`
- `summarize my bookmarks`
- `bookmark digest`
- `bookmark recap`

The dispatch flow:
1. Capture dispatch start timestamp (for stale-failure detection).
2. Fast-fail flock check (reply "busy" if held, skip everything).
3. Ack to Telegram: `🔖 Kicked off — bookmark digest inbound in a few minutes.`
4. Launch a background `Agent` (run_in_background=true) whose sole job is to call `twitter-fire.sh twitter-bookmarks` via Bash and wait for completion.
5. On Agent completion, read `last-failure.json` and relay any failure whose `at` timestamp is newer than the dispatch start.

The Agent gets all of `twitter-fire.sh`'s invariants for free: flock, prefire, post-fire frontmost restore.

## "No paired session" symptom

If you DM `/bookmarks` and nothing happens, ensure a paired Claude Code session is currently running with the telegram plugin active. The telegram plugin delivers DMs as MCP notifications to whatever session is currently paired; if no session is listening, the DM lands with no consumer.

## Failure-kind taxonomy

Same as twitter-digest. See `~/.claude/skills/twitter-digest/references/runbook.md` for the full table — both skills share the kinds.

Bookmark-specific notes:
- `kind: "empty"` — treated as **success** ("Nothing new in bookmarks 🥱" sent, state advanced). This is the COMMON case on second-and-later fires; don't treat as a problem.
- `kind: "busy"` — emitted by `twitter-fire.sh` (not the skill) when the shared flock is held by another fire. Caller should retry in ~5 min.

## Re-auth

Same as twitter-digest: the daemon Chrome's `~/Library/Application Support/twitter-bot-chrome/` is the source of truth for X cookies. Sign in via the bot Chrome window when the skill hard-fails with `kind: "auth"`. No reseed script needed.

## DOM gotchas (from C.1 probe)

If a future X redesign changes the bookmarks-page DOM, the most likely points of breakage:

- `article[data-testid="tweet"]` — the bookmark tile container. If this becomes `data-testid="bookmark"` or similar, update the extraction eval in step 3.
- `time[datetime]` — the tweet's authored date. Used for the tweet-age heuristic. If `datetime` attribute disappears or moves to a different element, the heuristic breaks.
- `[aria-label*="Bookmark"]` — bookmark-list indicator used in step 2's visibility probe. Update if X relabels the section.

Run the DOM probe (Task C.1 of the implementation plan, or just re-run the extraction eval against a manually-loaded bookmarks page) when you suspect a UI change.
