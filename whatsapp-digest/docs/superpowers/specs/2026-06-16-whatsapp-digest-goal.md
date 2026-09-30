# WhatsApp Digest Goal Spec

Use this with `/goal` as the source of truth:

```text
Execute /Users/pattybot/dotfiles/whatsapp-digest/docs/superpowers/specs/2026-06-16-whatsapp-digest-goal.md until every success criterion is satisfied. Do not use OpenClaw. Continue through live WhatsApp QR auth, group discovery, daily digest implementation, Telegram delivery, launchd scheduling, and verification.
```

## Objective

Build and run a reliable daily automation that reads selected muted WhatsApp group chats, summarizes important activity, and sends a concise Telegram digest to CrabbyPatty.

## Non-Negotiables

- Do not depend on OpenClaw, its runtime, its config, or its WhatsApp plugin.
- Use the standalone `whatsapp-digest-mcp` server in this package as the WhatsApp access layer.
- Keep WhatsApp MCP tools read-only unless the user explicitly authorizes outbound WhatsApp sending later.
- Do not commit WhatsApp auth/session state, Telegram tokens, runtime logs, or digest state.
- Use Telegram HTML delivery through the hardened helper at `/Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh`.
- Advance WhatsApp cursors only after Telegram delivery succeeds.
- Preserve existing unrelated dirty work in `~/dotfiles`; do not revert or include it in commits for this work.

## Current State

The first MCP spike exists in `/Users/pattybot/dotfiles/whatsapp-digest`:

- `bin/whatsapp-digest-mcp` - stow-managed wrapper for the MCP server.
- `.local/share/whatsapp-digest/src/server.js` - stdio MCP server.
- `.local/share/whatsapp-digest/src/whatsapp-session.js` - `whatsapp-web.js` session manager.
- `.local/share/whatsapp-digest/src/tool-definitions.js` - read-only MCP tool schemas.
- `.local/share/whatsapp-digest/src/tools.js` - group listing and group message reading.
- `.local/share/whatsapp-digest/src/normalize.js` - stable data normalization.
- `.claude/skills/whatsapp-digest/SKILL.md` - digest skill shell.
- `.claude/skills/whatsapp-digest/references/runbook.md` - QR/auth/group-discovery runbook.
- `.claude/skills/whatsapp-digest/references/groups.example.json` - target group template.
- `.claude/skills/whatsapp-digest/references/mcp.example.json` - MCP config example.

Verified on 2026-06-16:

```bash
cd /Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest
npm test
npm run check:deps
```

Expected current result:

- `npm test`: 11 tests pass.
- `npm run check:deps`: prints `dependency imports ok`; a Node `punycode` deprecation warning from dependencies is acceptable.

## Target Groups

Start with the groups visible in the screenshot:

- PEF NYC
- PEF Health & Wellness
- PEF AI Experimentation
- PEF Finance & Markets
- PEF SF / Bay Area
- PEF Job Board
- Founders Club NY

Group IDs must be discovered from WhatsApp after QR auth and written to:

```text
/Users/pattybot/dotfiles/whatsapp-digest/.claude/skills/whatsapp-digest/references/groups.json
```

Use `groups.example.json` as the template. Each enabled group must have:

```json
{
  "name": "PEF AI Experimentation",
  "query": "PEF AI",
  "groupId": "120363...@g.us",
  "enabled": true
}
```

## Success Criteria

The goal is complete only when all of these are true:

1. `whatsapp-digest-mcp` is installed via stow and reachable at `/Users/pattybot/bin/whatsapp-digest-mcp`.
2. A WhatsApp Web QR login has been completed and persists under `/Users/pattybot/.local/state/whatsapp-digest/auth`.
3. The MCP host can call:
   - `whatsapp_status`
   - `whatsapp_list_groups`
   - `whatsapp_read_group_messages`
4. All target group IDs are filled in `groups.json`.
5. At least one live `whatsapp_read_group_messages` call returns real recent messages from a target group.
6. A dry-run digest can read all enabled groups, cluster/scorify messages, write an audit, and print Telegram HTML without sending.
7. A live digest sends one Telegram message to CrabbyPatty and writes success state.
8. Cursors are updated only for messages included in a successful run window.
9. A launchd job exists and can trigger the same code path as manual live fire.
10. The final verification commands pass:

```bash
cd /Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest
npm test
npm run check:deps

/Users/pattybot/bin/whatsapp-digest-fire --dry-run
/Users/pattybot/bin/whatsapp-digest-fire --live-test
launchctl kickstart -p gui/$(id -u)/com.pattybot.whatsapp-digest
```

## Required Implementation Phases

### Phase 1: Live MCP Validation

Install and link the package:

```bash
cd /Users/pattybot/dotfiles
stow -t /Users/pattybot -R whatsapp-digest

cd /Users/pattybot/.local/share/whatsapp-digest
npm install
npm test
npm run check:deps
```

Run the MCP server directly and scan the QR:

```bash
/Users/pattybot/bin/whatsapp-digest-mcp
```

Expected behavior:

- QR/auth logs print to stderr, not stdout.
- After scan, stderr prints `whatsapp-digest: WhatsApp Web session ready`.
- Auth state appears under `/Users/pattybot/.local/state/whatsapp-digest/auth`.

Then configure the MCP server in the host using:

