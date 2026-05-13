# Twitter Bookmarks — Production Handoff Checklist

**Branch**: `twitter-bookmarks-impl` (12 commits ahead of main)
**Worktree**: `/Users/pattybot/dotfiles/.claude/worktrees/twitter-bookmarks`
**Date**: 2026-05-12

All file authoring is done in the worktree. The steps below need to run against your **actual `~/dotfiles/`** checkout (not the worktree) because they touch real launchd state, the bot Chrome, and Telegram. Run them in order.

---

## Step 1 — Merge the worktree branch into main

```bash
cd ~/dotfiles
git checkout main
git merge twitter-bookmarks-impl --ff-only
# OR if you want a merge commit:
# git merge twitter-bookmarks-impl --no-ff
```

If you'd rather review commits one at a time first:
```bash
git log --oneline main..twitter-bookmarks-impl
git diff main..twitter-bookmarks-impl -- twitter/bin/twitter-fire.sh   # any specific file
```

The 12 commits, in order:

1. `d487be1` — apply codex review fixes to plan
2. `5843617` — wip hardening before refactor (System Events pre-warm + 30s timeout + diagnostics) ← the work you'd been doing locally
3. `273b2bc` — rename stow package `twitter-digest/` → `twitter/`
4. `d99e0ff` — extract `twitter-prefire.sh` from fire wrapper
5. `07f4d97` — add `twitter-fire.sh` orchestrator (with flock)
6. `61fcf6c` — switch digest plist to twitter-fire.sh, preserve legacy
7. `c1b3589` — add `bin/lib/{telegram-send,dedup-append}.sh`
8. `65fc571` — rewire digest SKILL.md to call shared helpers
9. `50d2c1f` — add twitter-bookmarks + dispatch skills

(Plus 3 earlier commits for the design spec + plan that landed before execution.)

---

## Step 2 — Re-stow

The rename moved the package directory from `twitter-digest/` to `twitter/`. Stow's symlinks need to be refreshed:

```bash
cd ~/dotfiles
stow -t ~ -D twitter-digest 2>/dev/null   # remove old symlinks (may already be gone if package was renamed)
stow -t ~ -R twitter                       # install symlinks pointing into twitter/
```

**Verify symlinks resolve into the renamed package:**

```bash
ls -la ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
# Expected: -> /Users/pattybot/dotfiles/twitter/Library/LaunchAgents/...
ls -la ~/.claude/skills/twitter-digest/SKILL.md
ls -la ~/.claude/skills/twitter-bookmarks/SKILL.md       # NEW
ls -la ~/.claude/skills/twitter-bookmarks-dispatch/SKILL.md  # NEW
```

If `~/bin/twitter-digest-fire.sh` symlink is still present from before the legacy rename, remove it (it points to the renamed `.legacy.sh` now anyway — the new wrapper is at the package path):

```bash
ls -la ~/bin/twitter-digest-fire*
# If twitter-digest-fire.sh still exists pointing at a non-existent target, rm -f it
```

---

## Step 3 — Reload the digest launchd job to pick up the new plist

```bash
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl print     gui/$(id -u)/com.pattybot.twitter-digest | grep -E 'program|argument' | head -5
```

**Expected output:**
```
program = /Users/pattybot/dotfiles/twitter/bin/twitter-fire.sh
arguments = {
        "/Users/pattybot/dotfiles/twitter/bin/twitter-fire.sh"
        "twitter-digest"
}
```

---

## Step 4 — Smoke test: dry-run

```bash
~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest --dry-run
tail -40 ~/Library/Logs/twitter-fire.log
```

**Expected log block:**
```
===== fire 2026-05-12T... skill=twitter-digest =====
  pre-fire: activating bot Chrome PID=<n>, will restore frontmost PID=<n>
  pre-fire: cdp un-minimize: un-minimized N window(s)
  pre-fire: activation confirmed (bot Chrome is frontmost)
... (claude -p dry-run output)
----- exit 0 at ... -----
```

