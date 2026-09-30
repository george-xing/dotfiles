#!/usr/bin/env python3
"""Deterministic X home-feed collector for the scheduled Twitter digest.

The model owns editorial triage and composition. This helper owns the bounded,
repetitive browser loop so a routine feed plateau never requires another model
or multimodal round trip. It writes candidates and collection metadata under
``/tmp/twitter-digest-run`` and writes the normal categorized failure record on
hard browser/auth/DOM failures.
"""

from __future__ import annotations

import json
import argparse
import os
import signal
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


CDP_URL = os.environ.get("TWITTER_CDP_URL", "http://127.0.0.1:9222")
BROWSER_USE = os.environ.get(
    "TWITTER_BROWSER_USE", "/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh"
)
EXTRACT_TWEETS = os.environ.get(
    "TWITTER_EXTRACT_TWEETS",
    "/Users/pattybot/dotfiles/twitter/bin/lib/extract-tweets.sh",
)
STATE_DIR = Path(
    os.environ.get(
        "TWITTER_DIGEST_STATE",
        "/Users/pattybot/.claude/skills/twitter-digest/state",
    )
)
RUN_DIR = Path(os.environ.get("TWITTER_DIGEST_RUN_DIR", "/tmp/twitter-digest-run"))
WALL_SECONDS = int(os.environ.get("TWITTER_DIGEST_WALL_SECONDS", "300"))
HEALTHY_TARGET = int(os.environ.get("TWITTER_DIGEST_HEALTHY_TARGET", "150"))
MATURE_PLATEAU_SECONDS = int(
    os.environ.get("TWITTER_DIGEST_MATURE_PLATEAU_SECONDS", "120")
)

ESCAPE_CAP = 3
TOP_CAP = 3
HOME_RECOVERY_CAP = 2

PROBE_JS = r'''JSON.stringify({
  origin: location.origin,
  path: location.pathname,
  title: document.title,
  vis: document.visibilityState,
  iw: innerWidth,
  ih: innerHeight,
  hasPrimaryColumn: !!document.querySelector('[data-testid="primaryColumn"]'),
  hasAuthenticatedNav: !!document.querySelector('[data-testid="AppTabBar_Profile_Link"]'),
  hasLoginWall: Array.from(document.querySelectorAll('a[href="/login"], a[href="/i/flow/login"]'))
    .some(node => node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden')
})'''

DIALOG_JS = r'''JSON.stringify((() => {
  const dialog = Array.from(document.querySelectorAll('[role="dialog"]')).find((x) => {
    // X can render the modal in fixed-position children of a zero-height root.
    return [x, ...x.querySelectorAll('*')].some((node) => {
      const r = node.getBoundingClientRect();
      const s = getComputedStyle(node);
      return r.width > 0 && r.height > 0 && s.visibility !== 'hidden'
        && s.display !== 'none' && node.getClientRects().length > 0;
    });
  });
  return dialog ? (dialog.innerText || '[visible dialog]').slice(0, 300) : null;
})())'''

ENSURE_FOR_YOU_JS = r'''JSON.stringify((() => {
  const tabs = document.querySelectorAll('[role="tablist"] [role="tab"]');
  const tab = Array.from(tabs).find(t => /^for you$/i.test(t.innerText.trim()));
  const clicked = !!tab && tab.getAttribute('aria-selected') !== 'true';
  // Clicking an already-selected For You tab opens Snooze Topics on current X.
  if (clicked) tab.click();
  return {found: !!tab, clicked};
})())'''


