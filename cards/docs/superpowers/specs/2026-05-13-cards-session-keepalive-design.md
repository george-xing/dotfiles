# Cards Session Keepalive — Design Spec

**Date:** 2026-05-13
**Status:** brainstorming-approved (awaiting implementation plan)
**Approach selected:** A — Minimum-Viable Keepalive (MVK)
**Out-of-scope alternatives considered:** Option B (Keychain credentials + scripted login), Approach B (separated keepalive + watchdog), Approach C (adaptive learning keepalive), operator-assisted pre-fire login, Telegram-triggered fires.

---

## 1. Purpose

The cards-bot Chrome's Amex/Chase sessions die ~30 minutes after the last user-input event, because both issuers run short idle timers on untrusted devices and no in-browser affordance ("Remember Me", "trusted device" checkboxes) extends the per-session timeout. Yesterday's fire activated 97 Amex offers successfully, but the session was dead 26 minutes later — making the 03:00 daily fire frequently arrive at a logged-out tab and fail with `kind:auth`.

This spec defines a **third launchd job** (`com.pattybot.cards-keepalive`) that fires every ~5 minutes and injects minimal synthetic activity (`Page.bringToFront` + 1–3 px scroll) on the Amex and Chase offers tabs of the daemon Chrome, with the goal of resetting the bank's idle timer and extending session life from ~30 minutes to whatever the bank's absolute timeout is (unknown; assumed ≥ several hours; possibly indefinite).

The keepalive also serves as a **passive watchdog**: when probes detect an auth wall, missing tab, or unreachable daemon, it appends a structured event to `state/keepalive-events.jsonl` and (subject to a 6-hour per-issuer cooldown) Telegrams the operator with a screenshot and recovery instructions.

## 2. Effective priority ranking

Original ranking presented to user: **A → C → B → D** (detection-quietness → recoverability → session-survival → simplicity).

Updated ranking after user selected synthetic keepalive (Approach I) to enable autonomous operation: **B → A → C → D**. The choice of synthetic activity injection is itself a conscious trade-off of A (quietness) for B (survival). The design minimizes detection footprint *within* the constraint that activity must occur.

| Letter | Meaning | What it implies in this design |
|---|---|---|
| **B** | Session survival / autonomy | Keepalive cadence ≤ 5 min (well below Amex/Chase idle); jitter on top |
| **A** | Detection-quietness | Single event type per iteration; 1–3 px randomized scroll; counter-scroll to prevent visual drift |
| **C** | Recoverability | Telegram on first failure of each kind; cooldown prevents spam; jsonl trail for post-mortem |
| **D** | Code simplicity | One bash script, one plist, no in-memory state, no learning loop |

## 3. Constraints (non-negotiable, inherited from `cards/CLAUDE.md`)

These constraints apply to the keepalive script the same way they apply to the existing fire workflow:

- **No programmatic login on bank sites.** Risk: account lockout.
- **No typing into any input field.** Keystroke timing is a behavioral signature.
- **No clicks outside activate-offer buttons.** Extended here: this includes "are you still there?" idle-warning modals — keepalive does not dismiss them. (If a modal blocks the page, the session was already dying.)
- **No `browser-use close --all` anywhere.** Daemon Chrome lifetime is launchd's responsibility.
- **No fake foreground via CDP** (`Page.setWebLifecycleState`). `Page.bringToFront` IS allowed (real OS-level activation).
- **No per-iteration retries.** The next iteration is the retry.
- **HTML, not Markdown, for Telegram.** Escape pipeline (`& → &amp;`, `< → &lt;`, `> → &gt;`) applied last.

## 4. Architecture

### 4.1 Three-job topology