If `exit 0` and you see the prefire log lines, **Phase A is validated**.

If exit non-zero: inspect the log block and the `state/last-failure.json` for the digest skill. Don't proceed to step 5 until this passes.

---

## Step 5 — Live cron smoke test (via launchctl kickstart)

This sends a real digest to Telegram — same code path as the 08:00/22:00 cron fires:

```bash
launchctl kickstart -p gui/$(id -u)/com.pattybot.twitter-digest
tail -F ~/Library/Logs/twitter-fire.log
```

Expected: within ~5-10 min, a 🌅 Morning digest or 🌆 Evening recap message lands in Telegram chat 7953915703. Log block shows `----- exit 0 -----`.

If this fails: rollback by editing the plist's `ProgramArguments` to point at `/Users/pattybot/dotfiles/twitter/bin/twitter-digest-fire.legacy.sh`, then reload. The legacy wrapper is preserved exactly for this scenario.

---

## Step 6 — Phase B isolation tests (helpers)

**Telegram-send isolation:**

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
```

Expected: exit 0; one HTML message in Telegram. Re-run the same command immediately to verify NO duplicate (the file-payload pattern prevents the historical duplicate-send bug).

**Plain-text retry test:**

```bash
echo '<b>broken html' > "$TMPDIR/msg.html"   # unclosed tag forces ok:false
TELEGRAM_CHAT_ID=7953915703 \
TELEGRAM_MESSAGE_FILE="$TMPDIR/msg.html" \
TELEGRAM_MESSAGE_PLAIN_FILE="$TMPDIR/msg.txt" \
RUN_DIR="$TMPDIR" \
  ~/dotfiles/twitter/bin/lib/telegram-send.sh
```

Expected: exit 0, stderr shows `retrying with plain text`, plain-text message lands in Telegram.

The dedup-append helper's correctness was already validated in the worktree (see commit `c1b3589`); no need to re-test.

---

## Step 7 — Phase B unattended gate (cron fire)

Wait for the next 08:00 or 22:00 ET cron fire and verify it delivers a normal digest using the new helpers. This is the same gate as Step 5 but unattended — it's where launchd-context-only bugs would surface.

If your next scheduled fire is far away and you want faster validation, kick it manually via `launchctl kickstart` from Step 5 again.

---

## Step 8 — Phase C bookmark skill — DOM probe + seed fire

**DOM probe first** — verify the bookmarks-page selectors before relying on them:

In the bot Chrome window, navigate to `https://x.com/i/bookmarks`. Then from any terminal:

```bash
browser-use --cdp-url http://127.0.0.1:9222 eval "
  Array.from(document.querySelectorAll('article[data-testid=\"tweet\"]')).slice(0, 10).map(a => {
    const author = a.querySelector('[data-testid=\"User-Name\"]')?.innerText || '';
    const text = a.querySelector('[data-testid=\"tweetText\"]')?.innerText || '';
    const timeEl = a.querySelector('time');
    const timeISO = timeEl?.getAttribute('datetime') || null;
    const statusUrl = timeEl?.closest('a')?.getAttribute('href') || null;
    return {author: author.slice(0,40), textLen: text.length, timeISO, hasStatusUrl: !!statusUrl};
  })
"
```

Expected: 10 entries, each with non-empty author + text + timeISO + hasStatusUrl=true. **If selectors don't work, stop and update the skill's step 3 extraction eval before proceeding.**

**Seed fire** — actually run the bookmark skill end-to-end for the first time:

```bash
~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks
tail -F ~/Library/Logs/twitter-fire.log
```

Expected: ~5-10 min run. A 🔖 Bookmark recap message lands in Telegram with Posts + Saved articles sections. `~/.claude/skills/twitter-bookmarks/state/digested-urls.json` has 50-150 entries.

**Second-fire no-op gate:**

```bash
~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks
```

Expected: short run (~30s); Telegram receives `Nothing new in bookmarks 🥱`.

**Manual-bookmark + re-fire:**

