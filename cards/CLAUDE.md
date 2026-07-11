# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A GNU Stow package (`cards/`) inside `~/dotfiles`. Running `stow -t ~ -R cards` symlinks every file back to its mirrored path under `$HOME`:

| In repo | Symlinked to |
|---|---|
| `bin/cards-fire.sh` | `~/bin/cards-fire.sh` |
| `bin/cards-prefire.sh` | `~/bin/cards-prefire.sh` |
| `bin/cards-auth.py` | `~/bin/cards-auth.py` |
| `bin/cards-keychain.swift` | `~/bin/cards-keychain.swift` |
| `bin/cards-onepassword-provision.sh` | `~/bin/cards-onepassword-provision.sh` |
| `bin/cards-onepassword-setup.sh` | `~/bin/cards-onepassword-setup.sh` |
| `bin/cards-bot-chrome-setup.sh` | `~/bin/cards-bot-chrome-setup.sh` |
| `bin/cards-keepalive.sh` | `~/bin/cards-keepalive.sh` |
| `Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist` | `~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist` |
| `Library/LaunchAgents/com.pattybot.credit-card-offers.plist` | `~/Library/LaunchAgents/com.pattybot.credit-card-offers.plist` |
| `Library/LaunchAgents/com.pattybot.cards-keepalive.plist` | `~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist` |
| `.claude/skills/credit-card-offers/{SKILL,references/*}.md` | `~/.claude/skills/credit-card-offers/...` |

Editing the symlinked path and editing the file inside this repo are the same operation — both write through to the repo. After altering the directory layout (adding/moving files), rerun `stow -t ~ -R cards` to refresh links.

There is no build, lint, or test step. The codebase is bash + macOS launchd plists + Markdown skill files.

## Three-job architecture

Mirrors the twitter package's two-job pattern, extended to three. Three launchd jobs cooperate:

1. **`com.pattybot.cards-bot-chrome`** — `KeepAlive: true`, runs `Google Chrome.app` with `--user-data-dir=~/Library/Application Support/cards-bot-chrome --remote-debugging-port=19223`. **Always running.** This is the only Chrome the offers workflow talks to. It is signed in fresh for each daily fire and explicitly signed out afterward.
2. **`com.pattybot.credit-card-offers`** — `StartCalendarInterval` at 03:00 local time daily, fires `bin/cards-fire.sh credit-card-offers`. `RunAtLoad=false` so a fresh launchctl-bootstrap doesn't trigger a mid-day fire against bank sites — only the next 03:00.
3. **`com.pattybot.cards-keepalive`** — legacy and intentionally unloaded. Daily 1Password login + explicit logout replaced session keepalive.

The fire wrapper is split into two pieces, structurally identical to twitter:

- **`bin/cards-prefire.sh`** — OS plumbing only. Health-checks `http://127.0.0.1:19223/json/version` for up to 12s; disambiguates the cards bot Chrome from the twitter bot Chrome and the user's daily Chrome via `lsof -iTCP:19223 -sTCP:LISTEN -t`; CDP-unminimizes bot Chrome windows; pre-warms System Events; PID-activates the bot Chrome with a 30s timeout; bounded-polls activation settlement. Emits `SAVED_FRONTMOST_PID=<pid>` as its final stdout line. Does NOT invoke claude or touch Telegram.
- **`bin/cards-fire.sh <skill-name>`** — orchestrator. It calls prefire, runs `cards-auth.py login` using least-privilege 1Password references, runs the browser-aware skill through `codex exec` inside the macOS Seatbelt profile `config/cards-agent.sb`, falls back to the validated `cards-offers.py` browser driver only when the model service is unavailable, and always runs `cards-auth.py logout` after a live attempt.

The keepalive wrapper is a separate one-shot:

- **`bin/cards-keepalive.sh`** — one iteration per launchd invocation. Reads `state/fire-in-progress.lock` and skips if a fire is active (PID-alive check first via `kill -0`; 60-min `mtime` cap as a tertiary fallback against PID reuse). Otherwise: discover tracked tabs via CDP, per-tab `Page.bringToFront` + 1–3 px scroll + counter-scroll + probe, diff against `state/keepalive-events.jsonl` tail, append event on state change, Telegram on notifiable transitions (subject to per-issuer 6h cooldown). Does not log in, type, click, retry, navigate, or open/close tabs. See spec for full taxonomy.

