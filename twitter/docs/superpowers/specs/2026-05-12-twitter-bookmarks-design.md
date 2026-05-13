# Twitter Bookmarks Skill + Refactor — Design

**Status**: Approved design, awaiting implementation plan.
**Date**: 2026-05-12

## Goal

Add on-demand X bookmark summarization triggered from Telegram, reusing the existing twitter-digest anti-bot Chrome infrastructure. Refactor twitter-digest along the way so the two skills share genuinely-duplicated infrastructure (OS-plumbing wrapper, Telegram send, dedup append) without coupling their workflow logic.

## Scope

In scope (all three phases, one plan):
- **Phase A** — split `twitter-digest-fire.sh` into `twitter-prefire.sh` (OS plumbing) + `twitter-fire.sh <skill-name>` (orchestrator).
- **Phase B** — extract `bin/lib/telegram-send.sh` and `bin/lib/dedup-append.sh`; rewire the digest skill to call them.
- **Phase C** — build `twitter-bookmarks` skill + paired-session Telegram dispatch via the `Agent` tool with `run_in_background: true`.

Out of scope:
- Replacing the digest's curl-based Telegram send with the MCP `telegram:reply` tool (different failure semantics).
- A dedicated launchd-managed Telegram listener (deferred until paired-session-unavailability becomes a real pain point).
- Following non-X external links from bookmarks (only X Articles, per existing digest behavior).
- Backlog catchup beyond the "last 2 months" seed.

## Architecture

The dotfiles stow package `twitter-digest/` is renamed to `twitter/` (single atomic commit at the start of work — both skills now live there). After all phases:

```
~/dotfiles/twitter/
├── bin/
│   ├── twitter-prefire.sh          # OS-plumbing only (foreground/TCC/un-minimize)
│   ├── twitter-fire.sh             # orchestrator; takes <skill-name>
│   └── lib/
│       ├── telegram-send.sh        # curl-pattern wrapper, retry-only-on-ok:false
│       └── dedup-append.sh         # atomic JSON array append with optional TTL
├── Library/LaunchAgents/
│   ├── com.pattybot.twitter-bot-chrome.plist   # unchanged
│   └── com.pattybot.twitter-digest.plist       # updated: ProgramArguments → twitter-fire.sh twitter-digest
└── .claude/skills/
    ├── twitter-digest/             # existing skill, edited to call shared helpers
    │   ├── SKILL.md
    │   └── references/{themes.md,runbook.md}
    └── twitter-bookmarks/          # NEW
        ├── SKILL.md
        └── references/runbook.md
```

Skill state directories (`~/.claude/skills/<skill>/state/`) remain per-skill and gitignored. No shared mutable state between skills. The only shared resource is the bot Chrome itself, guarded by a single `flock` lock at `~/.claude/skills/.twitter-fire.lock`.

Phase ordering is sequential. After each phase, the existing twice-daily digest must still fire cleanly (regression gate).

## Components

### `bin/twitter-prefire.sh`
- **Purpose**: bring bot Chrome window to foreground, un-minimize, confirm activation settled. Nothing else.
- **Input**: none.
- **Output**: stdout/stderr `pre-fire: …` log block. Exit 0 if activation confirmed; exit 2 if daemon health check failed; exit 0 with `WARN` if activation didn't settle (existing behavior — SKILL.md visibility probe is the authoritative gate).
- **Does**: daemon health check (12s deadline), prior frontmost PID capture, `lsof`-based bot Chrome PID disambiguation, CDP `Browser.setWindowBounds` un-minimize, System Events pre-warm, PID-targeted activate, 5s settle poll.
- **Does NOT**: invoke `claude`, send Telegram, restore prior frontmost.

### `bin/twitter-fire.sh <skill-name> [--dry-run]`
- **Purpose**: run a single fire of one twitter skill end-to-end.
- **Input**: skill name (required, matches a directory under `~/.claude/skills/`); optional `--dry-run`.
- **Output**: `~/Library/Logs/twitter-fire.log` (renamed from `twitter-digest.log`). Wraps run in `===== fire <iso> skill=<name> =====` / `----- exit <N> -----` blocks.
- **Does**: acquires `flock`, calls `twitter-prefire.sh`, invokes `claude -p` against `~/.claude/skills/<skill-name>/SKILL.md`, post-fire frontmost restore (only if bot Chrome still frontmost), exits with claude's exit code.

### `bin/lib/telegram-send.sh`
- **Purpose**: send one HTML message to a Telegram chat with hardened retry semantics.
- **Input** (env): `TELEGRAM_CHAT_ID`, `TELEGRAM_MESSAGE_FILE` (HTML path), `TELEGRAM_MESSAGE_PLAIN_FILE` (plain-text fallback path).
- **Output**: exit 0 on success; exit 1 if Telegram returned `ok: false` even after plain-text retry; exit 2 if curl/network failure. Response saved to `$RUN_DIR/tg_response.json`.
- **Enforces**: payload routed via `--data-urlencode "text@…"` from file (never from shell var — preserves duplicate-message fix). Retry ONLY on parseable `ok: false`. One retry max (plain-text fallback). Token loaded from `~/.claude/channels/telegram/.env`.