Save one new bookmark in the bot Chrome manually, wait 30s, re-fire:

```bash
~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks
```

Expected: a digest with exactly one bullet for that one bookmark.

---

## Step 9 — Live Telegram dispatch test

From your paired CC session (the one with the telegram MCP loaded), DM the bot:

```
/bookmarks
```

**Expected within ~6s:** ack message — `🔖 Kicked off — bookmark digest inbound in a few minutes.`

**Expected within ~5 min:** the bookmark digest itself (or `Nothing new` if you've already exhausted the dedup with Step 8).

In your paired CC session, you should see the `twitter-bookmarks-dispatch` skill activate and launch a background Agent. After ~5 min the parent receives completion notification.

---

## Step 10 — Failure-relay + concurrency tests (optional, for confidence)

**Failure relay:**

```bash
mv ~/.claude/channels/telegram/.env ~/.claude/channels/telegram/.env.bak
```

DM `/bookmarks`. Expected: ack arrives (MCP `reply` doesn't need the token), Agent runs, scrape fails at the `telegram-send.sh` step, parent reads `last-failure.json`, sends `❌ Bookmark fire failed: telegram — TELEGRAM_BOT_TOKEN not found...` via MCP.

Restore:
```bash
mv ~/.claude/channels/telegram/.env.bak ~/.claude/channels/telegram/.env
```

**Concurrency (flock contention):**

Terminal 1: `~/dotfiles/twitter/bin/twitter-fire.sh twitter-bookmarks` (let run).
Terminal 2 (within 30s): `~/dotfiles/twitter/bin/twitter-fire.sh twitter-digest`.

Expected: terminal 2 exits 3 immediately. Log shows `===== fire ... skill=twitter-digest BUSY =====` block naming terminal 1's PID. Terminal 1 completes normally.

---

## Rollback (only if a step above fails dangerously)

**To revert the digest cron fire to the pre-refactor wrapper:**

```bash
# Edit the plist's ProgramArguments to point at the legacy wrapper
$EDITOR ~/dotfiles/twitter/Library/LaunchAgents/com.pattybot.twitter-digest.plist
# Replace the new ProgramArguments array with:
#     <string>/Users/pattybot/dotfiles/twitter/bin/twitter-digest-fire.legacy.sh</string>

# Reload
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.twitter-digest.plist
```

The legacy wrapper contains the pre-refactor behavior (foregrounding + claude -p) as a single script, so rollback is one plist edit + reload.

**To revert everything (full nuclear option):**

```bash
cd ~/dotfiles
git revert --no-edit 50d2c1f..d487be1
# Or hard-reset to the pre-merge state, if you remember the SHA:
# git reset --hard <pre-merge-sha>
```

---

## After everything passes

- Schedule a deletion of `twitter/bin/twitter-digest-fire.legacy.sh` one week from now (calendar reminder). The plan called for a one-week rollback window before final removal.
- Optionally push the branch to GitHub if you want a backup:
  ```bash
  git push origin main
  git push origin twitter-bookmarks-impl   # if you want to preserve the branch separately
  ```

---

## Open questions / future work (out of scope here)

- **No paired session** — if the user DMs `/bookmarks` and no CC session is paired/listening, the Telegram plugin queues with no consumer. Documented limitation in the bookmark runbook. A future fix would be a dedicated launchd watcher daemon that taps Telegram getUpdates independently.
- **Non-X external links** — bookmarks containing external URLs are summarized only by their tweet text; the external link itself isn't followed. Out of scope.
- **Bookmark backlog catchup beyond 2 months** — the seed fire's tweet-age heuristic bounds the initial batch. To deliberately re-process more, reset the dedup file (`mv ~/.claude/skills/twitter-bookmarks/state/digested-urls.json /tmp/`) and re-fire.
- **Per-topic theming for bookmarks** — bookmarks ship as Posts + Saved articles (chronological-ish), not by topic. If you later want themed bookmarks, add a `references/themes.md` to the bookmark skill and a theming step like the digest's section 5.
