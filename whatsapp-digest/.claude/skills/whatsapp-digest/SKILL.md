---
name: whatsapp-digest
description: Generate a daily digest of selected WhatsApp group chats via the standalone whatsapp-digest MCP server and deliver it to Telegram. Use when the user asks for WhatsApp summaries, WhatsApp group digests, PEF/Founders Club chat summaries, or the scheduled daily digest.
---

# WhatsApp Digest

Daily job: read recent messages from configured WhatsApp groups through the standalone `whatsapp-digest-mcp` server, identify important threads, write a candidate audit, compose a Telegram HTML digest, and deliver via the existing hardened Telegram helper.

This skill intentionally does **not** depend on OpenClaw.

## Inputs

- **MCP server**: `~/bin/whatsapp-digest-mcp`, backed by `whatsapp-web.js`.
- **WhatsApp auth state**: `~/.local/state/whatsapp-digest/auth`, created by scanning a QR code from WhatsApp > Linked devices.
- **Group config**: `references/groups.json`, copied from `references/groups.example.json` after the first group discovery.
- **State**: `state/group-cursors.json`, `state/pending.json`, `state/last-success.json`, `state/last-failure.json`, `state/candidate-audits/*.json`.
- **Telegram delivery**: `/Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh`.

## Workflow

1. Confirm MCP auth:
   - Call `whatsapp_status`.
   - If not ready, follow `references/runbook.md` to run the MCP server and scan the QR.

2. Discover or validate groups:
   - Call `whatsapp_list_groups` with queries such as `PEF`, `Founders`, `FCNY`.
   - Update `references/groups.json` with exact group IDs and friendly names.

3. Read group messages:
   - Load `state/group-cursors.json`.
   - For each enabled group, call `whatsapp_read_group_messages` with `groupId`, `limit`, and prior `afterTimestamp`.
   - Keep only messages newer than the cursor.

4. Score and cluster:
   - Prioritize actionable requests, offers, events, jobs, AI/coding-agent discussion, finance/markets signal, local recommendations, and high-volume threads.
   - Drop small talk, repeated acknowledgements, weak banter, and stale logistics unless they close the loop on an important item.
   - Compose dynamic sections by actual topic, not fixed group order.

5. Write candidate audit:
   - Include every candidate thread/message considered, selection outcome, rejection reason, group name, sender, timestamps, and digest section.
   - Write before Telegram send so failures remain inspectable.

6. Deliver to Telegram:
   - Compose HTML and plain text fallback.
   - Use `/Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh`.
   - On success, update group cursors after Telegram delivery.
   - On failure, do not advance cursors.

## Operator Dry Runs

When the user says "dry run", run `~/bin/whatsapp-digest-fire --dry-run` so cursors do not advance, then send the generated `/tmp/whatsapp-digest-run/digest.html` and `.txt` to Telegram using the WhatsApp digest `sendTelegram` helper. This is an operator preview, not the scheduled production fire.

## Digest Shape

Use Telegram HTML, not Markdown.

```text
<b>WhatsApp digest — DATE</b>

🔥 <b>Needs attention</b>
• <b>PEF NYC</b>: Harry asked whether anyone has June 25 tickets. Reply if you can help.

💼 <b>Jobs and opportunities</b>
• <b>PEF Job Board</b>: Thread about MS program candidates; useful hiring lead.

🤖 <b>AI and tools</b>
• <b>PEF AI Experimentation</b>: Discussion about model behavior and prompting strategy.

—
N groups scanned · M messages reviewed
```

Always attribute group and, when useful, sender. Avoid presenting WhatsApp claims as verified facts.

## Failure Kinds

- `mcp` — MCP server unavailable or tool call failed.
- `auth` — WhatsApp Web session not ready or QR login needed.
- `group_config` — configured group ID missing or not a group.
- `empty` — no new messages across enabled groups.
- `telegram` — Telegram send failed.
- `cursor` — cursor update failed after successful send.
