# WhatsApp Digest Runbook

## Install

```bash
cd ~/dotfiles
stow -t ~ -R whatsapp-digest

cd ~/.local/share/whatsapp-digest
npm install
npm test
```

## Configure MCP

Use the example at:

```text
~/.claude/skills/whatsapp-digest/references/mcp.example.json
```

Add the `whatsapp-digest` server to the MCP config for the host that will run the digest, then restart that host so it discovers the new MCP tools.

## First Login

Run the visible-browser auth wrapper:

```bash
~/bin/whatsapp-digest-auth
```

It opens the same WhatsApp MCP session with a non-headless browser and also writes QR/auth output to stderr. Scan the QR from:

```text
WhatsApp > Settings > Linked Devices > Link a Device
```

Prefer scanning the QR shown in the Chrome/WhatsApp Web window. The server also writes fallback QR artifacts:

```text
~/.local/state/whatsapp-digest/qr.png
~/.local/state/whatsapp-digest/qr.txt
```

If the terminal QR is hard to scan, open the PNG:

```bash
open ~/.local/state/whatsapp-digest/qr.png
```

The QR refreshes periodically; the PNG path is overwritten with the latest code.

The auth wrapper auto-opens the refreshed PNG by default. To avoid that and scan only the browser-rendered QR:

```bash
WHATSAPP_DIGEST_OPEN_QR=false ~/bin/whatsapp-digest-auth
```

Useful diagnostic milestones:

- `whatsapp-digest: WhatsApp Web session authenticated` means the phone scan reached this session.
- `whatsapp-digest: loading ...` means WhatsApp Web is restoring after auth.
- `whatsapp-digest: WhatsApp Web session ready` means the persisted session is ready for group discovery.

If QR codes rotate but none of those lines appear, the scan did not reach this browser session.

### Pairing-Code Fallback

If QR linking does not work, use WhatsApp's phone-number pairing flow instead:

```bash
~/bin/whatsapp-digest-pair '+12125550100'
```

Use the WhatsApp account phone number with country code. The command prints:

```text
whatsapp-digest: WhatsApp pairing code: ABCD-EFGH
```

On the phone, choose:

```text
WhatsApp > Settings > Linked Devices > Link a Device > Link with phone number instead
```

and enter the printed code. The same `authenticated`, `loading`, and `ready` milestones apply.

After `whatsapp-digest: WhatsApp Web session ready`, stop the foreground process with `Ctrl-C`. The session persists under:

```text
~/.local/state/whatsapp-digest/auth
```

After auth is complete, the normal headless MCP and digest commands reuse that persisted session.

## First Group Discovery

After the WhatsApp Web session is ready, run:

```bash
~/bin/whatsapp-digest-groups
```

This reads:

```text
~/.claude/skills/whatsapp-digest/references/groups.example.json
```

and writes candidate matches to:

```text
~/.claude/skills/whatsapp-digest/references/groups.discovered.json
```

Then copy `groups.example.json` to `groups.json` and fill each `groupId` with the exact returned group JID ending in `@g.us`.

## First Read Test

Call `whatsapp_read_group_messages` for one group:

```json
{
  "groupId": "120363...@g.us",
  "limit": 50
}
```

Success criteria:

- Returns the expected group name.
- Returns recent messages with `id`, `senderId`, `sentAt`, `text`, `type`, `hasMedia`, and `fromMe`.
- Muted groups are still readable.

## Known Limitations

- WhatsApp history availability is governed by WhatsApp Web sync. If a group has not synced enough history, the digest can only summarize what the Web session can see.
- QR login requires human action.
- The MCP server is read-only. Sending WhatsApp messages is intentionally out of scope for the digest.
