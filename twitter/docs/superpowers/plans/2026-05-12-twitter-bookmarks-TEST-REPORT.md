# Twitter Bookmarks — Test Report

**Date**: 2026-05-13 (UTC)
**Branch**: `twitter-bookmarks-impl` (now merged into main; HEAD = `28a1d30`)
**Scope**: Codex review of all 13 commits, then end-to-end production testing.

## Summary

15 commits landed. Codex review surfaced 6 issues (2 CRITICAL, 2 HIGH, 2 MEDIUM) — all fixed pre-merge. E2E testing surfaced 1 additional production bug (zsh string comparison in dispatch failure relay) — fixed mid-test. Live production validated against the real bot Chrome, real launchd cron path, and real Telegram chat 7953915703. Two messages delivered live (digest msg_id 312-ish via kickstart, bookmark recap msg_id 313, no-op `Nothing new` msg).

**All automatable tests pass. Remaining manual tests are flagged below for your hands.**

---

## Codex review findings + fixes

Codex was given the whole implementation (skills, helpers, scripts, plist, plan, spec). Top 6 findings, all addressed in commit `d50f775`:

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | CRITICAL | `flock` not available on macOS — wrapper would exit 3 on every fire (command-not-found returns 127, `! flock -n` enters busy branch) | Replaced `flock -n 200` with `shlock -p $$ -f "$LOCK_FILE"`. macOS-native PID-file locking with built-in stale-PID detection. |
| 2 | CRITICAL | Wrapper silently exited (missing binary, prefire failure, busy) without writing `last-failure.json`, so dispatch couldn't relay the failure to Telegram | Added `write_failure()` helper; called on every non-zero exit. kinds: `config`, `busy`, `prefire`. |
| 3 | HIGH | Timestamps mismatched: wrapper used `date -Iseconds` (local TZ offset), dispatch used Python UTC. Lexicographic compare across TZs is unreliable. | All timestamps now UTC ISO via `iso_utc_now()` python helper in the wrapper. Dispatch already used UTC. |
| 4 | HIGH | Section 8 advanced `last-success.json` BEFORE dedup-append. If dedup failed after Telegram succeeded → URLs lost → next fire re-sends → duplicate digest. | Reordered both skills' section 8: dedup-append FIRST. If dedup fails, write `kind: dedup` failure, leave `pending.json`, do not advance success. |
| 5 | MEDIUM | dedup-append helper comment said it was race-safe; actually relies on the wrapper lock | Comment updated for accuracy |
| 6 | MEDIUM | telegram-send.sh plain-text retry didn't classify local-parse errors as exit-2 transport (same as first attempt does) | Mirror parse-error handling on retry path. |

Then during E2E testing, found one more:

| # | Severity | Issue | Fix |
|---|---|---|---|
| 7 | HIGH | Dispatch's `[ "$FAILURE_AT" \> "$DISPATCH_AT_ISO" ]` works in bash but NOT in zsh. Claude Code's Bash tool uses zsh on this system, so the comparison always went to STALE → real Telegram failures would be silently dropped instead of relayed. | Comparison moved into Python (env-var form). Works in both bash and zsh. Updated "what NOT to do" with the trap. Commit `28a1d30`. |

---

## Test results — automated (this session)

### Phase 3b — Helper isolation tests

| Test | Result | Evidence |
|---|---|---|
| `telegram-send.sh` HTML success | ✅ PASS | exit 0, msg_id 308, `ok=True` |
| Duplicate-send regression check (2× same payload back-to-back) | ✅ PASS | msg_id 309 + 310, two distinct messages, no internal duplicate |
| HTML→plain-text retry on malformed HTML | ✅ PASS | exit 0, stderr `retrying with plain text`, msg_id 311 |
| `dedup-append.sh` fresh + dedup + TTL | ✅ PASS | fresh→2 entries, dedup→3 (no duplicate of status/A), TTL prune→2 (status/B removed at 8d age) |

### Phase 3c — twitter-fire.sh

| Test | Result | Evidence |
|---|---|---|
| Dry-run digest end-to-end | ✅ PASS | Full skill execution (76 scrolls, 201 tweets), exit 0, no Telegram send |
| Flock contention | ✅ PASS | Holder PID 8413 acquired; contender exit 3 in 16ms; `kind: busy` written to `last-failure.json` with holder PID |
| UTC timestamps everywhere | ✅ PASS | All `at` fields confirmed `+00:00` |

### Phase 3d — Launchctl reload + live cron-path fire