The skill (`.claude/skills/credit-card-offers/SKILL.md`) is the actual work: CDP-attach, navigate to Chase Offers hub + Amex Offers, click "Add to card" on every unactivated offer, dedup against `state/{chase,amex}-activated.json`, deliver summary to Telegram.

## Why cards is its own package (vs. living under twitter)

- **Different security posture**: banks aggressively pattern-match high-frequency identical sessions; sharing the twitter Chrome's profile would mix fingerprints and increase re-auth rate.
- **Different daemon lifetime**: cards Chrome is opened to a Chase tab + Amex tab and stays there; twitter Chrome is on x.com/home.
- **Different port**: 19223 (cards) vs 9222 (twitter) vs 19222 (kalalau).
- **Independent failure domain**: a twitter Chrome cookie expiry shouldn't affect the cards fire and vice versa.

## Structural debt — shared helpers

The cards SKILL.md calls **twitter's** `bin/lib/telegram-send.sh` and `bin/lib/dedup-append.sh` by absolute path. Those helpers are package-generic (no twitter-specific code) but live in the twitter repo for historical reasons. **When a third consumer needs them, lift to `~/dotfiles/common/bin/lib/`** and update absolute-path references in both twitter and cards SKILL.md files. Until then, the cross-package reference is the documented choice (vs. duplicate-and-drift or extract-now-while-twitter-is-stable).

Cards-specific helpers live in `bin/lib/` — kept deliberately TINY and DOM-agnostic. All DOM specifics live in `SKILL.md` so the agent can adapt at runtime when banks ship UI changes.
- `cdp-eval.sh` — generic Runtime.evaluate primitive (find tab by URL substring, evaluate JS expression, return JSON value). Zero DOM knowledge.
- `cdp-screenshot.sh` — generic Page.captureScreenshot primitive for forensics.

Earlier versions had `activate-amex.sh` / `activate-chase.sh` with hardcoded selectors and a probe-only mode. Those were removed because banking DOMs change too often to bake into bash; the agentic SKILL.md driver replaced them.

## Operational source of truth

Two reference files document operational behavior:

- `.claude/skills/credit-card-offers/SKILL.md` — full step-by-step skill workflow, failure-kind taxonomy, "what NOT to do" list (added phase 3).
- `.claude/skills/credit-card-offers/references/runbook.md` — manual-fire commands, daemon control, TCC permission setup, log paths, re-auth procedure.

## Common commands

```bash
# Refresh stow symlinks (after adding/moving/renaming files in the repo)
cd ~/dotfiles && stow -t ~ -R cards

# One-time bootstrap (interactive)
~/dotfiles/cards/bin/cards-bot-chrome-setup.sh
~/dotfiles/cards/bin/cards-onepassword-provision.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist

# Then VNC into the Mac mini, sign into chase.com + americanexpress.com
# in the bot Chrome window (cards-bot-chrome, port 19223).

# Smoke-test prefire (verifies daemon, foreground activation)
~/dotfiles/cards/bin/cards-prefire.sh
# Last line: SAVED_FRONTMOST_PID=<pid>

# Smoke-test end-to-end without sending to Telegram
~/dotfiles/cards/bin/cards-fire.sh credit-card-offers --dry-run
tail -50 ~/Library/Logs/cards-fire.log

# Manual live fire (sends to Telegram)
~/dotfiles/cards/bin/cards-fire.sh credit-card-offers

# Load / unload the daily cron job
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.credit-card-offers.plist
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.credit-card-offers.plist

# Trigger via launchd (same code path as the 03:00 local fire)
launchctl kickstart -p gui/$(id -u)/com.pattybot.credit-card-offers

# Daemon Chrome control (NEVER use Cmd-Q or `osascript ... quit` — those
# can hit the wrong Chrome instance, and KeepAlive would respawn anyway)
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist

# Keepalive control (5-min cadence, RunAtLoad=true so first iteration is
# immediate on bootstrap; safe to bootout/bootstrap any time).
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist

# Manual one-shot keepalive iteration (no plist needed; useful for debugging)
~/dotfiles/cards/bin/cards-keepalive.sh

# Self-test mode (runs pure-function assertions; safe to run anytime)
KEEPALIVE_SELFTEST=1 ~/dotfiles/cards/bin/cards-keepalive.sh

# Inspect keepalive activity
tail -50 ~/Library/Logs/cards-keepalive.log
tail -20 ~/.claude/skills/credit-card-offers/state/keepalive-events.jsonl | python3 -m json.tool
```

