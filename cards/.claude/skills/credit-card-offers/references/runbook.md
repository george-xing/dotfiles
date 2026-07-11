# credit-card-offers — runbook

Operational reference. `SKILL.md` owns the post-login offer workflow;
`bin/cards-auth.py` exclusively owns authentication and sign-out.
The normal post-login path is browser-aware and agentic. If Codex is
unavailable because of model capacity, authentication, or usage limits,
`cards-fire.sh` invokes the validated deterministic CDP fallback so the daily
bank job does not depend on model credits.

## One-time bootstrap

1. Stow the package and start the dedicated Chrome:

   ```bash
   cd ~/dotfiles && stow -t ~ -R cards
   ~/dotfiles/cards/bin/cards-bot-chrome-setup.sh
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-bot-chrome.plist
   ```

2. In 1Password, create a dedicated non-built-in vault containing only the
   Chase and Amex Login items. Service accounts cannot access Personal,
   Private, Employee, or the default Shared vault. Grant the service account
   `read_items` only; do not grant write/share/create-vault permissions.

3. Run the CLI-only interactive provisioner. It registers/signs in the CLI,
   creates `pattybot-cards-mac-mini` with `read_items` only, and pipes the
   one-time token into Login Keychain without printing it or using an argument:

   ```bash
   ~/dotfiles/cards/bin/cards-onepassword-provision.sh
   ```

   Supply each base reference as `op://Vault/Item`. The generated config at
   `~/.config/cards/onepassword.conf` contains references only and is mode
   `0600`. If a Login item has a `one-time password` field, TOTP is enabled
   automatically. Otherwise, SMS/push/CAPTCHA remains a manual challenge.

4. Smoke-test without reading secrets or submitting forms:

   ```bash
   ~/dotfiles/cards/bin/cards-auth.py self-test
   ~/dotfiles/cards/bin/cards-auth.py login --dry-run
   ~/dotfiles/cards/bin/cards-fire.sh credit-card-offers --dry-run
   ```

5. After one successful live run, load the daily job. Keepalive must remain
   unloaded because every fire now signs in fresh and signs out afterward:

   ```bash
   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.cards-keepalive.plist 2>/dev/null || true
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pattybot.credit-card-offers.plist
   ```

## Authentication invariants

- Secrets are resolved just-in-time through `op read` using the vault-scoped
  service account held in Login Keychain.
- Username, password, TOTP, and service-account token are never logged,
  persisted in state, passed as shell arguments, or embedded in evaluated JS.
- Each bank login form is submitted at most once per fire. A rejection is not
  retried.
- Only one unambiguous TOTP input plus one unambiguous confirmation control may
  be automated. SMS, push, CAPTCHA, device verification, and ambiguous flows
  stop safely and trigger a Telegram notice.
- Challenge screenshots are captured only after password/OTP-like inputs are
  cleared.
- Logout is successful only after the login wall is observed again.

## Enforced agent boundary

Only deterministic authentication runs with access to the 1Password service
account. `cards-fire.sh` starts the post-login Codex process through macOS
`sandbox-exec` with `config/cards-agent.sb`. The agent and every child process
are denied:

- the cards `op://` reference configuration and 1Password application state;
- `op`, `cards-keychain`, `security`, `osascript`, and authentication code;
- Keychain/securityd IPC, including from a copied or newly compiled helper;
- writes to the sandbox, wrapper, fallback, skill, launchd plist, credential
  tooling, shell startup files, SSH configuration, and LaunchAgents.

CDP on port 19223, state/dedup files, screenshots, Telegram delivery, and
Codex network access remain available. The deterministic fallback is reviewed
code, not a model process, and runs outside this agent sandbox after login.

The boundary smoke test should show the broker succeeding outside the sandbox,
failing inside it, secret config unreadable, and CDP allowed. Never print or
persist the broker output while testing.

## Manual challenge recovery

For `kind:mfa` or `kind:challenge`, open the cards Chrome on the Mac mini and
complete the displayed challenge. Then re-run once:

```bash
~/dotfiles/cards/bin/cards-fire.sh credit-card-offers
```

Do not repeatedly submit passwords or codes. The automation deliberately does
not guess MFA methods, dismiss consent screens, or bypass challenges.

## Rotation and revocation

`cards-onepassword-setup.sh` remains available for token rotation when a new
service account has already been created. Revoke the old service account after
confirming the replacement works. If the Mac mini is lost or compromised,
revoke the service account and terminate the bank sessions immediately.

## Schedule and inspection

The checked-in plist fires daily at 03:00 local time. Verify the loaded copy:

```bash
launchctl print gui/$(id -u)/com.pattybot.credit-card-offers | sed -n '/event triggers/,/event channels/p'
```

Manual launchd-equivalent fire:

```bash
launchctl kickstart -p gui/$(id -u)/com.pattybot.credit-card-offers
```

## Logs and state

- `~/Library/Logs/cards-fire.log` — authentication metadata and offer run log;
  never secret values.
- `~/Library/Logs/credit-card-offers.launchd.{out,err}.log` — launchd errors.
- `~/.claude/skills/credit-card-offers/state/last-success.json` — last digest
  success.
- `~/.claude/skills/credit-card-offers/state/last-failure.json` — categorized
  failure.
- `~/.claude/skills/credit-card-offers/state/screenshots/` — mode-0600
  challenge/DOM forensics.

Common failure kinds: `config`, `onepassword`, `browser`, `auth`, `mfa`,
`challenge`, `dom`, `logout`, `telegram`, `busy`, and `prefire`.