def run(args: list[str], timeout: int = 30, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    process = subprocess.Popen(args, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=env, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        # Killing only a shell leaves its browser client holding the session.
        # Terminate this command's group; the existing Chrome daemon is separate.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


def browser(*args: str, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return run([BROWSER_USE, *args], timeout=timeout)


def browser_eval(js: str) -> Any:
    result = browser("eval", js)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip()[:500])
    output = result.stdout.strip()
    if output.startswith("result:"):
        output = output[len("result:") :].strip()
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return output


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False)
    os.replace(temporary, path)


def fail(kind: str, message: str, screenshot: str | None = None) -> None:
    failure: dict[str, Any] = {
        "kind": kind,
        "at": datetime.now(timezone.utc).isoformat(),
        "message": message,
    }
    if screenshot:
        failure["screenshot"] = screenshot
    atomic_write_json(STATE_DIR / "last-failure.json", failure)
    print("HARD_FAIL " + json.dumps(failure), flush=True)
    raise SystemExit(20)


def page_probe() -> dict[str, Any]:
    probe = retry_read(lambda: browser_eval(PROBE_JS))
    if isinstance(probe, str):
        try:
            probe = json.loads(probe)
        except json.JSONDecodeError:
            fail("dom", f"page probe returned invalid JSON: {probe[:300]}")
    if not isinstance(probe, dict):
        fail("dom", f"page probe returned {type(probe).__name__}, expected object")
    return probe


def retry_read(operation, attempts=3):
    """Retry read-only transport failures; never wrap clicks or navigation."""
    for attempt in range(attempts):
        try:
            return operation()
        except (subprocess.TimeoutExpired, RuntimeError, OSError):
            if attempt + 1 == attempts:
                raise
            time.sleep(2)


def bring_x_target_to_front() -> bool:
    try:
        import websocket  # type: ignore[import-not-found]

        targets = json.loads(
            urllib.request.urlopen(f"{CDP_URL}/json", timeout=3).read()
        )
        target = next(
            item
            for item in targets
            if item.get("type") == "page"
            and item.get("url", "").split("?", 1)[0] == "https://x.com/home"
        )
        socket = websocket.create_connection(
            target["webSocketDebuggerUrl"], suppress_origin=True, timeout=3
        )
        socket.send(json.dumps({"id": 1, "method": "Page.bringToFront"}))
        while True:
            reply = json.loads(socket.recv())
            if reply.get("id") == 1:
                break
        socket.close()
        return True
    except Exception as error:
        # Focus is best-effort on a locked desktop. Authenticated content on
        # the browser client's actual tab remains the authority below.
        print(f"visibility: focus unavailable ({type(error).__name__}); checking background content", flush=True)
        return False


def ready_page_probe(attempts: int = 11) -> dict[str, Any]:
    """Navigation completes before X hydrates. Missing navigation is not logout."""
    for attempt in range(attempts):
        probe = page_probe()
        if probe.get("hasLoginWall"):
            return probe
        if probe.get("origin") != "https://x.com" or probe.get("path") != "/home":
            return probe
        if probe.get("hasAuthenticatedNav") and probe.get("hasPrimaryColumn"):
            return probe
        if attempt + 1 < attempts:
            time.sleep(2)
    return probe


def verify_page() -> bool:
    """Allow a locked desktop only with independent route, auth, and content proof."""
    probe = ready_page_probe()
    if probe.get("vis") != "visible":
        bring_x_target_to_front()
        time.sleep(1)
        probe = ready_page_probe()
    if probe.get("hasLoginWall"):
        fail("auth", "bot Chrome shows an X login wall")
    if probe.get("origin") != "https://x.com" or probe.get("path") != "/home":
        fail("dom", "browser is not on the expected X Home route")
    if not probe.get("hasAuthenticatedNav"):
        fail("dom", "X Home did not hydrate authenticated navigation within the readiness window")
    if not probe.get("iw") or not probe.get("ih"):
        fail("visibility", "X Home has a zero-sized viewport")
    if not probe.get("hasPrimaryColumn"):
        fail("dom", "X Home primary column is missing")
    degraded = probe.get("vis") != "visible"
    if degraded:
        # Auth/navigation can hydrate before the virtualized timeline renders.
        # Request a real frame before judging a hidden page's content, using
        # the same existing mechanism as the collection loop.
        content_ready = False
        for attempt in range(4):
            render_background_frame()
            tiles = extract_tiles()
            if any(t.get("statusUrl") and t.get("timeISO") and not t.get("isPromoted")
                   and (t.get("text") or t.get("articleLink")) for t in tiles):
                content_ready = True
                break
            if attempt < 3:
                time.sleep(2)
        if not content_ready:
            fail("visibility", "hidden X Home did not yield authenticated feed content")
        print("visibility: background collection verified by route, auth, viewport and feed extraction", flush=True)
    return degraded


def load_digested_urls() -> set[str]:
    path = STATE_DIR / "digested-urls.json"
    try:
        return {
            item["url"]
            for item in json.loads(path.read_text(encoding="utf-8"))
            if isinstance(item, dict) and item.get("url")
        }
    except (FileNotFoundError, json.JSONDecodeError, TypeError):
        return set()


def extract_tiles() -> list[dict[str, Any]]:
    env = os.environ.copy()
    env["MAX"] = "80"
    def read():
        result = run([EXTRACT_TWEETS], timeout=30, env=env)
        if result.returncode:
            raise RuntimeError((result.stderr or result.stdout).strip()[:500])
        return result
    result = retry_read(read)
    data = json.loads(result.stdout)
    if not isinstance(data, list):
        raise RuntimeError("extract-tweets.sh returned non-array JSON")
    return data


def capture_stall_screenshot() -> tuple[str | None, str | None]:
    stalls_dir = STATE_DIR / "stalls"
    stalls_dir.mkdir(parents=True, exist_ok=True)
    screenshot = stalls_dir / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ.png")
    result = browser("screenshot", str(screenshot), timeout=30)
    screenshots = sorted(
        stalls_dir.glob("*.png"), key=lambda item: item.stat().st_mtime, reverse=True
    )
    for old_screenshot in screenshots[10:]:
        old_screenshot.unlink(missing_ok=True)
    if result.returncode:
        return None, (result.stderr or result.stdout).strip()[:300]
    return str(screenshot), None


def dialog_signature() -> str | None:
    value = retry_read(lambda: browser_eval(DIALOG_JS))
    return value.strip() if isinstance(value, str) and value.strip() else None


def dismiss_dialog() -> None:
    """Verify native Escape actually removed the obstruction before scrolling."""
    result = browser("keys", "Escape")
    if result.returncode:
        fail("dom", f"native Escape failed: {(result.stderr or result.stdout)[:300]}")
    time.sleep(1)
    if dialog_signature():
        screenshot, _ = capture_stall_screenshot()
        fail("stall", "X dialog remained open after native Escape", screenshot)


def render_background_frame() -> None:
    """Request a real frame so hidden Chrome updates X's virtualized timeline.

    On a locked Mac, scrollY moves while rendering/IntersectionObserver updates
    can remain suspended. A CDP screenshot advances rendering without changing
    visibility, lifecycle, authentication, or the desktop. Overwrite one local
    artifact; no screenshot is sent to a model.
    """
    result = browser("screenshot", str(RUN_DIR / "background-frame.png"))
    if result.returncode:
        fail("visibility", f"background frame capture failed: {(result.stderr or result.stdout)[:300]}")


def choose_stall_action(
    *,
    scanned: int,
    elapsed: int,
    dialog_signature: str | None,
    handled_dialogs: set[str],
    escape_used: int,
    top_used: int,
    home_used: int,
) -> str:
    """Return the next bounded recovery action; kept pure for regression tests."""
    if dialog_signature:
        if dialog_signature not in handled_dialogs and escape_used < ESCAPE_CAP:
            return "escape"
        return "blocked_dialog"
    if scanned >= HEALTHY_TARGET and elapsed >= MATURE_PLATEAU_SECONDS:
        return "stop_clean_plateau"
    if top_used < TOP_CAP:
        return "scroll_top"
    if home_used < HOME_RECOVERY_CAP:
        return "home_refresh"
    return "stop_clean_plateau"


def write_collection(
    *,
    seen: dict[str, dict[str, Any]],
    articles: dict[str, dict[str, Any]],
    elapsed: int,
    reason: str,
    escape_used: int,
    top_used: int,
    home_used: int,
    visibility_degraded: bool = False,
    background_frames: int = 0,
    screenshot: str | None = None,
    screenshot_error: str | None = None,
) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "scanned": len(seen),
        "scanTarget": HEALTHY_TARGET,
        "scanShortfall": max(0, HEALTHY_TARGET - len(seen)),
        "wallBudgetSeconds": WALL_SECONDS,
        "articleCandidates": len(articles),
        "elapsedSeconds": elapsed,
        "reason": reason,
        "visibilityDegraded": visibility_degraded,
        "backgroundFrames": background_frames,
        "screenshot": screenshot,
        "screenshotError": screenshot_error,
        "caps": {
            "escape": escape_used,
            "top": top_used,
            "homeRecovery": home_used,
        },
    }
    atomic_write_json(RUN_DIR / "candidates.json", list(seen.values()))
    atomic_write_json(RUN_DIR / "articles.json", list(articles.values()))
    atomic_write_json(RUN_DIR / "collection.json", metadata)
    return metadata


