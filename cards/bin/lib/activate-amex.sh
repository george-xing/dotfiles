#!/bin/bash
# activate-amex.sh — Amex Offers DOM driver, multi-card aware (CDP-direct).
#
# Reads (env):
#   DAEMON_PORT  — Chrome CDP debug port, default 19223
#   DEDUP_FILE   — path to amex-activated.json (array of {url:card_id::offer_id,...})
#   MODE         — "probe" (enumerate only) or "activate" (DISABLED pending selector verification)
#   MAX_CLICKS   — safety cap per card per run, default 50
#
# Writes single-line JSON to stdout — see below for shape.
#
# Same CDP-direct rationale as activate-chase.sh: targeted tab-by-URL
# evaluation without browser-use's switch-active-tab side effect.

set -uo pipefail

PYTHON_BIN="/usr/bin/python3"
DAEMON_PORT="${DAEMON_PORT:-19223}"
MODE="${MODE:-probe}"
MAX_CLICKS="${MAX_CLICKS:-50}"
SCREENSHOT_DIR="$HOME/.claude/skills/credit-card-offers/state/screenshots"

: "${DEDUP_FILE:?DEDUP_FILE is required}"

mkdir -p "$SCREENSHOT_DIR"

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
    print(json.dumps({"ok": False, "kind": "config", "message": "websocket-client missing in /usr/bin/python3", "screenshot": None}))
    sys.exit(0)

PORT = os.environ["DAEMON_PORT"]
MODE = os.environ["MODE"]
DEDUP_FILE = os.environ["DEDUP_FILE"]
SCREENSHOT_DIR = os.environ["SCREENSHOT_DIR"]
MAX_CLICKS = int(os.environ.get("MAX_CLICKS", "50"))

TARGET_URL_SUBSTRING = "americanexpress.com"
SCREENSHOT_PREFIX = "amex"
OFFERS_HUB_URL = "https://global.americanexpress.com/offers/eligible"


def emit_failure(kind, message, screenshot=None):
    print(json.dumps({"ok": False, "kind": kind, "message": message, "screenshot": screenshot}))
    sys.exit(0)


def screenshot_path(label="fail"):
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return os.path.join(SCREENSHOT_DIR, f"{SCREENSHOT_PREFIX}-{label}-{ts}.png")


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


# Bring this tab to front within the bot Chrome window. The prefire activated
# the Chrome window OS-level; this activates THIS tab specifically. Real
# activation call, not fakery (same precedent as twitter-digest's bringToFront).
cdp("Page.bringToFront")
time.sleep(0.5)

# Ensure the tab is on the offers eligible page.
current_url, _ = evaluate("location.href")
if current_url and "/offers/eligible" not in current_url:
    cdp("Page.enable")
    cdp("Page.navigate", {"url": OFFERS_HUB_URL})
    for _ in range(8):
        time.sleep(1)
        u, _ = evaluate("location.href")
        if u and "/offers/eligible" in (u or ""):
            break
    time.sleep(2)


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
      /log in|sign in|login/i.test(document.title) ||
      // Amex sometimes iframes its login flow too — short body + login title
      // is the heuristic that catches it.
      (/log in|sign in/i.test(document.title) && (document.body?.innerText || '').length < 200)
    ),
    onOffersPage: location.pathname.includes('/offers'),
    cardSwitcherCandidates: {},
    tileCandidates: {}
  };
  const cardSelectors = [
    '[data-test*="account-switcher"]',
    '[data-test*="card-account"]',
    '[aria-label*="select card" i]',
    '[class*="AccountSwitcher"]',
    'button[class*="card-chip" i]',
    'select[name*="account" i]',
    '[role="tablist"] [role="tab"]'
  ];
  for (const sel of cardSelectors) {
    result.cardSwitcherCandidates[sel] = document.querySelectorAll(sel).length;
  }
  const tileSelectors = [
    '[data-test*="offer-tile"]',
    '[data-test*="OfferTile"]',
    '[data-test*="offer"]',
    '[class*="offer-tile"]',
    '[class*="OfferTile"]',
    'article[class*="offer" i]',
    '[role="region"][aria-label*="offer" i]'
  ];
  for (const sel of tileSelectors) {
    result.tileCandidates[sel] = document.querySelectorAll(sel).length;
  }
  const tileWinner = Object.entries(result.tileCandidates).sort((a,b) => b[1] - a[1])[0];
  result.tile_winner = tileWinner && tileWinner[1] > 0 ? tileWinner[0] : null;
  result.tile_count = tileWinner ? tileWinner[1] : 0;
  if (result.tile_winner) {
    const tiles = document.querySelectorAll(result.tile_winner);
    result.tile_samples = Array.from(tiles).slice(0, 3).map(t => ({
      text: (t.innerText || '').slice(0, 300),
      buttons: Array.from(t.querySelectorAll('button, [role="button"], a')).map(b => ({
        tag: b.tagName,
        text: (b.innerText || '').trim().slice(0, 60),
        ariaLabel: b.getAttribute('aria-label') || null,
        dataTest: b.getAttribute('data-test') || b.getAttribute('data-testid') || null
      }))
    }));
  }
  return result;
})()
"""

probe, err = evaluate(PROBE_JS)
if err:
    emit_failure("dom", f"probe eval failed: {err.get('message')}")

if probe.get("hasLoginWall"):
    sp = take_screenshot("auth")
    emit_failure("auth", "Amex login wall present — sign in via the cards bot Chrome window", sp)

if probe.get("vis") != "visible":
    sp = take_screenshot("vis")
    emit_failure("visibility", f"Amex tab vis={probe.get('vis')!r}", sp)

if "americanexpress.com" not in (probe.get("url") or ""):
    sp = take_screenshot("nav")
    emit_failure("dom", f"not on Amex (url={probe.get('url')!r})", sp)

if probe.get("tile_count", 0) == 0:
    sp = take_screenshot("no-tiles")
    emit_failure("dom", f"no offer tiles found (candidates={probe.get('tileCandidates')})", sp)

# Probe succeeded — wrap as multi-card success shape (single-card view for now;
# card-switcher iteration enabled after we observe the real DOM and refine).
out = {
    "ok": True,
    "issuer": "amex",
    "mode": MODE,
    "url": probe.get("url"),
    "cards": [
        {
            "card_id": "current-card-on-page",
            "card_label": "current card on page (card switcher TBD)",
            "tiles_seen": probe.get("tile_count", 0),
            "tile_winner": probe.get("tile_winner"),
            "tile_samples": probe.get("tile_samples", []),
            "tileCandidates": probe.get("tileCandidates", {}),
            "cardSwitcherCandidates": probe.get("cardSwitcherCandidates", {}),
            "activated": [],
            "would_activate": [],
            "skipped_dedup": [],
            "skipped_already_added": [],
            "failures": []
        }
    ]
}

if MODE == "probe":
    print(json.dumps(out))
    sys.exit(0)

emit_failure(
    "dom",
    "activate mode not yet enabled — run with MODE=probe first to capture live selectors + card-switcher, "
    "then update activate-amex.sh's click section (and remove this guard) against the captured samples"
)
PY
