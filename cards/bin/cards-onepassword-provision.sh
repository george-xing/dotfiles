#!/bin/bash
# Interactive CLI-only provisioning for the cards automation.
# Account password, Secret Key, session token, service token, and bank secrets
# are never printed or passed in command arguments.
set -euo pipefail

export HOME="/Users/pattybot"
export PATH="$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
OP="$HOME/.local/bin/op"
KEYCHAIN="$HOME/.local/bin/cards-keychain"
KEYCHAIN_SOURCE="$(dirname "$(realpath "$0")")/cards-keychain.swift"
CONFIG="$HOME/.config/cards/onepassword.conf"
VAULT="Pattybot"
SERVICE_ACCOUNT_NAME="pattybot-cards-mac-mini"

[ -x "$OP" ] || { echo "missing signed 1Password CLI at $OP" >&2; exit 1; }
if [ ! -x "$KEYCHAIN" ] || [ "$KEYCHAIN_SOURCE" -nt "$KEYCHAIN" ]; then
  echo "===> Building the local Keychain helper"
  TMP_HELPER="$KEYCHAIN.tmp.$$"
  xcrun swiftc -O "$KEYCHAIN_SOURCE" -o "$TMP_HELPER"
  /usr/bin/codesign --force --sign - "$TMP_HELPER" >/dev/null 2>&1
  chmod 700 "$TMP_HELPER"
  mv "$TMP_HELPER" "$KEYCHAIN"
fi

echo "===> 1Password CLI sign-in"
if [ "$("$OP" account list --format json | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -eq 0 ]; then
  echo "No CLI account is registered. 1Password will securely prompt for account details."
  echo "IMPORTANT: the account Secret Key must start with A3-. Do not enter an ops_ service-account token."
  eval "$("$OP" account add --signin)"
else
  eval "$("$OP" signin)"
fi

echo "===> Validating dedicated vault and discovering Login items"
"$OP" vault get "$VAULT" >/dev/null
DISCOVERY=$(OP_BIN="$OP" VAULT="$VAULT" /usr/bin/python3 - <<'PY'
import json, os, subprocess
op, vault = os.environ["OP_BIN"], os.environ["VAULT"]
summaries = json.loads(subprocess.check_output([op, "item", "list", "--vault", vault, "--format", "json"], text=True))
matches = {"chase": [], "amex": []}
for summary in summaries:
    item = json.loads(subprocess.check_output([op, "item", "get", summary["id"], "--vault", vault, "--format", "json"], text=True))
    field_names = " ".join(str(f.get("id", "")) + " " + str(f.get("label", "")) for f in item.get("fields", [])).lower()
    has_login_fields = "username" in field_names and "password" in field_names
    if not has_login_fields:
        continue
    urls = " ".join(str(u.get("href", "")) for u in item.get("urls", []))
    haystack = (str(item.get("title", "")) + " " + urls).lower()
    if "chase" in haystack:
        matches["chase"].append(item["id"])
    if "amex" in haystack or "americanexpress" in haystack or "american express" in haystack:
        matches["amex"].append(item["id"])
if len(matches["chase"]) != 1 or len(matches["amex"]) != 1:
    raise SystemExit(2)
print(matches["chase"][0])
print(matches["amex"][0])
PY
) || {
  echo "Expected exactly one Chase credential and one Amex credential in vault '$VAULT', identifiable by title or website URL." >&2
  exit 2
}
CHASE_ITEM_ID=$(printf '%s\n' "$DISCOVERY" | sed -n '1p')
AMEX_ITEM_ID=$(printf '%s\n' "$DISCOVERY" | sed -n '2p')
unset DISCOVERY

echo "===> Creating read_items-only service account"
TOKEN=$("$OP" service-account create "$SERVICE_ACCOUNT_NAME" --vault "$VAULT:read_items" --raw)
trap 'TOKEN=""; unset TOKEN OP_SERVICE_ACCOUNT_TOKEN' EXIT
[ -n "$TOKEN" ] || { echo "1Password returned an empty service-account token" >&2; exit 3; }

echo "===> Unlocking Login Keychain for the one-time token transfer"
/usr/bin/security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"
printf '%s' "$TOKEN" | "$KEYCHAIN" set
export OP_SERVICE_ACCOUNT_TOKEN="$TOKEN"

CHASE_BASE="op://$VAULT/$CHASE_ITEM_ID"
AMEX_BASE="op://$VAULT/$AMEX_ITEM_ID"
for ref in "$CHASE_BASE/username" "$CHASE_BASE/password" "$AMEX_BASE/username" "$AMEX_BASE/password"; do
  value=$("$OP" read --no-newline "$ref")
  [ -n "$value" ] || { echo "required Login field is empty" >&2; exit 4; }
  value=""
done
CHASE_OTP_REF=""
AMEX_OTP_REF=""
"$OP" read --no-newline "$CHASE_BASE/one-time%20password" >/dev/null 2>&1 && CHASE_OTP_REF="$CHASE_BASE/one-time%20password" || true
"$OP" read --no-newline "$AMEX_BASE/one-time%20password" >/dev/null 2>&1 && AMEX_OTP_REF="$AMEX_BASE/one-time%20password" || true

umask 077
mkdir -p "$(dirname "$CONFIG")"
TMP="$CONFIG.tmp.$$"
trap 'rm -f "${TMP:-}"; TOKEN=""; unset TOKEN OP_SERVICE_ACCOUNT_TOKEN' EXIT
{
  printf 'CHASE_USERNAME_REF=%s/username\n' "$CHASE_BASE"
  printf 'CHASE_PASSWORD_REF=%s/password\n' "$CHASE_BASE"
  printf 'CHASE_OTP_REF=%s\n' "$CHASE_OTP_REF"
  printf 'AMEX_USERNAME_REF=%s/username\n' "$AMEX_BASE"
  printf 'AMEX_PASSWORD_REF=%s/password\n' "$AMEX_BASE"
  printf 'AMEX_OTP_REF=%s\n' "$AMEX_OTP_REF"
} > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$CONFIG"
TMP=""

TOKEN=""
unset TOKEN OP_SERVICE_ACCOUNT_TOKEN value OP_SESSION
trap - EXIT
echo "Provisioning complete: read-only service account stored in Keychain; reference-only config written."
