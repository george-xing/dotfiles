#!/bin/bash
# activate-chase.sh — Chase Offers DOM driver (CDP-direct via websocket).
#
# Reads (env):
#   DAEMON_PORT  — Chrome CDP debug port, default 19223
#   DEDUP_FILE   — path to chase-activated.json (array of {url:offer_id,...})
#   MODE         — "probe" (enumerate only, no clicks) or "activate"
#                  (enumerate + click — DISABLED until selectors are verified)
#   MAX_CLICKS   — safety cap on activations per run, default 50
#
# Writes single-line JSON to stdout — see below for shape.
#
# Why CDP-direct (not browser-use):
#   browser-use eval has no tab-targeting flag — it operates on the first
#   page target. With multiple tabs (Chase + Amex + newtab), we'd have to
#   switch tabs imperatively, which changes user-visible state. Direct CDP
#   lets us find the Chase tab by URL substring and evaluate without any
#   side effects.

set -uo pipefail

PYTHON_BIN="/usr/bin/python3"
DAEMON_PORT="${DAEMON_PORT:-19223}"
MODE="${MODE:-probe}"
MAX_CLICKS="${MAX_CLICKS:-50}"
SCREENSHOT_DIR="$HOME/.claude/skills/credit-card-offers/state/screenshots"

: "${DEDUP_FILE:?DEDUP_FILE is required}"

mkdir -p "$SCREENSHOT_DIR"

# Delegate everything to python+websocket. Output is JSON on stdout.
DAEMON_PORT="$DAEMON_PORT" \
DEDUP_FILE="$DEDUP_FILE" \
MODE="$MODE" \
MAX_CLICKS="$MAX_CLICKS" \
SCREENSHOT_DIR="$SCREENSHOT_DIR" \
  "$PYTHON_BIN" - <<'PY'
import json, os, sys, time, urllib.request
from datetime import datetime, timezone

try:
    import websocket
except ImportError:
    print(json.dumps({"ok": False, "kind": "config", "message": "websocket-client missing in /usr/bin/python3 — install via: /usr/bin/python3 -m pip install --user websocket-client", "screenshot": None}))
    sys.exit(0)

PORT = os.environ["DAEMON_PORT"]
MODE = os.environ["MODE"]
DEDUP_FILE = os.environ["DEDUP_FILE"]
SCREENSHOT_DIR = os.environ["SCREENSHOT_DIR"]
MAX_CLICKS = int(os.environ.get("MAX_CLICKS", "50"))

TARGET_URL_SUBSTRING = "chase.com"
SCREENSHOT_PREFIX = "chase"
OFFERS_HUB_URL = "https://secure.chase.com/web/auth/dashboard#/dashboard/offers/offerHub"


def emit_failure(kind, message, screenshot=None):
    print(json.dumps({"ok": False, "kind": kind, "message": message, "screenshot": screenshot}))
    sys.exit(0)


def screenshot_path(label="fail"):
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return os.path.join(SCREENSHOT_DIR, f"{SCREENSHOT_PREFIX}-{label}-{ts}.png")


# 1. Find the target tab by URL substring.
try:
    tabs = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=3).read())
except Exception as e:
    emit_failure("dom", f"could not list CDP tabs at port {PORT}: {e}")

page_tabs = [t for t in tabs if t.get("type") == "page" and TARGET_URL_SUBSTRING in (t.get("url") or "")]
if not page_tabs:
    all_pages = [t.get("url", "")[:80] for t in tabs if t.get("type") == "page"]
    emit_failure("dom", f"no tab matching '{TARGET_URL_SUBSTRING}' (page tabs: {all_pages})")

target = page_tabs[0]
ws_url = target["webSocketDebuggerUrl"]

# 2. Connect to that tab's CDP socket.
try:
    ws = websocket.create_connection(ws_url, suppress_origin=True, timeout=5)
except Exception as e:
    emit_failure("dom", f"could not open CDP websocket: {e}")

_msg_id = [0]
def cdp(method, params=None):
    _msg_id[0] += 1
    mid = _msg_id[0]
    ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
    deadline = time.time() + 10
    while time.time() < deadline:
        try:
            ws.settimeout(deadline - time.time())
            r = json.loads(ws.recv())
        except Exception as e:
            return {"error": {"message": f"recv failed: {e}"}}
        if r.get("id") == mid:
            return r
    return {"error": {"message": "timeout"}}


def evaluate(js):
    r = cdp("Runtime.evaluate", {"expression": js, "returnByValue": True, "awaitPromise": True})
    if "error" in r:
        return None, r["error"]
    res = r.get("result", {}).get("result", {})
    if res.get("subtype") == "error":
        return None, {"message": res.get("description", "js error")}
    return res.get("value"), None


def take_screenshot(label):
    path = screenshot_path(label)
    try:
        r = cdp("Page.captureScreenshot", {"format": "png"})
        b64 = r.get("result", {}).get("data")
        if not b64:
            return None
        import base64
        with open(path, "wb") as f:
            f.write(base64.b64decode(b64))
        return path
    except Exception:
        return None


# 3. Bring this tab to front within the bot Chrome window. The prefire already
#    activated the Chrome window OS-level; this activates THIS tab specifically.
#    Page.bringToFront calls WebContentsImpl::Activate() — it's a real activation
#    path, not fakery. Same precedent as twitter-digest step 2's bringToFront use.
cdp("Page.bringToFront")
time.sleep(0.5)

