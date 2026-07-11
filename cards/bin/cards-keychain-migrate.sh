#!/bin/bash
# One-time migration from the implicit interactive ACL to a helper-only ACL.
set -euo pipefail
export HOME="/Users/pattybot"
SOURCE="/Users/pattybot/dotfiles/cards/bin/cards-keychain.swift"
HELPER="$HOME/.local/bin/cards-keychain"
NEW="$HELPER.new.$$"
TOKEN=""
trap 'rm -f "$NEW"; TOKEN=""; unset TOKEN' EXIT

echo "Building replacement Keychain helper..."
xcrun swiftc -O "$SOURCE" -o "$NEW"
/usr/bin/codesign --force --sign - "$NEW" >/dev/null 2>&1
chmod 700 "$NEW"

echo "Reading the existing token (macOS may request Keychain approval)..."
TOKEN=$("$HELPER" get)
[ -n "$TOKEN" ] || { echo "existing token was empty" >&2; exit 1; }
"$HELPER" delete
mv "$NEW" "$HELPER"
printf '%s' "$TOKEN" | "$HELPER" set
VERIFY=$("$HELPER" get)
[ "$VERIFY" = "$TOKEN" ] || { echo "Keychain round-trip verification failed" >&2; exit 2; }
VERIFY=""
TOKEN=""
unset TOKEN VERIFY
trap - EXIT
echo "Keychain ACL migration completed."
