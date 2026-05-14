#!/bin/bash
# cdp-screenshot.sh — minimal Page.captureScreenshot primitive.
#
# Why this exists separate from cdp-eval.sh:
#   Page.captureScreenshot is a distinct CDP method that returns base64 image
#   data, not a JS value. Folding it into cdp-eval would require ugly special-
#   casing.
#
# Reads (env):
#   DAEMON_PORT             — default 19223
#   TARGET_URL_SUBSTRING    — required, picks the tab to screenshot
#   LABEL                   — short tag for the filename, default "shot"
#   SCREENSHOT_DIR          — default ~/.claude/skills/credit-card-offers/state/screenshots
#
# Writes single-line JSON to stdout:
#   { "ok": true,  "path": "/abs/path/to/file.png" }
#   { "ok": false, "kind": "...", "message": "..." }
#
# Exit code: always 0.

set -uo pipefail

PYTHON_BIN="/usr/bin/python3"
DAEMON_PORT="${DAEMON_PORT:-19223}"
LABEL="${LABEL:-shot}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$HOME/.claude/skills/credit-card-offers/state/screenshots}"

: "${TARGET_URL_SUBSTRING:?TARGET_URL_SUBSTRING is required}"
mkdir -p "$SCREENSHOT_DIR"

DAEMON_PORT="$DAEMON_PORT" \
TARGET_URL_SUBSTRING="$TARGET_URL_SUBSTRING" \
LABEL="$LABEL" \
SCREENSHOT_DIR="$SCREENSHOT_DIR" \
  "$PYTHON_BIN" - <<'PY'
import json, os, sys, time, base64, urllib.request
from datetime import datetime, timezone

try:
    import websocket
except ImportError:
    print(json.dumps({"ok": False, "kind": "config", "message": "websocket-client missing"}))
    sys.exit(0)

PORT = os.environ["DAEMON_PORT"]
TARGET = os.environ["TARGET_URL_SUBSTRING"]
LABEL = os.environ["LABEL"]
SHOT_DIR = os.environ["SCREENSHOT_DIR"]


def emit(ok, **kw):
    print(json.dumps({"ok": ok, **kw}))
    sys.exit(0)


try:
    tabs = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=3).read())
except Exception as e:
    emit(False, kind="ws-error", message=f"CDP /json: {e}")
if not isinstance(tabs, list):
    emit(False, kind="dom-error", message="CDP /json non-list")
page_tabs = [t for t in tabs if t.get("type") == "page" and TARGET in (t.get("url") or "")]
if not page_tabs:
    emit(False, kind="no-tab", message=f"no tab matching {TARGET!r}")
ws_url = page_tabs[0].get("webSocketDebuggerUrl")
if not ws_url:
    emit(False, kind="dom-error", message="tab has no webSocketDebuggerUrl")

try:
    ws = websocket.create_connection(ws_url, suppress_origin=True, timeout=5)
except Exception as e:
    emit(False, kind="ws-error", message=f"ws connect: {e}")

try:
    ws.send(json.dumps({"id": 1, "method": "Page.captureScreenshot", "params": {"format": "png"}}))
    deadline = time.time() + 10
    b64 = None
    while time.time() < deadline:
        ws.settimeout(max(0.05, deadline - time.time()))
        r = json.loads(ws.recv())
        if r.get("id") == 1:
            b64 = r.get("result", {}).get("data")
            break
    ws.close()
    if not b64:
        emit(False, kind="dom-error", message="screenshot returned no data")
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(SHOT_DIR, f"{LABEL}-{ts}.png")
    with open(path, "wb") as f:
        f.write(base64.b64decode(b64))
    if os.path.getsize(path) == 0:
        os.unlink(path)
        emit(False, kind="dom-error", message="screenshot file is 0 bytes")
    emit(True, path=path)
except Exception as e:
    emit(False, kind="ws-error", message=f"screenshot: {e}")
PY
