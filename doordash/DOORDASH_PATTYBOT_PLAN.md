# DoorDash CLI + Claude Telegram Pattybot

Status: CLI installed and authenticated; Claude-to-CLI integration self-test passed; no account data was read and no DoorDash mutation or order was performed.

## Architecture

Pattybot is the standalone Claude Telegram receiver, not OpenClaw:

```text
Telegram bot
  -> com.pattybot.claude-telegram LaunchAgent
  -> telegram-receiver.ts
  -> fresh authenticated `claude -p` process
  -> ~/.claude/skills/dd-cli-usage/SKILL.md
  -> ~/.local/bin/dd-cli
  -> DoorDash OAuth token in Pattybot's macOS Keychain
```

The LaunchAgent runs in Pattybot's Aqua session, which is required for `dd-cli` to access macOS Keychain. Headless Codex and SSH processes cannot use the CLI credential even when the Keychain is unlocked.

## Completed validation

- Installed `dd-cli` v0.2.0 at `~/.local/bin/dd-cli` on Apple Silicon macOS.
- Verified the release archive against DoorDash's published SHA-256:
  `cd6502c1704d12b7d7e9b64dc58fda7efac1a7765a7e0eb887260f7a7dcc6442`.
- Completed DoorDash browser OAuth for the approved account.
- Stored OAuth credentials in the local Keychain service `dd-cli`, account `oauth-tokens`.
- Installed and validated the `dd-cli-usage` skill in Claude's actual skill directory.
- Ran an end-to-end test through Pattybot's exact Claude setup-token wrapper and GUI/Keychain context.
- Claude successfully ran authenticated `dd-cli order --help` and returned the available order commands.
- Disabled the unused `ai.openclaw.gateway` LaunchAgent because it was competing for the same Telegram bot and causing continuous `getUpdates` 409 conflicts.
- Confirmed the standalone Claude receiver is the only remaining Telegram poller and has a fresh heartbeat.

## Available CLI functionality

- Search nearby restaurants.
- Browse menus and item details.
- Search grocery and retail stores/items.
- Create, inspect, add to, and remove from carts.
- Preview a cart's pricing without charging.
- View order history and receipts and create a reorder cart.
- Generate a browser checkout URL.
- Submit an order directly.
- Check submitted order status.
- Read saved address and payment-method metadata.
- Emit structured JSON using `--json-output`.

The installed Claude skill tells Pattybot to discover exact leaf syntax with `--help` instead of guessing.

## Version 1 behavior

Both George and Michelle may:

- Search restaurants or stores.
- Compare menus and items.
- Suggest choices.
- Add or remove cart items.
- Review a final cart and pricing preview.

Only George's Telegram user ID (`7953915703`) may request:

- Saved address or payment information.
- Order history, receipts, or reorders.
- A checkout URL or another purchase-related action.

Version 1 never runs `order submit`. After an exact preview and explicit owner confirmation, Pattybot may generate a checkout URL for George to complete in DoorDash. Any cart or total change invalidates the confirmation and requires another preview.

## Important constraints

- The repository distributes a closed, ad-hoc-signed binary. It is not Developer ID signed or notarized; the installer re-signs it locally and removes quarantine.
- v0.2.0 is very new and has reported input-validation and inconsistent-error bugs. Pattybot must reject missing store identities, unpaired coordinates, negative/unbounded limits, and ambiguous success responses.
- DoorDash treats agent actions as the account owner's actions and may not provide another confirmation before direct CLI checkout.
- CLI use is personal, non-commercial, and restricted to the authenticated account. Michelle may collaborate but may not act as the account owner or independently authorize payment.
- Do not automate tobacco, cannabis, or controlled products. Alcohol is permitted under the normal owner-only checkout and explicit-confirmation safeguards.
- Merchant allergen/dietary data is not authoritative.
- Prices, availability, fees, tips, credits, promotions, ETAs, and totals may change at checkout.
- DoorDash's CLI terms restrict storage and retention of menu, price, address, payment, and order data. The skill prohibits writing raw CLI output to files, memory, databases, or logs and tells Claude to retain only transaction-minimum context.

## Remaining hardening

1. Capture Michelle's numeric Telegram user ID from her next group message and add George + Michelle explicitly to the group sender allowlist. The group is currently restricted by chat ID but permits any member of that chat.
2. Update `telegram-receiver.ts` so group messages are described as coming from their real sender instead of the legacy sentence saying every message came from George. The skill already uses the trusted numeric `Sender:` field as a workaround.
3. Replace the receiver's broad `--dangerously-skip-permissions` posture with a scoped tool policy or a dedicated DoorDash command wrapper if Pattybot should enforce financial boundaries independently of model instructions.
4. Add automated tests for owner/collaborator authorization, changed-cart reconfirmation, duplicate requests, stale confirmation, CLI error envelopes, and auth expiry.
5. Decide whether hosted-model and Telegram retention satisfy DoorDash's CLI terms or obtain clarification/zero-retention controls.

Direct `order submit` should remain disabled until items 1-4 are implemented and an observed low-cost test order succeeds through the checkout-URL flow.