### `bin/lib/dedup-append.sh`
- **Purpose**: read a JSON file containing array of `{url, ts}`, append new URLs with current timestamp, optionally prune entries older than a TTL, atomic write back.
- **Input** (env): `DEDUP_FILE`, `DEDUP_URLS_JSON` (JSON array of URL strings), `DEDUP_TTL_DAYS` (optional; if absent, no pruning — supports bookmark "no TTL" model).
- **Output**: exit 0, prints final entry count.
- **Enforces**: tmp-file write + atomic move; idempotent on duplicates; preserves entry order.

### `.claude/skills/twitter-bookmarks/SKILL.md`
- **Purpose**: scrape `x.com/i/bookmarks`, dedup against `state/digested-urls.json`, summarize new bookmarks + any X Articles among them, deliver to Telegram.
- **Structure**: mirrors digest's SKILL.md sections (load dedup → attach + visibility probe → navigate bookmarks page → scroll-extract loop → article extraction → theme/compose → deliver → finalize) with these workflow differences:
  - URL: `x.com/i/bookmarks` (not `/home`).
  - No Home-tab refresh tactic in the sanctioned toolkit (no equivalent on bookmarks page).
  - No For-You-tab ensure step.
  - Stop conditions: (a) ~150 substantive bookmarks accumulated, (b) ~10 consecutive bookmarks whose tweets are older than 2 months (save-date heuristic — bookmarks page is reverse-chronological by save date), (c) URL dedup says all recent are summarized, (d) feed plateau or hard-fail.
  - Header: `🔖 Bookmark recap — <date>`.
  - First fire seeds the dedup naturally via the 2-month cutoff; subsequent fires only surface newly saved bookmarks.

### `.claude/skills/twitter-bookmarks/references/runbook.md`
- Bookmark-specific operational notes: re-auth (same bot Chrome window), manual fire (`~/bin/twitter-fire.sh twitter-bookmarks`), dedup reset procedure, Telegram trigger phrases, "no paired session" symptom.

### Paired-session Telegram dispatch
A new skill at `.claude/skills/twitter-bookmarks-dispatch/SKILL.md` inside the renamed stow package, symlinked to `~/.claude/skills/twitter-bookmarks-dispatch/`. Activates in the paired CC session on trigger phrases.

- **Trigger phrases**: DM starting with `/bookmarks`, `read my bookmarks`, `summarize my bookmarks`, similar.
- **Behavior**: paired session shells out to `~/bin/twitter-prefire.sh` via Bash, then launches an `Agent` with `run_in_background: true`, `subagent_type: "general-purpose"`, prompt instructing it to run twitter-bookmarks. Parent immediately acks via Telegram `reply` tool ("🔖 Kicked off — results inbound in a few minutes."). On subagent completion, parent reads `state/last-failure.json` if present and relays a short error to Telegram via MCP `reply`.

## Data Flow

### Cron-fired digest (post-refactor, externally unchanged)

```
launchd 08:00/22:00 ET
  → com.pattybot.twitter-digest.plist
  → twitter-fire.sh twitter-digest
      → flock acquire
      → twitter-prefire.sh                              # foreground, un-minimize, settle
      → claude -p "Run twitter-digest skill at <path>"
          → CDP attach 127.0.0.1:9222
          → scroll x.com/home For You, extract, article extract
          → telegram-send.sh                            # curl POST, retry-on-false
          → dedup-append.sh (TTL=7d)
          → write state/last-success.json
      → post-fire frontmost restore (if bot Chrome still frontmost)
      → flock release
      → exit
```

### On-demand bookmark fire (new)

```
DM to Telegram bot: "/bookmarks"
  → telegram plugin server.ts (always running)
  → MCP notification → paired Claude Code session
  → twitter-bookmarks-dispatch skill activates
      → flock check (bail with "busy" Telegram reply if held)
      → Bash: twitter-prefire.sh
      → Telegram reply tool: ack
      → Agent (run_in_background=true, general-purpose):
          prompt: run twitter-bookmarks skill
            → CDP attach 127.0.0.1:9222
            → navigate x.com/i/bookmarks
            → scroll-extract loop until ~150 items / 2-month cutoff / plateau
            → article extract for each unique articleLink
            → dedup-append.sh (no TTL — persistent)
            → telegram-send.sh
            → write state/last-success.json
          → subagent returns
      → parent notified; if subagent wrote last-failure.json,
        parent reads it and relays short error via MCP reply tool
```

### Manual fire (terminal, no Telegram)
Same as cron path, invoked as `~/bin/twitter-fire.sh twitter-bookmarks` or `~/bin/twitter-fire.sh twitter-digest`.

### State touchpoints