| Test | Result | Evidence |
|---|---|---|
| Plist `ProgramArguments` updated | ✅ PASS | `launchctl print` shows `program = .../twitter-fire.sh`, `arguments = { twitter-fire.sh, twitter-digest }` |
| `launchctl kickstart` live fire | ✅ PASS | exit 0 in 8.5 min, `telegramOk: true`, 131 tweets in `last-success.json`, dedup grew 80→96 entries (Section 8 reorder confirmed) |
| osascript activation -1712 absorbed by 30s timeout | ✅ PASS | WARN logged but skill continued (bot Chrome was already visible from prior fire); 30s budget kept it non-fatal |

### Phase 3e — Bookmark DOM probe

| Test | Result | Evidence |
|---|---|---|
| Visibility probe selectors | ✅ PASS | `hasBookmarkAria: true`, `hasPrimaryColumn: true`, `articleCount: 5`, `hasLoginWall: false` |
| Tweet extraction selectors | ✅ PASS | 5 entries with valid author/timeISO/statusUrl (May 9-11 dates) |

### Phase 3f — Bookmark seed fire + no-op gate

| Test | Result | Evidence |
|---|---|---|
| Seed fire end-to-end | ✅ PASS | 151 bookmarks scraped in 126s, 21-bullet themed digest (7 themes) delivered as msg_id 313, 3968 chars (under 4096 cap), zero X Articles in scope |
| `digested-urls.json` populated | ✅ PASS | 151 entries persisted, no TTL |
| Section 8 reorder (dedup before state advance) | ✅ PASS | `last-success.json` written AFTER dedup-append succeeded |
| No-op gate (immediate re-fire) | ✅ PASS | Loop stopped on `dedup_consec=10` after 1 iteration, "Nothing new in bookmarks 🥱" delivered, `kind: empty` in state |

### Phase 3g — Dispatch logic + concurrency

| Test | Result | Evidence |
|---|---|---|
| Dispatch lock-check while held | ✅ PASS | Correctly identifies BUSY when live holder; FREE when no lock |
| Failure-relay timestamp comparison — fresh failure | ✅ PASS | Produces `RELAY\|telegram\|TELEGRAM_BOT_TOKEN not found` |
| Failure-relay timestamp comparison — stale failure | ✅ PASS | Produces `STALE` |
| Two-fire concurrency (bookmark + digest) | ✅ PASS | Bookmark held lock at PID 27631; digest exited 3 in 16ms with `kind:busy` referencing 27631 |

---

## Test results — manual (require your hands)

### Live Telegram trigger (cannot run from background agent)

**You need to do this:** open a Claude Code session in a terminal (so the telegram MCP plugin is paired), then from your phone DM the bot:

```
/bookmarks
```

**Expected:**
- Within ~6s, a Telegram reply: `🔖 Kicked off — bookmark digest inbound in a few minutes.`
- Within ~5 min, a `🔖 Bookmark recap` digest in Telegram. Since the seed fire already populated 151 dedup entries, the most likely outcome is `Nothing new in bookmarks 🥱` (matches the no-op gate behavior).
- In your paired CC session: the `twitter-bookmarks-dispatch` skill activates, a background Agent launches with `subagent_type: general-purpose`, the Agent runs `twitter-fire.sh twitter-bookmarks` via Bash, returns a one-sentence summary, parent reads `last-failure.json` and confirms `ok` (no fresh failure).

### Failure-relay end-to-end

```bash
mv ~/.claude/channels/telegram/.env ~/.claude/channels/telegram/.env.bak
```

DM `/bookmarks`. Expected:
- Ack still arrives (MCP `reply` works — uses its own auth, not the .env)
- Agent runs, scrape fails at `telegram-send.sh` (no token)
- Wrapper writes `kind: telegram` to `last-failure.json`
- Parent reads the fresh failure, sends `❌ Bookmark fire failed: telegram — TELEGRAM_BOT_TOKEN not found...` via MCP

Restore:
```bash
mv ~/.claude/channels/telegram/.env.bak ~/.claude/channels/telegram/.env
```

---

## Production state — final

