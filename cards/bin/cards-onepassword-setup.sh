#!/bin/bash
# Retired after migration to Hermes on 2026-09-20.
printf '%s\n' "Retired: cards now run through Hermes. Use hermes cron list and the credit-card-offers skill; do not provision a separate Keychain token." >&2
exit 64

# One-time, interactive setup. Secret values are never accepted as arguments.
set -euo pipefail

export HOME="/Users/pattybot"
OP="$HOME/.local/bin/op"
CONFIG="$HOME/.config/cards/onepassword.conf"
SERVICE="com.pattybot.cards.1password-service-account"
KEYCHAIN="$HOME/.local/bin/cards-keychain"

[ -x "$OP" ] || { echo "missing $OP" >&2; exit 1; }
[ -x "$KEYCHAIN" ] || { echo "missing $KEYCHAIN" >&2; exit 1; }

echo "Use the existing AI agents 1Password vault containing the Chase and Amex Login items."
echo "Grant a service account read_items only on AI agents (no write/share/create-vault access)."
read -r -s -p "Paste the one-time service-account token (input hidden): " TOKEN
echo
printf '%s' "$TOKEN" | "$KEYCHAIN" set
TOKEN=""

read -r -p "Chase Login item base ref (op://AI agents/Item): " CHASE_ITEM
read -r -p "Amex Login item base ref (op://AI agents/Item): " AMEX_ITEM
for ref in "$CHASE_ITEM" "$AMEX_ITEM"; do
  [[ "$ref" == op://*/* ]] || { echo "invalid 1Password item reference" >&2; exit 2; }
done

TOKEN=$("$KEYCHAIN" get)
export OP_SERVICE_ACCOUNT_TOKEN="$TOKEN"
CHASE_OTP_REF=""
AMEX_OTP_REF=""
if "$OP" read --no-newline "$CHASE_ITEM/one-time%20password" >/dev/null 2>&1; then
  CHASE_OTP_REF="$CHASE_ITEM/one-time%20password"
fi
if "$OP" read --no-newline "$AMEX_ITEM/one-time%20password" >/dev/null 2>&1; then
  AMEX_OTP_REF="$AMEX_ITEM/one-time%20password"
fi

echo "Validating references without printing secret values..."
for ref in "$CHASE_ITEM/username" "$CHASE_ITEM/password" "$AMEX_ITEM/username" "$AMEX_ITEM/password"; do
  value=$("$OP" read --no-newline "$ref")
  [ -n "$value" ] || { echo "empty field: $ref" >&2; exit 3; }
  value=""
done

umask 077
mkdir -p "$(dirname "$CONFIG")"
tmp="$CONFIG.tmp.$$"
trap 'rm -f "$tmp"' EXIT
{
  printf 'CHASE_USERNAME_REF=%s/username\n' "$CHASE_ITEM"
  printf 'CHASE_PASSWORD_REF=%s/password\n' "$CHASE_ITEM"
  printf 'CHASE_OTP_REF=%s\n' "$CHASE_OTP_REF"
  printf 'AMEX_USERNAME_REF=%s/username\n' "$AMEX_ITEM"
  printf 'AMEX_PASSWORD_REF=%s/password\n' "$AMEX_ITEM"
  printf 'AMEX_OTP_REF=%s\n' "$AMEX_OTP_REF"
} > "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$CONFIG"
trap - EXIT

unset TOKEN OP_SERVICE_ACCOUNT_TOKEN value
echo "1Password setup complete: $CONFIG"