```text
/Users/pattybot/.claude/skills/whatsapp-digest/references/mcp.example.json
```

Restart the MCP host and verify tool calls.

### Phase 2: Group Discovery

Call `whatsapp_list_groups` with queries from `groups.example.json`:

```json
{ "query": "PEF", "limit": 100 }
```

```json
{ "query": "Founders", "limit": 100 }
```

Create `groups.json` from `groups.example.json` and fill `groupId` values with exact `@g.us` IDs.

Verify one group read:

```json
{
  "groupId": "120363...@g.us",
  "limit": 50
}
```

Expected output includes real `messages[]` with `id`, `chatId`, `senderId`, `sentAt`, `text`, `type`, `hasMedia`, and `fromMe`.

### Phase 3: Digest Runtime

Create:

- `/Users/pattybot/dotfiles/whatsapp-digest/bin/whatsapp-digest-fire`
- `/Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest/src/digest-cli.js`
- `/Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest/src/group-config.js`
- `/Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest/src/cursors.js`
- `/Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest/src/audit.js`
- `/Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest/src/compose-digest.js`
- focused tests in `/Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest/test/`

Behavior:

- Load `groups.json`.
- Load `state/group-cursors.json`.
- Read messages from every enabled group.
- Convert messages into candidate items.
- Cluster by actual topic/thread.
- Select important material:
  - direct asks
  - ticket/event logistics
  - jobs and hiring leads
  - finance/markets signal
  - AI/coding-agent/tooling signal
  - local recommendations
  - high-volume threads with a clear outcome
- Reject low-signal chatter, acknowledgements, repeated jokes, stale logistics, and unsupported media-only messages.
- Write `state/candidate-audits/<runAt>.json` before Telegram send.
- Write `state/pending.json` before Telegram send.
- On Telegram success, atomically update `state/group-cursors.json` and `state/last-success.json`, then remove `pending.json`.
- On failure, write `state/last-failure.json` and do not advance cursors.

Digest output must be Telegram HTML with a plain-text fallback file:

```text
<b>WhatsApp digest - DATE</b>

🔥 <b>Needs attention</b>
• <b>PEF NYC</b>: Harry asked whether anyone has June 25 tickets. Reply if you can help.

💼 <b>Jobs and opportunities</b>
• <b>PEF Job Board</b>: Thread about MS program candidates; useful hiring lead.

—
N groups scanned · M messages reviewed
```

Escape dynamic strings for Telegram HTML: `&`, `<`, `>`.

### Phase 4: Telegram Delivery

Use:

```bash
TELEGRAM_CHAT_ID=7953915703 \
TELEGRAM_MESSAGE_FILE="$RUN_DIR/digest.html" \
TELEGRAM_MESSAGE_PLAIN_FILE="$RUN_DIR/digest.txt" \
RUN_DIR="$RUN_DIR" \
  /Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh
```

Do not retry outside that helper. Follow the helper exit codes:

- `0`: sent successfully; advance cursors.
- `1`: Telegram rejected HTML and plain-text fallback; write `kind:"telegram"`.
- `2`: curl/network/local parse failure; write `kind:"telegram"` and do not retry.

### Phase 5: launchd Scheduling

Create:

```text
/Users/pattybot/dotfiles/whatsapp-digest/Library/LaunchAgents/com.pattybot.whatsapp-digest.plist
```

Recommended schedule:

- Once daily at 08:30 America/New_York unless the user chooses a different time.

The job should run:

```bash
/Users/pattybot/bin/whatsapp-digest-fire
```

The wrapper must:

- Export `HOME=/Users/pattybot`.
- Use absolute paths.
- Log to `/Users/pattybot/Library/Logs/whatsapp-digest.log`.
- Acquire a lock so overlapping runs exit cleanly.
- Support `--dry-run` and `--live-test`.

## Tests To Add

Use TDD for each behavior. Required test coverage:

- `group-config.test.js`: rejects missing `groupId` for enabled groups.
- `cursors.test.js`: advances per-group cursor only to the max shipped/read timestamp after success.
- `audit.test.js`: audit contains every considered group/message and selected/rejected outcome.
- `compose-digest.test.js`: escapes Telegram HTML and omits empty sections.
- `digest-cli.test.js`: dry-run does not write success cursors or call Telegram.
- `telegram-delivery.test.js`: success updates state; failure preserves cursors.

The existing tests must continue passing:

```bash
cd /Users/pattybot/dotfiles/whatsapp-digest/.local/share/whatsapp-digest
npm test
```

## Operational Failure Taxonomy

Write `state/last-failure.json` with `kind`, `at`, and `message`:

- `auth`: WhatsApp session not ready, QR required, or session expired.
- `mcp`: MCP server unavailable or malformed response.
- `group_config`: enabled group missing ID or ID is not a group.
- `read`: group read failed.
- `empty`: no enabled group produced new messages.
- `telegram`: Telegram send failed.
- `cursor`: Telegram succeeded but cursor/state update failed.

## Definition Of Done

The automation is done when a fresh run has:

1. Read real messages from the configured WhatsApp groups.
2. Produced a digest with useful clustered summaries.
3. Sent that digest to Telegram.
4. Persisted audit, cursors, pending/success/failure state correctly.
5. Been triggered once manually and once through launchd.
6. Left no committed runtime secrets or auth state.

Do not mark the goal complete before those six conditions are verified in the current session.