def main() -> int:
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    for stale_name in ("candidates.json", "articles.json", "collection.json"):
        (RUN_DIR / stale_name).unlink(missing_ok=True)

    opened = browser("open", "https://x.com/home")
    if opened.returncode:
        fail("dom", f"failed to navigate to X Home: {(opened.stderr or opened.stdout)[:300]}")
    time.sleep(4)
    # A hidden renderer can postpone even the first DOM probe until a real
    # frame is requested. Warm rendering before checking readiness, not after.
    render_background_frame()
    visibility_degraded = verify_page()
    background_frames = 0

    def update_background_frame() -> None:
        nonlocal background_frames
        if visibility_degraded:
            render_background_frame()
            background_frames += 1

    update_background_frame()
    escape_used = 0
    if dialog_signature():
        dismiss_dialog()
        escape_used += 1

    browser_eval(
        "const link=document.querySelector('a[data-testid=\"AppTabBar_Home_Link\"]');"
        "if(link)link.click();({clicked:!!link})"
    )
    time.sleep(4)
    selected = browser_eval(ENSURE_FOR_YOU_JS)
    if not isinstance(selected, dict) or not selected.get("found"):
        fail("dom", "For You tab is missing")
    time.sleep(2)
    if browser_eval("JSON.stringify(Array.from(document.querySelectorAll('[role=tab]')).some(t=>/^for you$/i.test(t.innerText.trim()) && t.getAttribute('aria-selected')==='true'))") is not True:
        fail("dom", "For You tab did not become selected")
    update_background_frame()

    digested = load_digested_urls()
    seen: dict[str, dict[str, Any]] = {}
    articles: dict[str, dict[str, Any]] = {}

    def merge_tiles() -> int:
        added = 0
        for tile in extract_tiles():
            status_url = tile.get("statusUrl")
            if (
                tile.get("isPromoted")
                or not tile.get("timeISO")
                or status_url in digested
            ):
                continue
            key = str(status_url or (tile.get("author", ""), tile.get("text", "")))
            if key in seen:
                continue
            seen[key] = tile
            added += 1
            if tile.get("articleLink"):
                articles[str(tile["articleLink"])] = tile
        return added

    started = time.monotonic()
    zero_new = 0
    mode = "scroll"
    top_used = 0
    home_used = 0
    handled_dialogs: set[str] = set()

    try:
        merge_tiles()
        while time.monotonic() - started < WALL_SECONDS:
            if mode == "scroll":
                browser_eval("window.scrollBy(0,1500);'ok'")
            else:
                browser_eval(
                    "const tweets=document.querySelectorAll('article[data-testid=\"tweet\"]');"
                    "if(tweets.length)tweets[tweets.length-1].scrollIntoView({block:'end'});'ok'"
                )
            update_background_frame()
            time.sleep(1.5)
            added = merge_tiles()
            elapsed = int(time.monotonic() - started)
            print(
                f"iter mode={mode} new={added} total={len(seen)} elapsed={elapsed}",
                flush=True,
            )
            if added:
                zero_new = 0
                mode = "scroll"
                continue
            zero_new += 1
            if zero_new < 2:
                continue
            if mode == "scroll":
                mode = "into"
                zero_new = 0
                continue

            visibility_degraded = verify_page() or visibility_degraded
            dialog = dialog_signature()
            action = choose_stall_action(
                scanned=len(seen),
                elapsed=elapsed,
                dialog_signature=dialog,
                handled_dialogs=handled_dialogs,
                escape_used=escape_used,
                top_used=top_used,
                home_used=home_used,
            )
            print(f"stall action={action} dialog={bool(dialog)} elapsed={elapsed}", flush=True)
            if action == "escape":
                handled_dialogs.add(dialog or "")
                dismiss_dialog()
                escape_used += 1
                if top_used < TOP_CAP:
                    browser_eval("window.scrollTo(0,0);'ok'")
                    top_used += 1
                    time.sleep(1)
            elif action == "blocked_dialog":
                screenshot, _ = capture_stall_screenshot()
                fail("stall", "X dialog blocks collection after bounded recovery", screenshot)
            elif action == "scroll_top":
                browser_eval("window.scrollTo(0,0);'ok'")
                top_used += 1
                time.sleep(5)
            elif action == "home_refresh":
                browser_eval(
                    "const link=document.querySelector('a[data-testid=\"AppTabBar_Home_Link\"]');"
                    "if(link)link.click();({clicked:!!link})"
                )
                home_used += 1
                time.sleep(4)
            else:
                screenshot, screenshot_error = capture_stall_screenshot()
                metadata = write_collection(
                    seen=seen,
                    articles=articles,
                    elapsed=elapsed,
                    reason="clean_plateau",
                    escape_used=escape_used,
                    top_used=top_used,
                    home_used=home_used,
                    visibility_degraded=visibility_degraded,
                    background_frames=background_frames,
                    screenshot=screenshot,
                    screenshot_error=screenshot_error,
                )
                print("COLLECTION_COMPLETE " + json.dumps(metadata), flush=True)
                return 0
            zero_new = 0
            mode = "scroll"
    except (RuntimeError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        fail("dom", f"collection/extraction failed: {error}")

    elapsed = int(time.monotonic() - started)
    metadata = write_collection(
        seen=seen,
        articles=articles,
        elapsed=elapsed,
        reason="wall_budget",
        escape_used=escape_used,
        top_used=top_used,
        home_used=home_used,
        visibility_degraded=visibility_degraded,
        background_frames=background_frames,
    )
    print("COLLECTION_COMPLETE " + json.dumps(metadata), flush=True)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-browser", action="store_true", help="Check existing Home state without collecting or delivering")
    args = parser.parse_args()
    try:
        if args.check_browser:
            RUN_DIR.mkdir(parents=True, exist_ok=True)
            print(json.dumps({"browserReady": True, "visibilityDegraded": verify_page()}))
        else:
            raise SystemExit(main())
    except subprocess.TimeoutExpired:
        fail("timeout", "browser command exceeded its deadline after bounded read recovery")
    except Exception as error:
        fail("dom", f"collector failed: {type(error).__name__}: {str(error)[:300]}")
