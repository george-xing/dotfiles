# CLAUDE.md

This package contains the standalone WhatsApp digest automation. It intentionally does not depend on OpenClaw.

## What this package is

A GNU Stow package (`whatsapp-digest/`) whose files mirror `$HOME`:

| In repo | Symlinked to |
|---|---|
| `bin/whatsapp-digest-mcp` | `~/bin/whatsapp-digest-mcp` |
| `.local/share/whatsapp-digest/*` | `~/.local/share/whatsapp-digest/*` |
| `.claude/skills/whatsapp-digest/*` | `~/.claude/skills/whatsapp-digest/*` |

After adding or moving files, refresh links with:

```bash
cd ~/dotfiles && stow -t ~ -R whatsapp-digest
```

## Architecture

- `~/.local/share/whatsapp-digest/src/server.js` is a stdio MCP server.
- The server uses `whatsapp-web.js` with `LocalAuth` and a persistent auth directory at `~/.local/state/whatsapp-digest/auth`.
- The MCP surface is read-only:
  - `whatsapp_status`
  - `whatsapp_list_groups`
  - `whatsapp_read_group_messages`
- Digest composition and Telegram delivery should live in the `whatsapp-digest` Claude skill, borrowing state/audit/send patterns from `twitter-digest`.

## Common Commands

```bash
cd ~/dotfiles/whatsapp-digest/.local/share/whatsapp-digest
npm install
npm test

cd ~/dotfiles && stow -t ~ -R whatsapp-digest

# Run the MCP server directly. It prints QR/auth logs to stderr.
~/bin/whatsapp-digest-mcp
```

## Runtime State

Do not commit runtime state:

- `~/.local/state/whatsapp-digest/auth` — WhatsApp Web session credentials.
- `~/.claude/skills/whatsapp-digest/state` — digest cursors, audits, pending send state, failures.

## Development Notes

- Keep MCP stdout clean. Log QR codes, auth messages, and errors to stderr only.
- Keep the MCP server read-only unless the user explicitly asks for WhatsApp sends.
- Unit-test normalization and dispatch behavior without a live WhatsApp session.
- Live validation requires a QR scan from the user's WhatsApp app.
