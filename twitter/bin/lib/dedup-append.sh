#!/bin/bash
# dedup-append.sh — atomic JSON array append for the twitter skills.
#
# Reads:
#   DEDUP_FILE       — path to JSON file (array of {url, digestedAt})
#   DEDUP_URLS_JSON  — JSON array of URL strings to add
#   DEDUP_TTL_DAYS   — optional; prune entries older than N days before append
#
# Writes the merged file atomically (PID-suffixed tmp + os.replace).
# Idempotent: duplicate URLs are NOT re-added.
# Preserves entry order. Prints final count to stdout.

set -uo pipefail

: "${DEDUP_FILE:?DEDUP_FILE is required}"
: "${DEDUP_URLS_JSON:?DEDUP_URLS_JSON is required (JSON array of URL strings)}"

mkdir -p "$(dirname "$DEDUP_FILE")"

DEDUP_TTL_DAYS="${DEDUP_TTL_DAYS:-}" python3 - <<'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone

path = os.environ["DEDUP_FILE"]
new_urls = json.loads(os.environ["DEDUP_URLS_JSON"])
ttl_days_str = os.environ.get("DEDUP_TTL_DAYS", "")
ttl_days = int(ttl_days_str) if ttl_days_str else None

now = datetime.now(timezone.utc)

existing = []
if os.path.exists(path) and os.path.getsize(path):
    with open(path) as f:
        existing = json.load(f)

if ttl_days is not None:
    cutoff = now - timedelta(days=ttl_days)
    existing = [e for e in existing if datetime.fromisoformat(e["digestedAt"]) >= cutoff]

seen = {e["url"] for e in existing}
for u in new_urls:
    if u and u not in seen:
        existing.append({"url": u, "digestedAt": now.isoformat()})
        seen.add(u)

# PID-suffixed tmp so concurrent writers (if the shared flock ever fails)
# can't clobber each other on the way to os.replace.
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w") as f:
    json.dump(existing, f)
os.replace(tmp, path)
print(len(existing))
PY