Logs:
- `~/Library/Logs/cards-fire.log` — main per-fire log (`===== fire <iso> skill=<name> =====` blocks)
- `~/Library/Logs/cards-bot-chrome.{out,err}.log` — daemon Chrome stdout/stderr
- `~/Library/Logs/credit-card-offers.launchd.{out,err}.log` — launchd-level errors for the daily cron job (PATH / permissions / plist syntax)
- `~/Library/Logs/cards-keepalive.log` — state-change events from the 5-min keepalive (silent on healthy iterations)
- `~/Library/Logs/cards-keepalive.{out,err}.log` — keepalive stdout/stderr (launchd-level)

## Editing rules specific to this package

- **State directory is gitignored.** `**/state/` matches `~/.claude/skills/credit-card-offers/state/`. It holds `last-success.json`, `last-failure.json`, `pending.json`, `chase-activated.json`, `amex-activated.json` — none of those should ever be committed. The dedup files double as a privacy-sensitive activity log of which merchants you've been offered.
- **Dedup is offer-ID-keyed, no TTL.** Unlike twitter-digest's 7d URL TTL, the cards dedup keeps every activated offer ID forever. Bank offers expire on their own; once activated, the offer remains activated for the operator until expiration. The dedup file doubles as audit log.
- **Wrapper paths are absolute on purpose.** `bin/cards-fire.sh` and `bin/cards-prefire.sh` hardcode the Codex CLI, system Python, 1Password CLI, and CDP helper paths. launchd's PATH is minimal; relying on `PATH` lookup will silently break under launchd. Same for `HOME` — both wrappers `export HOME=/Users/pattybot` before referencing `$HOME`.
- **macOS python3 vs Homebrew python3.** The pre-fire CDP un-minimize block pins `/usr/bin/python3` explicitly because it has `websocket-client` available via the system user-site while `/opt/homebrew/bin/python3` does not. Don't "simplify" that to bare `python3`.
- **Plist `ProcessType: Interactive`** on both jobs is required so the daemon Chrome is allowed to render and the wrapper is allowed to script System Events. Don't downgrade it to `Background`.
- **`KeepAlive: true` on the bot-chrome plist implies an initial speculative launch**, so `RunAtLoad` is intentionally absent.
- **HTML, not Markdown, when delivering to Telegram.** Merchant names routinely contain `_*[` (e.g. "Brooks_Brothers"); legacy Telegram Markdown breaks on these. The escape pipeline (`& → &amp;`, `< → &lt;`, `> → &gt;`, applied last) is critical — don't reorder it.
- **Login is isolated to `bin/cards-auth.py`.** It resolves secret-reference URIs with a read-only, vault-scoped 1Password service account, submits each login at most once, automates only an unambiguous TOTP field, redacts inputs before screenshots, and never prints secret values. Do not add credential handling to the skill or shell wrappers.
- **The agent boundary is enforced, not prompt-only.** `config/cards-agent.sb`
  denies the Codex process and its children access to 1Password, Login
  Keychain/securityd, credential helpers/config, auth code, and security
  control files while retaining CDP/state/Telegram access. Authentication and
  the reviewed deterministic fallback run outside that model sandbox.
- **NEVER click anything but the activate-offer buttons.** Mid-run action set is exactly: enumerate offer tiles, click "Add to card" on each unactivated one, verify state change, record. Clicking ANY other button (even dismiss-y "Got it" / "Continue" / "OK" prompts) is forbidden — those can commit you to TOS/consent terms and are behavioral signatures.

## What "fixing it" usually does NOT mean

Operational failures here will fall into a small set of root causes (`auth`, `mfa`, `challenge`, `dom`, `telegram`, `partial`, `visibility`, `empty` — see SKILL.md once it's in place). Before writing code in response to a failure:

1. Read `~/.claude/skills/credit-card-offers/state/last-failure.json` and the screenshot it points at.
2. Match `kind` against the failure-kind table — most cases need an operator action (re-login on Mac mini, update a selector), not a code change.
3. **Avoid these "fixes" — banking sites punish them harder than X does**:
   - Typing into ANY input field, including non-credential ones (search boxes, card nicknames). Pattern-detectable.
   - Auto-dismissing modals by selector — even harmless-looking ones can be "agree to terms" prompts.
   - Programmatic login of any kind.
   - Faking foreground state via CDP — same reasoning as twitter; banks check `document.visibilityState` for fraud signals.
   - Retrying clicks on stuck offers — banks count failed activations and may flag the account.
   - Hourly-or-more-frequent runs — daily is fine, anything faster invites pattern detection.