```
~/dotfiles/  (on main, 28a1d30 HEAD)
├── twitter/                                  ← stow package (renamed from twitter-digest/)
│   ├── bin/
│   │   ├── twitter-fire.sh                   ← NEW orchestrator (shlock, write_failure, UTC)
│   │   ├── twitter-prefire.sh                ← NEW OS plumbing (pre-warm, 30s timeout, diagnostics)
│   │   ├── twitter-digest-fire.legacy.sh     ← PRESERVED for rollback (1-week window)
│   │   ├── twitter-bot-chrome-setup.sh
│   │   └── lib/
│   │       ├── telegram-send.sh              ← NEW (hardened curl pattern)
│   │       └── dedup-append.sh               ← NEW (atomic, idempotent, PID-tmp)
│   ├── Library/LaunchAgents/
│   │   ├── com.pattybot.twitter-bot-chrome.plist
│   │   └── com.pattybot.twitter-digest.plist ← UPDATED ProgramArguments
│   ├── .claude/skills/
│   │   ├── twitter-digest/
│   │   │   ├── SKILL.md                      ← UPDATED (calls helpers, reordered Section 8)
│   │   │   └── references/{themes,runbook}.md ← UPDATED paths
│   │   ├── twitter-bookmarks/                ← NEW skill
│   │   │   ├── SKILL.md
│   │   │   └── references/runbook.md
│   │   └── twitter-bookmarks-dispatch/       ← NEW dispatch skill
│   │       └── SKILL.md
│   ├── CLAUDE.md                             ← UPDATED architecture description
│   └── docs/superpowers/
│       ├── specs/2026-05-12-twitter-bookmarks-design.md
│       └── plans/
│           ├── 2026-05-12-twitter-bookmarks.md
│           ├── 2026-05-12-twitter-bookmarks-PRODUCTION-HANDOFF.md
│           └── 2026-05-12-twitter-bookmarks-TEST-REPORT.md  ← THIS FILE
└── (symlinks via stow into ~/bin/, ~/.claude/skills/, ~/Library/LaunchAgents/)
```

**Cron-fired digest**: live, validated via launchctl kickstart at 02:32 UTC, exit 0, 131 tweets delivered, dedup grew 80→96.

**Bookmark skill**: live, seed-fired at 02:42 UTC, 151 bookmarks scraped → 21-bullet themed digest delivered as msg 313. Second fire at 03:02 UTC → "Nothing new in bookmarks 🥱" (dedup_consec stop). Concurrency-test fire at 03:05 UTC → blocked by held lock, correctly exited 3 with `kind:busy`.

**Dispatch skill**: bash logic validated in isolation. The Agent-launch path requires a paired CC session — flagged for your manual test.

**Stale state files**:
- `~/.claude/skills/twitter-digest/state/last-failure.json` has a `kind:busy` entry from 03:05:33 (the concurrency test). NOT a real failure; will be naturally overwritten on next genuine fire OR can be removed manually.
- `~/.claude/skills/twitter-bookmarks/state/last-failure.json` does not exist (never failed).

---

## Recommended cleanup

```bash
# Remove the stale concurrency-test failure marker (not strictly required —
# dispatch's timestamp comparison would correctly ignore it as stale anyway):
rm -f ~/.claude/skills/twitter-digest/state/last-failure.json

# After 1 week of clean fires, you can delete the legacy wrapper:
# rm ~/dotfiles/twitter/bin/twitter-digest-fire.legacy.sh

# When ready to clean up the worktree (NOT NEEDED for production — main is
# fully caught up):
# git worktree remove ~/dotfiles/.claude/worktrees/twitter-bookmarks
```

---

## Known frictions / future-work notes

- **`browser-use eval` returns Python repr() not JSON.** Both skills' SKILL.md extraction snippets technically rely on the runtime to parse Python-repr objects, not JSON. The actual skill executions handled it (the runtime auto-tries `json.loads` then `ast.literal_eval`), but the docs would be more honest if they wrapped the eval body in `JSON.stringify(...)`. Tracked but not a blocker.
- **`SAVED_FRONTMOST_PID` was empty on every test fire.** The prior frontmost capture returns empty on some launchctl/CC contexts — possibly because the calling shell isn't a GUI app. No effect on functionality (post-fire restore just no-ops with empty SAVED PID). Worth investigating only if you notice "frontmost not restored after manual fire" as a UX issue.
- **osascript activation hits AppleEvent timeout (-1712) in unattended fires.** The 30s budget absorbs it (this was the WIP hardening's whole point), and the skill's visibility probe is the authoritative gate. Worth keeping an eye on whether the warn-line is consistently appearing — if every cron fire gets the WARN, the 30s budget is masking a deeper issue (e.g. macOS App Nap on the daemon Chrome).
- **Bookmark skill's "summarized URLs" semantic.** SKILL.md says "URLs that shipped"; the seed-fire skill chose to append ALL 151 scanned URLs (not just the 21 that became bullets). This prevents a permanent re-summarization backlog of "scanned-but-didn't-make-the-cut" bookmarks. Operationally correct; worth updating the SKILL.md prose to match.