# 4. Ensure the tab is on the offers hub. Navigate only if it isn't already
#    on the offers URL — avoids unnecessary reloads that can trigger re-auth.
current_url, _ = evaluate("location.href")
if current_url and "offers/offerHub" not in current_url:
    cdp("Page.enable")
    cdp("Page.navigate", {"url": OFFERS_HUB_URL})
    # Wait for the page to settle. Chase SPA can take a beat — bounded poll.
    for _ in range(8):
        time.sleep(1)
        u, _ = evaluate("location.href")
        if u and "offers/offerHub" in (u or ""):
            break
    time.sleep(2)  # extra hydration time for the offers grid

# 5. Probe the page state.
PROBE_JS = """
(() => {
  const result = {
    url: location.href,
    title: document.title,
    vis: document.visibilityState,
    iw: innerWidth,
    ih: innerHeight,
    hasLoginWall: (
      !!document.querySelector('input[type="password"]') ||
      /sign in|log in|login/i.test(document.title) ||
      // Chase iframes its auth UI; the outer page shows "loading" while the
      // iframe boots. If body is short + title says sign-in, that's our cue.
      (/sign in|log in/i.test(document.title) && (document.body?.innerText || '').length < 200)
    ),
    onOffersHub: location.hash.includes('offers/offerHub') || location.pathname.includes('/offers'),
    candidates: {}
  };
  const selectors = [
    '[data-testid*="offer-tile"]',
    '[data-testid*="merchant-offer"]',
    '[data-testid*="offer"]',
    '[class*="OfferTile"]',
    '[class*="offer-tile"]',
    '[role="button"][aria-label*="offer" i]',
    'article[class*="offer" i]'
  ];
  for (const sel of selectors) {
    result.candidates[sel] = document.querySelectorAll(sel).length;
  }
  const winner = Object.entries(result.candidates).sort((a,b) => b[1] - a[1])[0];
  result.winner_selector = winner && winner[1] > 0 ? winner[0] : null;
  result.winner_count = winner ? winner[1] : 0;
  if (result.winner_selector && result.winner_count > 0) {
    const tiles = document.querySelectorAll(result.winner_selector);
    result.samples = Array.from(tiles).slice(0, 3).map(t => {
      // Capture every data-* / id / aria-label attr on the tile — one of these
      // is almost certainly the offer_id key (data-offerid, data-merchant-id,
      // etc). Saves a second probe pass to discover.
      const tileAttrs = {};
      for (const attr of t.attributes || []) {
        if (attr.name.startsWith('data-') || attr.name === 'id' || attr.name === 'aria-label') {
          tileAttrs[attr.name] = attr.value;
        }
      }
      return {
        text: (t.innerText || '').slice(0, 300),
        dataAttrs: tileAttrs,
        outerHTMLPrefix: (t.outerHTML || '').slice(0, 600),
        buttons: Array.from(t.querySelectorAll('button, [role="button"], a')).map(b => {
          const bAttrs = {};
          for (const attr of b.attributes || []) {
            if (attr.name.startsWith('data-') || attr.name === 'id' || attr.name === 'aria-label' || attr.name === 'href') {
              bAttrs[attr.name] = attr.value;
            }
          }
          return {
            tag: b.tagName,
            text: (b.innerText || '').trim().slice(0, 60),
            ariaLabel: b.getAttribute('aria-label') || null,
            dataTestid: b.getAttribute('data-testid') || null,
            attrs: bAttrs
          };
        })
      };
    });
  }
  return result;
})()
"""

probe, err = evaluate(PROBE_JS)
if err:
    emit_failure("dom", f"probe eval failed: {err.get('message')}")

if probe.get("hasLoginWall"):
    sp = take_screenshot("auth")
    emit_failure("auth", "Chase login wall present — sign in via the cards bot Chrome window", sp)

if probe.get("vis") != "visible":
    sp = take_screenshot("vis")
    emit_failure("visibility", f"Chase tab vis={probe.get('vis')!r}", sp)

if not probe.get("onOffersHub") and "chase.com" not in (probe.get("url") or ""):
    sp = take_screenshot("nav")
    emit_failure("dom", f"not on Chase Offers hub (url={probe.get('url')!r})", sp)

if probe.get("winner_count", 0) == 0:
    sp = take_screenshot("no-tiles")
    emit_failure("dom", f"no offer tiles found (candidates={probe.get('candidates')})", sp)

# Probe succeeded.
out = {
    "ok": True,
    "issuer": "chase",
    "mode": MODE,
    "url": probe.get("url"),
    "tiles_seen": probe.get("winner_count", 0),
    "winner_selector": probe.get("winner_selector"),
    "samples": probe.get("samples", []),
    "candidates": probe.get("candidates", {}),
    "activated": [],
    "would_activate": [],
    "skipped_dedup": [],
    "skipped_already_added": [],
    "failures": []
}

if MODE == "probe":
    print(json.dumps(out))
    sys.exit(0)

# MODE == "activate" — DISABLED until selectors are verified against live DOM.
# Clicking blindly on unverified bank DOM is the worst possible failure mode:
# could activate the wrong tile, OR click a "Continue"/"Agree" button on a
# modal — committing the operator to TOS/consent terms unread. Hard-stop and
# require an explicit selector-confirmation pass first.
emit_failure(
    "dom",
    "activate mode not yet enabled — run with MODE=probe first to capture live selectors, "
    "then update activate-chase.sh's click section (and remove this guard) against the captured samples"
)
PY