```
┌────────────────────────────────┐    ┌─────────────────────────────┐
│ com.pattybot.cards-bot-chrome  │    │ com.pattybot.cards-keepalive│
│ KeepAlive=true                 │◄───┤ StartInterval=300 (NEW)     │
│ Persistent profile, port 19223 │CDP │ bin/cards-keepalive.sh      │
└──────────────▲─────────────────┘    └─────────────────────────────┘
               │                                    ▲
               │ CDP                                │ reads
               │                                    │ fire-in-progress.lock
┌──────────────┴─────────────────┐                  │
│ com.pattybot.credit-card-offers│──────────────────┘ writes
│ StartCalendarInterval=03:00    │ (plist unchanged; the script it invokes,
│ bin/cards-fire.sh (MODIFIED)   │  cards-fire.sh, is modified to also park
│                                │  tabs and write/remove the lock)
└────────────────────────────────┘
```

### 4.2 Concurrency model

- **Bot Chrome (KeepAlive=true)** is the shared resource. All three jobs read its CDP socket.
- **`state/fire-in-progress.lock`** is the keepalive's "stay out of the way" signal. `cards-fire.sh` writes it at start and removes it on `trap EXIT INT TERM`.
- **Lock is *advisory*, not OS-enforced.** The lock file's first whitespace-delimited token is the fire's PID. Keepalive does a **PID-alive check first** (`kill -0 <pid>`): if the holder is alive AND the lock is younger than the 60-min stale cap, defer; otherwise proceed. If the holder PID is dead or unparseable, proceed regardless of lock age. The 60-min cap exists only as a defense against PID reuse (where a dead fire's PID happens to be reassigned to an unrelated process). This is more correct than mtime-only and accommodates legitimate long fires (the `credit-card-offers` skill has no built-in time cap).
- **No exclusive lock on the CDP socket itself.** Multiple connections to `/json` and to webSocketDebuggerUrls are explicitly OK. The lock coordinates *behavior* (don't bringToFront during a fire), not socket access.

### 4.3 Why not co-locate keepalive logic inside `cards-fire.sh`

Considered and rejected. The fire runs daily; keepalive runs every 5 min. Co-locating means either (a) invoking the full claude/skill flow every 5 min (cost-prohibitive), or (b) adding mode flags to the wrapper (complexity for no gain). A separate plist with `StartInterval=300` is idiomatic and matches the twitter package precedent.

## 5. Components

### 5.1 `bin/cards-keepalive.sh` (new)

**Type:** bash + embedded `/usr/bin/python3` (for `websocket-client`).
**Sizing:** ~150 LOC.
**Contract:**

- Runs as a **single one-shot iteration** per launchd invocation. No internal loop.
- Touches Chrome only via CDP read-only operations + one `Page.bringToFront` + one `Runtime.evaluate("window.scrollBy(...)")` per tracked tab.
- Mutates only its own state files: `state/keepalive-events.jsonl`, `state/auth-notify-cooldown.json`, and `state/screenshots/keepalive-*.png`.
- Never touches `last-success.json`, `last-failure.json`, dedup files, or any file owned by the fire.
- Telegrams only on state transitions to a failure kind, subject to 6h-per-issuer cooldown.

**Iteration sequence:**

1. Sleep `$((RANDOM % 60))` for cadence jitter (0–60s).
2. Check `state/fire-in-progress.lock`. PID-alive primary (`kill -0 <pid>`): if the holder is alive AND `mtime` < 60-min cap → exit 0 silently. Otherwise proceed with appropriate log line.
3. Read tail of `state/keepalive-events.jsonl` (last 2 entries per issuer) to determine `prev` state per issuer.
4. CDP enumerate: `GET http://127.0.0.1:19223/json` → filter `type=page` tabs by URL substring (`americanexpress.com`, `chase.com`).
5. For each tracked tab:
   - Open websocket to `webSocketDebuggerUrl`.
   - `Page.bringToFront`.
   - `Runtime.evaluate("window.scrollBy(0, 1 + Math.floor(Math.random()*3));")` — 1–3 px forward.
   - Sleep 250 ms.
   - `Runtime.evaluate("window.scrollBy(0, -2);")` — counter-scroll. Prevents long-term visual drift.
   - `Runtime.evaluate(probe_js)` — returns `{visibilityState, hasPwInput, url}`.
   - Close websocket.
6. State diff per issuer. If unchanged → silent. If changed → append jsonl entry.
7. If transitioned to a notifiable failure kind (`auth-wall`, `tab-missing`, `daemon-down`), check `state/auth-notify-cooldown.json`. If cooldown elapsed: capture screenshot, build Telegram, send via `dotfiles/twitter/bin/lib/telegram-send.sh`, atomic-write new cooldown.

**Exit codes:**
- `0` ran healthily (or honored lock-skip)
- `1` config error (state dir unwritable, etc.) — also written to launchd stderr
- `2` daemon Chrome unreachable

### 5.2 `bin/cards-fire.sh` (modified)

Three additive changes to the existing wrapper; no other behavior touched.

1. **Write lock at fire start** (after `shlock` acquired):
   ```bash
   LOCK_FILE="$HOME/.claude/skills/credit-card-offers/state/fire-in-progress.lock"
   echo "$$ $(date -u +%FT%TZ)" > "$LOCK_FILE"
   ```
2. **Trap-cleanup the lock on exit:**
   ```bash
   trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
   ```
3. **Park tabs on offers URLs after the fire body completes** (before trap fires the lock removal):
   - Amex tab → `https://global.americanexpress.com/offers/eligible`
   - Chase tab → `https://secure.chase.com/web/auth/dashboard#/dashboard/offers/offerHub`
   - Bounded 5s wait per nav.

### 5.3 `Library/LaunchAgents/com.pattybot.cards-keepalive.plist` (new)

```
Label:                com.pattybot.cards-keepalive
ProgramArguments:     /Users/pattybot/dotfiles/cards/bin/cards-keepalive.sh
StartInterval:        300       (5 min cadence)
RunAtLoad:            true      (kick on bootstrap, no 5-min wait)
ProcessType:          Interactive
StandardOutPath:      ~/Library/Logs/cards-keepalive.out.log
StandardErrorPath:    ~/Library/Logs/cards-keepalive.err.log
EnvironmentVariables: HOME=/Users/pattybot
```

### 5.4 State files (all under existing gitignored `state/`)

**`state/keepalive-events.jsonl`** — append-only, line-atomic JSON-lines (per-line < 4 KB, well under POSIX PIPE_BUF).
```
{"ts":"2026-05-14T08:00:00+00:00","issuer":"amex","prev":"unknown","new":"authed","note":"first-observation"}
{"ts":"2026-05-14T09:15:00+00:00","issuer":"chase","prev":"authed","new":"auth-wall","note":"detected by keepalive","screenshot":".../keepalive-auth-chase-...png"}
{"ts":"2026-05-14T11:42:00+00:00","issuer":"chase","prev":"auth-wall","new":"authed","note":"operator-relogin (inferred)"}
```
**States:** `unknown | authed | auth-wall | tab-missing | vis-error | daemon-down`.

**`state/auth-notify-cooldown.json`** — atomic-write (tmp + rename).
```json
{"amex":"2026-05-14T09:15:00+00:00","chase":null,"daemon":null}
```

**`state/fire-in-progress.lock`** — touch-file. Content informational; mtime is what matters.
```
12345 2026-05-14T03:00:01Z
```

## 6. Data flow

### 6.1 Healthy iteration (silent)

```
launchd → cards-keepalive.sh
  ├ jitter sleep (0–60s)
  ├ test fire-in-progress.lock → absent, continue
  ├ curl 19223/json → list page tabs
  ├ for each tab in [amex, chase]:
  │   ├ WS connect
  │   ├ Page.bringToFront
  │   ├ Runtime.evaluate(scrollBy 1–3 px)
  │   ├ sleep 250 ms
  │   ├ Runtime.evaluate(scrollBy -2)
  │   ├ Runtime.evaluate(probe_js)
  │   └ WS close
  ├ read tail of keepalive-events.jsonl
  ├ diff: prev == probed → no-op
  └ exit 0 (no log line, no Telegram, no state change)
```

End-to-end ~1–2 s. State files untouched on healthy iterations.

### 6.2 Newly detected auth wall

```
... (Flow 6.1 prefix) ...
  ├ probe finds input[type=password] on Amex tab
  ├ diff: prev=authed → new=auth-wall
  ├ append keepalive-events.jsonl entry
  ├ Page.captureScreenshot → state/screenshots/keepalive-auth-amex-<ts>.png
  ├ read auth-notify-cooldown.json
  │     amex.last = "2026-05-14T03:00:00Z", now = "2026-05-14T09:15:00Z"
  │     diff = 6h 15m ≥ 6h → proceed
  ├ build HTML telegram (issuer, ts, screenshot path, runbook URL)
  ├ telegram-send.sh → Telegram API
  ├ on exit 0: atomic-write auth-notify-cooldown.json
  ├ append ~/Library/Logs/cards-keepalive.log: "<ts> amex authed→auth-wall telegram-sent"
  └ exit 0
```

If cooldown blocks: log `throttled`, skip Telegram, but **still append jsonl event**. State is recorded; operator just isn't pinged.

### 6.3 Fire and keepalive timing

```
03:00:00  launchd fires cards-fire.sh
03:00:01  shlock acquired; write fire-in-progress.lock (PID + ISO ts)
03:00:01  trap 'rm -f $LOCK' EXIT INT TERM registered
03:00:02  cards-prefire.sh runs
03:00:30  claude -p credit-card-offers begins ──┐
                                                 │
03:05:00  launchd fires cards-keepalive.sh      │
03:05:42  keepalive wakes (jitter +42s)         │
03:05:42  test fire-in-progress.lock → present  │
03:05:42  stat lock mtime → age 5m 41s          │
                  PID alive + mtime < 60min      │
                  → SKIP                          │
03:05:42  exit 0 silently                       │
                                                 │
03:04:12  fire body completes ◄─────────────────┘
03:04:13  park Amex tab → /offers/eligible
03:04:18  park Chase tab → /dashboard/offers/offerHub
03:04:22  shlock release, trap fires, lock removed
03:04:22  cards-fire.sh exit 0

03:10:00  next keepalive iteration — lock gone, proceeds normally
```

PID-aware lock coordination (60-min mtime cap fallback) means: even if fire OS-kills before trap (power loss, `kill -9`), keepalive observes a dead PID via `kill -0` and resumes on the next iteration with an `orphan-lock proceed` log entry. The 60-min cap is only the tertiary defense against PID reuse.

### 6.4 Other flows

- **Tab missing:** filter returns 0 tabs for an issuer → append jsonl, Telegram (shared cooldown bucket per issuer with auth-wall).
- **Daemon down:** `curl 19223/json` fails → append jsonl with `issuer:"both"`, exit 2, Telegram on `daemon` cooldown key.
- **Recovery:** probe finds `authed` after `auth-wall` → jsonl event with note `"operator-relogin (inferred)"`; **no Telegram** (recovery is silent). (Distinct from `unknown → authed` first-observation, which is also non-notifiable but with note `"first-observation"`; see OD8.)

### 6.5 Atomicity

- `keepalive-events.jsonl`: appends are line-atomic at <4 KB.
- `auth-notify-cooldown.json`: write `<path>.tmp.$$`, then `mv`.
- `fire-in-progress.lock`: ordinary file; stat-then-skip race is acceptable (worst case = one extra-skipped iteration).

## 7. Error handling

### 7.1 Keepalive failure taxonomy

| `kind` | Detection | Per-iteration response | jsonl? | Telegram? | Cooldown key |
|---|---|---|---|---|---|
| `daemon-down` | `curl 19223/json` fails | exit 2 | yes | yes (with cooldown) | `daemon` |
| `tab-missing` | No tab matches issuer URL | continue with other issuer | yes | yes (with cooldown) | `<issuer>` |
| `auth-wall` | Probe finds `input[type=password]` | continue | yes | yes (with cooldown) | `<issuer>` |
| `vis-error` | `document.visibilityState != "visible"` | continue | yes | no — informational | `<issuer>` (informational) |
| `dom-error` | `Runtime.evaluate` throws or returns malformed payload | continue with other issuer | yes | no (transient by design) | (none) |
| `config` | Local state file unreadable, lock dir unwritable, websocket-client missing | exit 1 | best-effort; stderr to launchd | no — local state broken | (none) |

Recovery (e.g. `auth-wall → authed`) is **not** a separate column — it's the next-iteration observation. The transition itself is the recovery record.

### 7.2 What the keepalive deliberately does NOT do on failure

Extending and tightening the SKILL.md "what NOT to do" list:

- **No retries inside an iteration.** CDP timeout, probe throw, Telegram failure — all "next iteration handles it."
- **No clicks.** Including "are you still there?" idle-warning modals. Let them time out.
- **No typing.**
- **No tab opens, no tab closes.** `tab-missing` → notify and stop. Do NOT open a fresh Amex tab — script-initiated tab opening is a Chrome-emitted automation signal.
- **No process management.** No restarting Chrome, no `kill`, no `launchctl bootout`. Daemon Chrome `KeepAlive=true` is its own recovery primitive.
- **No `browser-use` calls of any kind.** Direct CDP only.

### 7.3 Self-protection

Three things the keepalive must never do, because if they happen, the next 03:00 fire's success matters more than the keepalive itself:

1. **Don't hold the CDP socket open across iterations.** Connect, do work, close.
2. **Don't `Page.navigate`.** Park-on-offers is the fire's job (it runs once a day; keepalive runs 288×).
3. **Don't try to be smart on `dom-error`.** Single throw or recurring throw — same handling: jsonl event, no Telegram, keep iterating. Pattern detection is the fire's job.

### 7.4 Idempotency and crash recovery

- **State reconstructed each run** from `keepalive-events.jsonl` tail. No in-memory state across iterations.
- **No locks held across iterations.** The `fire-in-progress.lock` is *checked* by keepalive, never held by it.
- **Crash-safe writes:** jsonl line-atomic appends; cooldown via tmp+rename. A `kill -9` mid-iteration leaves on-disk state at iteration N-1 or iteration N — never in between.

### 7.5 File ownership

Strict single-writer rule (the most important defensive design choice):

- **Fire owns:** `last-success.json`, `last-failure.json`, `pending.json`, `chase-activated.json`, `amex-activated.json`.
- **Keepalive owns:** `keepalive-events.jsonl`, `auth-notify-cooldown.json`, `screenshots/keepalive-*.png`.
- **Lock file is shared signal:** fire writes + removes; keepalive only reads. Never two writers on one file.

Whenever a state file shows weird content: lookup table is "who writes this?" → there's exactly one answer → debug that script.

## 8. Testing & validation

Validation is a staged ladder. Each rung gates the next.

### Rung 1 — Static checks
```bash
bash -n bin/cards-keepalive.sh
plutil -lint Library/LaunchAgents/com.pattybot.cards-keepalive.plist
test -x /usr/bin/python3
/usr/bin/python3 -c "import websocket"
test -x /Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh
shellcheck bin/cards-keepalive.sh   # optional but recommended
```

### Rung 2 — Iteration smoke (no banks)
Run keepalive against `about:blank` in the bot Chrome. Expected: exit 0, `tab-missing` events for both issuers (since neither URL substring matches), Telegram sent on first observation (`unknown → tab-missing` IS notifiable). This rung confirms the full Telegram path end-to-end without touching either bank.

### Rung 3 — Self-test mode
Gated behind `KEEPALIVE_SELFTEST=1`. Inline assertions for three pure-function helpers:

- **Cooldown evaluator:** `last=null` (yes), `last=now-7h` (yes), `last=now-5h` (no), `last=now-6h+1s` (no), `last=now-6h-1s` (yes).
- **State-diff classifier:** `unknown → authed` (not notifiable), `unknown → auth-wall` (notifiable), `authed → auth-wall` (notifiable), `auth-wall → auth-wall` (no-op).
- **Lock-age check:** 0 s old (skip), 29:59 (skip), 30:01 (proceed), 7d (proceed, log "stale lock").

### Rung 4 — Coexistence test
```bash
echo "99999 $(date -u +%FT%TZ)" > state/fire-in-progress.lock
./bin/cards-keepalive.sh        # expect exit 0, silent

touch -t $(date -v-35M +%Y%m%d%H%M) state/fire-in-progress.lock
./bin/cards-keepalive.sh        # expect proceeds (stale lock ignored)

rm state/fire-in-progress.lock
```

### Rung 5 — Failure injection
| Kind | How to induce | Expected |
|---|---|---|
| `daemon-down` | `launchctl bootout` cards-bot-chrome; run keepalive | exit 2, jsonl event, Telegram (first time) |
| `tab-missing` | Manually close Amex tab in bot Chrome; run keepalive | jsonl event, Telegram (first time); Chase still observed normally |
| `auth-wall` | Manually navigate Amex tab to login URL; run keepalive | jsonl event, Telegram (first time) |
| `dom-error` | Inject `delete window.scrollBy` via DevTools; run keepalive | jsonl event, no Telegram |
| `config` | `chmod 000` state dir; run keepalive | exit 1, no Telegram, error in launchd stderr log |
| `vis-error` | Hard to induce reliably; defer to live-soak observation | — |

### Rung 6 — Live bootstrap
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist
launchctl print gui/$(id -u)/com.pattybot.cards-keepalive
tail -f state/keepalive-events.jsonl   # first 30 min: expect silent
```
If a Telegram fires in the first 30 min against a known-good session, abort and debug.

### Rung 7 — Soak
The only validation that meaningfully answers "does this work?":

- 7-day soak with keepalive bootstrapped.
- Track: session-age-at-death distribution (from jsonl), operator interrupt count, MFA challenges on manual logins, "unusual activity" emails from Amex/Chase.
- After 7 days: stay on Approach A, tune cadence, or re-evaluate.

### What we explicitly cannot test pre-deployment

- Whether the cadence avoids bank-side detection (only absence of signals over time proves this).
- Whether `scrollBy(0, 1–3)` actually resets the idle timer (banks don't publish their logic).
- Whether an absolute timeout exists on either issuer.

These are knowledge gaps that only the soak phase can close.

## 9. What this design explicitly does NOT include

- **No credential storage.** Keychain or otherwise. Manual operator login remains the only auth path.
- **No MFA automation.**
- **No autonomous tab opening or closing.** Operator does it via VNC.
- **No automatic Chrome restart.** Daemon `KeepAlive=true` handles process death.
- **No adaptive cadence.** Fixed 5-min + jitter. (Adaptive is Approach C; rejected per priority D.)
- **No watchdog/keepalive separation.** Single script. (Separation is Approach B; rejected per priority D and lack of soak data justifying it.)
- **No cross-browser support.** Cards-bot Chrome on port 19223 is the only target.
- **No per-issuer enable/disable.** Both Amex and Chase tracked together. (Per-issuer plists could be added if needed; not for v1.)

## 10. Out-of-scope (deliberate)

- **Credential storage + scripted login (Option B).** Revisit only if v1 soak data shows Approach A delivers < 4-day median session and operator interrupt frequency is unacceptable.
- **Operator-assisted pre-fire login (Option II).** Could be a fallback if Approach A fails after several weeks.
- **Telegram command bot (Option III).** `/refire`, `/skip`, `/status` style — separate UX project.
- **Splitting the existing `credit-card-offers` skill into per-issuer skills.** Independent refactor; not blocked by this work.

## 11. Open implementation decisions

These are deliberately deferred to the implementation plan (writing-plans skill):

| # | Decision | Default I'd use | Latitude |
|---|---|---|---|
| OD1 | Keepalive interval | 300 s (5 min) | env override allowed |
| OD2 | Jitter window | 0–60 s | env override allowed |
| OD3 | Scroll amount | 1–3 px forward | hardcoded constant; could be env later |
| OD4 | Counter-scroll amount | -2 px | hardcoded |
| OD5 | Notify cooldown | 6 h per key | env override allowed |
| OD6 | Lock coordination | PID-alive check via `kill -0` first; 60-min `mtime` cap as tertiary fallback against PID reuse | hardcoded constants |
| OD7 | Probe timeout per CDP call | 5 s | hardcoded |
| OD8 | First-observation notifiability | `unknown → auth-wall` notifies; `unknown → authed` does not; `unknown → tab-missing` notifies; `unknown → daemon-down` notifies | encoded in state-diff table |
| OD9 | Health-check Telegram format | issuer name, transition, screenshot path, runbook hint | template stays in script |
| OD10 | Log line format | `<ts> <issuer> <prev>→<new> <action>` | one-line, parseable by `awk` |

## 12. Linked files (to be created or modified)

**New:**
- `bin/cards-keepalive.sh`
- `Library/LaunchAgents/com.pattybot.cards-keepalive.plist`
- `state/keepalive-events.jsonl` (created on first event)
- `state/auth-notify-cooldown.json` (created on first notification)

**Modified:**
- `bin/cards-fire.sh` — lock write, trap, park-on-offers
- `.stow-local-ignore` — exclude `docs/`
- `.claude/skills/credit-card-offers/references/runbook.md` — keepalive recovery section
- `.claude/skills/credit-card-offers/SKILL.md` — cross-reference keepalive's bounded action set in "what NOT to do"
- `CLAUDE.md` — three-job topology in "Two-job architecture" section, renamed

**No change:**
- `bin/cards-prefire.sh`
- `bin/lib/activate-chase.sh`
- `bin/lib/activate-amex.sh`
- `Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist`
- `Library/LaunchAgents/com.pattybot.credit-card-offers.plist`

## 13. Definition of done (v1 launch)

The build is "shipped" when:

1. **Rungs 1–5 pass *in the worktree, before merge*** — pre-merge validation gates the merge. Pre-merge rungs execute against the worktree's script (absolute path) without requiring stow or launchctl bootstrap.
2. Merge to main + `stow -t ~ -R cards` + `launchctl bootstrap` happen as a unit only after step 1 is green.
3. **Rung 6** (live bootstrap watch — first 30 min must be silent against a known-good session) passes post-bootstrap.
4. First 24 h of `keepalive-events.jsonl` shows expected event types only (no `config`, no `dom-error` storms, no off-cadence Telegrams).
5. Documentation updates land in `CLAUDE.md`, `SKILL.md`, `runbook.md`.

Validation-before-merge is intentional: pre-merge validation costs only worktree state; post-merge cleanup involves un-bootstrapping, reverting commits, and cookie hygiene. The cost asymmetry justifies the gate order.

Soak success (the bar that determines whether Approach A is the *right* answer) is evaluated at the 7-day and 28-day marks against the metrics enumerated in Rung 7.

---

## 14. Pre-merge validation results (2026-05-13, worktree branch `worktree-cards-keepalive-spec-v2`)

Validation performed against the worktree's `cards/bin/cards-keepalive.sh` (no merge, no stow, no bootstrap).

| Rung | Status | Notes |
|---|---|---|
| **Rung 1 — Static checks** | ✅ PASS | `bash -n` silent for both `cards-keepalive.sh` and `cards-fire.sh`; `plutil -lint` on plist returns `OK`; `/usr/bin/python3` + `websocket-client` + twitter telegram helper all present. |
| **Rung 2 — about:blank smoke** | ⏭️ SKIPPED | Requires VNC to change a bot Chrome tab to a non-bank URL. Operator can run manually if desired. |
| **Rung 3 — Selftest** | ✅ PASS | `KEEPALIVE_SELFTEST=1 cards/bin/cards-keepalive.sh` → `selftest: 26/26 passed`. (Plan literal `25/25` predates Task 2 Z-suffix fix; 26 is the correct count after Tasks 2 cooldown(7) + Task 3 state-diff(9) + Task 4 lock-age(4) + Task 6 probe(6) = 26 + 1 harness = 27 wait, recount.) Actually the breakdown is: harness 1 + cooldown 6 + state-diff 9 + lock-age 4 + probe 6 = 26. ✓ |
| **Rung 4 — Coexistence (PID-aware)** | ✅ PASS | Synthetic lock with alive PID → silent skip exit 0. Alive PID + 65-min mtime → proceeds with `"PID reuse?"` log line. Dead PID (999999) → proceeds with `"orphan-lock proceed"` log line. Lock cleanup works. |
| **Rung 5 — Failure injection** | ⚠️ PARTIAL | `config` kind tested: `chmod 000 state-dir` → keepalive exits 1 with `state dir not writable` stderr. **Caught a real bug** during this rung — `mkdir -p` returns 0 on existing chmod-000 dirs; fix committed as `f96342a` (added `[[ -w "$STATE_DIR" ]]` writability check). Other Rung 5 kinds (`daemon-down`, `tab-missing`, `auth-wall`, `dom-error`) skipped — daemon-down requires `launchctl bootout` of the production daemon (avoidable disruption); the rest require VNC. |

### Live-flow incidental observations

Task 9's live one-shot run already exercised the auth-wall and vis-error code paths against the production daemon:
- Amex: `unknown → auth-wall` (Telegram sent — real signal, the tab is at the login wall)
- Chase: `unknown → vis-error` (silent per OD8)
- Idempotency: second iteration recorded no new events.

### Recommendation

Proceed to Task 15 (merge + stow + bootstrap + Rung 6) given Rungs 1/3/4/partial-5 are green. Operator should accept that the skipped rungs (Rung 2 about:blank, Rung 5 daemon-down/tab-missing/auth-wall/dom-error) will be validated either via live operation post-bootstrap or by running them manually after VNC.

## 15. Issue #1 correction (2026-05-14)

The original v1 keepalive design assumed `Page.bringToFront` plus a tiny DOM scroll would reset issuer idle timers. Live evidence showed that assumption was wrong: DOM-only activity produced no bank HTTP traffic, and Amex/Chase sessions still expired before the next daily fire.

The implementation now performs a current-page reload followed by a same-origin credentialed `fetch(location.href, {cache: "no-store"})` from inside each tracked bank tab after the foreground/scroll poke and before the state probe. This keeps the endpoint generic and issuer-owned instead of hardcoding private bank heartbeat URLs, while still creating authenticated server-side activity that can reset idle timers.

Verification note: the first Issue #1 patch used only `fetch(location.href)`. During a 2026-05-14 assisted verification, Amex still expired at `2026-05-14T17:07:50Z`, about 16 minutes after relogin, despite successful heartbeat fetches. The current-page reload was added after that failed verification.

With the heartbeat in place, `document.visibilityState === "hidden"` is no longer treated as a keepalive failure by itself. The state probe now classifies a tab as authed when there is no password input and the heartbeat did not fail, even if Chrome is backgrounded.

Two adjacent fixes also landed:

- `com.pattybot.credit-card-offers` now fires at 15:00 local time, not 03:00.
- A live `fire-in-progress.lock` PID is always deferred, even when the lock is older than the stale cap. Old live locks are logged as `stale-lock defer` for investigation; keepalive no longer races a potentially active cards fire.
- Chase is parked on the stable dashboard URL, and the skill enters offers by clicking the dashboard `See your offers` CTA. Direct `#/dashboard/offers/offerHub` navigation can render a signed-in but blank Chase shell.
