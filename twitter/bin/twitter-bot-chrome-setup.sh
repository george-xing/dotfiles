#!/bin/bash
# twitter-bot-chrome-setup.sh — one-time bootstrap for the persistent bot Chrome.
#
# What this does:
#   1. Verify port 9222 isn't already taken (would prevent the daemon from binding).
#   2. Create the persistent user-data-dir at the canonical path.
#   3. Print the launchctl bootstrap command + the manual sign-in instructions.
#
# What this deliberately doesn't do:
#   - Copy cookies from your real Chrome profile. We learned that route brings WAL
#     corruption hazards and produces cookies with weird provenance. Instead, the
#     daemon launches with an empty profile and you sign into X interactively in
#     the bot Chrome window once. That window stays open under launchd; cookies
#     accumulate naturally with correct provenance.
#   - Quit any running Chrome. We don't touch the user's daily Chrome at all.
#     Two Chrome.app instances with different --user-data-dirs coexist fine
#     (Chromium's process singleton is keyed to the data dir).

set -euo pipefail

PERSISTENT_DIR="$HOME/Library/Application Support/twitter-bot-chrome"
PLIST="$HOME/Library/LaunchAgents/com.pattybot.twitter-bot-chrome.plist"
DEBUG_PORT=9222

echo "===> twitter-bot-chrome bootstrap"
echo

# 1. Port collision guard. If something is already on 9222 the daemon will
#    fail to bind and KeepAlive-loop indefinitely.
if lsof -nP -iTCP:${DEBUG_PORT} -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ERROR: port ${DEBUG_PORT} is already in use by:" >&2
  lsof -nP -iTCP:${DEBUG_PORT} -sTCP:LISTEN >&2
  echo "Kill that process or pick a different port (edit the plist + this script)." >&2
  exit 1
fi
echo "  ✓ port ${DEBUG_PORT} is free"

# 2. Create the persistent dir. Chrome will populate Default/ on first launch.
mkdir -p "$PERSISTENT_DIR"
echo "  ✓ persistent dir ready: $PERSISTENT_DIR"

# 3. Verify the plist is a symlink that resolves into the dotfiles repo.
#    A plain copy at this path (e.g. from a previous manual install) would
#    still exist but silently drift from the source of truth, so check for
#    the symlink specifically AND verify it points where we expect.
if [ ! -L "$PLIST" ]; then
  echo "ERROR: expected a symlink at $PLIST, found ${PLIST:+something else}" >&2
  echo "Run \`stow -t ~ twitter-digest\` from ~/dotfiles to symlink it." >&2
  exit 1
fi
RESOLVED=$(readlink -f "$PLIST" 2>/dev/null || python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$PLIST")
EXPECTED_PREFIX="$HOME/dotfiles/twitter-digest/"
if [ ! -f "$RESOLVED" ]; then
  echo "ERROR: plist symlink is dangling — resolves to $RESOLVED which doesn't exist" >&2
  exit 1
fi
case "$RESOLVED" in
  "$EXPECTED_PREFIX"*) ;;
  *)
    echo "ERROR: plist symlink resolves outside the dotfiles repo: $RESOLVED" >&2
    echo "Expected it to resolve under $EXPECTED_PREFIX" >&2
    exit 1
    ;;
esac
echo "  ✓ LaunchAgent plist symlink ok: $PLIST -> $RESOLVED"

cat <<EOF

===> Next steps (manual):

1. Load the daemon:
     launchctl bootstrap gui/\$(id -u) "$PLIST"

2. Wait ~3 seconds, then verify the daemon is listening:
     curl -fsS http://127.0.0.1:${DEBUG_PORT}/json/version

   Expected: a JSON blob with "Browser":"Chrome/<version>".

3. A Chrome window will appear (the bot's). Click into it (it'll open to
   chrome://newtab/ or about:blank), navigate to https://x.com/i/flow/login,
   and sign into your X account in that window. The cookies persist forever
   in the bot's user-data-dir at:
     $PERSISTENT_DIR

4. Leave the bot Chrome window foreground (or at least with an active tab on
   x.com/home) at fire times — \`document.visibilityState\` must be "visible"
   for the digest to scrape successfully. The skill hard-fails (no fake
   active state) if the window is backgrounded.

5. Sanity-check end-to-end:
     ~/bin/twitter-fire.sh twitter-digest --dry-run
     tail -50 ~/Library/Logs/twitter-fire.log

   You should see a composed digest in the log without "kind: visibility" or
   "kind: auth" failure entries.

When X eventually invalidates the bot's session (weeks/months from now),
just open the bot Chrome window and sign in again. No reseed script needed.
EOF
