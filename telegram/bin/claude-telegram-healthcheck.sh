#!/bin/bash
# claude-telegram-healthcheck.sh
#
# Runs every 5 min via launchd (com.pattybot.claude-telegram-healthcheck).
# Checks the standalone receiver's persisted heartbeat. A missing or stale
# heartbeat means polling is unhealthy, so kickstart the supervised daemon.
#
# Why this is needed: launchd supervises the main daemon's `script` +
# claude parent, but NOT claude's MCP subprocesses. Bun can silently die
# while claude stays alive, leaving Telegram deaf. Worse, an ad-hoc
# interactive `claude` session that loads the telegram plugin will spawn
# its own bun, which SIGTERMs the supervised bun (server.ts enforces
# single-poller via bot.pid) and reparents the Telegram token to itself.
# The supervised claude then stays alive but Telegram-deaf, and a naive
# "is bun parented by *a* claude?" check happily passes. This script
# closes both gaps.
#
# Respawn is idempotent — launchctl kickstart -k uses the main daemon's
# own ThrottleInterval/KeepAlive policy, so we won't thrash even if bun
# keeps failing to come up.
#
# All events logged to the unified system log via `logger`:
#   log show --predicate 'process == "logger"' --last 1h | grep claude-telegram-healthcheck

set -uo pipefail

MAIN_LABEL="com.pattybot.claude-telegram"
HEARTBEAT="/Users/pattybot/.claude/channels/telegram/receiver-state/heartbeat.json"

now=$(/bin/date +%s)
mtime=$(/usr/bin/stat -f %m "$HEARTBEAT" 2>/dev/null || echo 0)
age=$((now - mtime))

if [ "$mtime" -eq 0 ] || [ "$age" -gt 180 ]; then
  /usr/bin/logger -t claude-telegram-healthcheck "receiver heartbeat missing/stale age=${age}s; kickstarting $MAIN_LABEL"
  /bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/$MAIN_LABEL"
fi

exit 0