| File | Written by | TTL |
|---|---|---|
| `~/.claude/skills/twitter-digest/state/last-success.json` | digest skill | indefinite |
| `~/.claude/skills/twitter-digest/state/digested-urls.json` | dedup-append.sh | rolling 7d |
| `~/.claude/skills/twitter-bookmarks/state/last-success.json` | bookmarks skill | indefinite |
| `~/.claude/skills/twitter-bookmarks/state/digested-urls.json` | dedup-append.sh | persistent forever |
| `~/.claude/skills/.twitter-fire.lock` | twitter-fire.sh (flock) | per-fire |
| `$RUN_DIR/digest.html`, `tg_response.json` | skill + telegram-send.sh | per-fire (under `/tmp/twitter-*-run/`) |

## Error Handling

Both skills share the existing failure-kind taxonomy: `visibility`, `auth`, `dom`, `telegram`, `empty`, `stall`. Each writes `state/last-failure.json` with `{kind, at, message, screenshot?}` on hard fail. Operator response matrix per skill's `references/runbook.md`.

**New failure modes from this work:**

- **Bot Chrome contention** — guarded by shared `flock` at `~/.claude/skills/.twitter-fire.lock`. `twitter-fire.sh` acquires non-blocking; on conflict exits with kind `busy`. Paired-session dispatch checks the lock BEFORE acking; replies "Bot Chrome busy with PID <n>" if held.
- **Subagent failure relay** — parent session reads subagent's `state/last-failure.json` on completion notification; sends a one-line error via MCP `telegram:reply` tool. This is the ONE bypass of the curl-pattern Telegram send.
- **Paired session not running** — DM lands in telegram plugin with no consumer. Best-effort delivery is the plugin's design; documented limitation in bookmark `runbook.md`. Deferred mitigation.

**Refactor rollback**: `twitter-digest-fire.legacy.sh` preserved for one week after Phase A lands; plist `ProgramArguments` is the only thing to revert if regressions show up.

## Validation

No automated test suite. Manual + observational, scaled per phase.

### Phase A gates
1. `~/bin/twitter-fire.sh twitter-digest --dry-run` exits 0 with prefire activation confirmed in log.
2. Plist swap; `launchctl bootout` + `bootstrap`; `launchctl print` shows new ProgramArguments.
3. `launchctl kickstart` produces a live fire with full Telegram delivery and clean log.
4. **Unattended cron gate**: next 08:00 or 22:00 fire succeeds end-to-end.

### Phase B gates
1. `telegram-send.sh` isolation test: send + re-send (no duplicate) + malformed-HTML retry-to-plain-text.
2. `dedup-append.sh` isolation test: append + duplicate-ignore + TTL prune of backdated entry.
3. Dry-run gate via `~/bin/twitter-fire.sh twitter-digest --dry-run`.
4. **Unattended cron gate**: next fire succeeds end-to-end.

### Phase C gates
1. **DOM probe** before writing skill: run digest's extraction `eval` against `x.com/i/bookmarks` in the bot Chrome manually; confirm selectors work or note adaptations.
2. **First (seed) fire**: `~/bin/twitter-fire.sh twitter-bookmarks` from terminal produces ~150 items / 2-month cutoff worth, digest in Telegram, dedup populated.
3. **Second-fire no-op gate**: immediate re-run yields `kind: "empty"` or near-empty digest.
4. **Manual-bookmark + re-fire**: save one bookmark in bot Chrome, fire again, expect a one-bullet digest.
5. **Telegram-trigger live test**: DM `/bookmarks` → ack within 6s → digest in Telegram within ~5min.
6. **Failure-relay test**: temporarily break Telegram .env, DM `/bookmarks`, expect ack + MCP-relayed error.
7. **Concurrency test**: run digest fire from terminal while bookmark fire is mid-scrape; expect `busy` exit, no Chrome contention.

### Cross-phase
- Next 08:00 cron after all phases land delivers a normal digest.
- Telegram `/bookmarks` DM from a phone produces a digest.
- Neither `state/last-failure.json` shows recent unrecovered failures.

## Phase sequence summary

| Phase | Lands | Validates by | Rollback |
|---|---|---|---|
| Rename | Stow package renamed `twitter-digest` → `twitter` | symlinks still resolve; cron fire works | revert single commit |
| A | `twitter-prefire.sh` + `twitter-fire.sh <skill>`, digest plist updated | unattended cron fire | revert plist ProgramArguments to legacy wrapper |
| B | `lib/telegram-send.sh` + `lib/dedup-append.sh`; digest SKILL.md rewired | isolation tests + unattended cron fire | revert digest SKILL.md to inline curl/dedup |
| C | `twitter-bookmarks/` skill + dispatch skill + flock | manual + Telegram + concurrency tests | delete new files; remove dispatch skill |

## Deferred work (out of scope here)

- Dedicated Telegram listener daemon (covers "no paired session" gap).
- Migration of digest's Telegram send from curl to MCP `reply` tool.
- Bookmark backlog catchup beyond 2 months.
- Following non-X links from bookmarks.
- Automated test suite.
