#!/bin/bash
# cdp-eval.sh — minimal CDP Runtime.evaluate primitive.
#
# Why this exists:
#   The credit-card-offers skill drives offer activation agentically. Claude
#   reads the page, decides what to click, writes the JS, and calls this
#   primitive to send it to Chrome. Everything DOM-specific lives in Claude's
#   reasoning at runtime — this primitive only handles transport plumbing.
#
#   One CDP roundtrip per call: find tab by URL substring, open ws, send
#   Runtime.evaluate, close ws, print JSON. No internal state, no retries,
#   no decisions.
#
# Reads (env):
#   DAEMON_PORT             — Chrome CDP debug port, default 19223
#   TARGET_URL_SUBSTRING    — required, picks the first page tab whose URL
#                              contains this substring (e.g. "americanexpress.com")
#   EXPRESSION              — required, JS expression to evaluate. Will be
#                              wrapped in returnByValue + awaitPromise.
#   AWAIT_PROMISE           — "true" (default) or "false". Set "false" for
#                              synchronous expressions if you want it faster.
#   BRING_TO_FRONT          — "yes" (default) or "no". When yes, calls
#                              Page.bringToFront before the evaluate (legitimate
#                              OS-level activation, not Page.setWebLifecycleState).
#
# Writes single-line JSON to stdout:
#   { "ok": true,  "value": <returned JS value> }
#   { "ok": false, "kind": "ws-error"|"dom-error"|"no-tab"|"config",
#                  "message": "...", "value": null }
#
# Exit code: always 0. Inspect "ok" + "kind" to handle failures.
#
# Notes on JS expressions:
#   - The expression is evaluated with returnByValue=true, so the returned
#     value must be JSON-serializable. Wrap complex objects with JSON.stringify
#     if needed, then JSON.parse the value in shell.
#   - Use await freely; AWAIT_PROMISE=true (default) handles Promise-returning
#     expressions transparently.
#   - JS exceptions are reported as kind=dom-error with the exception text.

set -uo pipefail

PYTHON_BIN="/usr/bin/python3"
DAEMON_PORT="${DAEMON_PORT:-19223}"
AWAIT_PROMISE="${AWAIT_PROMISE:-true}"
BRING_TO_FRONT="${BRING_TO_FRONT:-yes}"

: "${TARGET_URL_SUBSTRING:?TARGET_URL_SUBSTRING is required}"
: "${EXPRESSION:?EXPRESSION is required (JS to evaluate)}"

DAEMON_PORT="$DAEMON_PORT" \
TARGET_URL_SUBSTRING="$TARGET_URL_SUBSTRING" \
EXPRESSION="$EXPRESSION" \
AWAIT_PROMISE="$AWAIT_PROMISE" \
BRING_TO_FRONT="$BRING_TO_FRONT" \
  "$PYTHON_BIN" - <<'PY'
import json, os, sys, time, urllib.request

try:
    import websocket
except ImportError:
    print(json.dumps({"ok": False, "kind": "config", "message": "websocket-client missing in /usr/bin/python3", "value": None}))
    sys.exit(0)

PORT = os.environ["DAEMON_PORT"]
TARGET = os.environ["TARGET_URL_SUBSTRING"]
EXPR = os.environ["EXPRESSION"]
AWAIT = os.environ["AWAIT_PROMISE"] == "true"
BTF = os.environ["BRING_TO_FRONT"] == "yes"


def emit(ok, **kw):
    out = {"ok": ok, **kw}
    if "value" not in out:
        out["value"] = None
    print(json.dumps(out))
    sys.exit(0)


# Find tab.
try:
    tabs = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=3).read())
except Exception as e:
    emit(False, kind="ws-error", message=f"CDP /json: {e}")
if not isinstance(tabs, list):
    emit(False, kind="dom-error", message=f"CDP /json returned non-list (got {type(tabs).__name__})")
page_tabs = [t for t in tabs if t.get("type") == "page" and TARGET in (t.get("url") or "")]
if not page_tabs:
    emit(False, kind="no-tab", message=f"no page tab matching {TARGET!r}")
target = page_tabs[0]
ws_url = target.get("webSocketDebuggerUrl")
if not ws_url:
    emit(False, kind="dom-error", message="matched tab has no webSocketDebuggerUrl")

# Connect.
try:
    ws = websocket.create_connection(ws_url, suppress_origin=True, timeout=5)
except Exception as e:
    emit(False, kind="ws-error", message=f"ws connect: {e}")

_mid = [0]
def cdp(method, params=None, timeout=10):
    _mid[0] += 1; mid = _mid[0]
    ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            ws.settimeout(max(0.05, deadline - time.time()))
            r = json.loads(ws.recv())
        except Exception as e:
            return {"error": {"message": f"recv: {e}"}}
        if r.get("id") == mid:
            return r
    return {"error": {"message": "timeout"}}

if BTF:
    cdp("Page.bringToFront")

r = cdp("Runtime.evaluate", {"expression": EXPR, "returnByValue": True, "awaitPromise": AWAIT})
try:
    ws.close()
except Exception:
    pass

if "error" in r:
    emit(False, kind="dom-error", message=f"CDP error: {r['error'].get('message', r['error'])}")
outer = r.get("result", {})
if "exceptionDetails" in outer:
    ex = outer["exceptionDetails"]
    emit(False, kind="dom-error", message=f"JS exception: {ex.get('text', 'unknown')}")
res = outer.get("result", {})
if res.get("subtype") == "error":
    emit(False, kind="dom-error", message=f"JS Error value: {res.get('description', 'unknown')}")
emit(True, value=res.get("value"))
PY
