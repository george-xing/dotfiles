#!/Users/pattybot/.local/share/twitter-browser-tools/browser-use/bin/python
"""Best-effort native focus; never click the desktop or interact with its lock screen.

AppKit avoids caller-dependent System Events Automation permission. CDP selects
an exact page in the dedicated browser. Visibility is independently checked by
the workflow, including authenticated background collection on a locked Mac.
"""
import json
import os
import subprocess
import sys
import urllib.request
from urllib.parse import urlsplit

from AppKit import NSRunningApplication, NSWorkspace, NSApplicationActivateAllWindows
from websockets.sync.client import connect

CDP_URL = os.environ.get("TWITTER_CDP_URL", "http://127.0.0.1:9222")


def frontmost():
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return (int(app.processIdentifier()), str(app.bundleIdentifier())) if app else (None, None)


def prepare():
    saved_pid, bundle = frontmost()
    desktop_available = bundle not in (None, "com.apple.loginwindow")
    port = str(urlsplit(CDP_URL).port or 9222)
    result = subprocess.run(["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
                            capture_output=True, text=True, timeout=5)
    pids = sorted(set(result.stdout.split()))
    if len(pids) != 1:
        raise RuntimeError("could not uniquely identify the dedicated Chrome listener")
    pid = int(pids[0])
    print(f"  pre-fire: activating bot Chrome PID={pid}, will restore frontmost PID={saved_pid if desktop_available else '<unavailable>'}")
    if desktop_available:
        app = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
        if app:
            app.activateWithOptions_(NSApplicationActivateAllWindows)
    else:
        print("  pre-fire: desktop locked/unavailable; using authenticated background collection")

    targets = json.load(urllib.request.urlopen(f"{CDP_URL}/json", timeout=4))
    target = next((t for t in targets if t.get("type") == "page"
                   and urlsplit(t.get("url", "")).hostname in ("x.com", "www.x.com")), None)
    if target:
        with connect(target["webSocketDebuggerUrl"], open_timeout=4, close_timeout=2) as ws:
            def call(i, method, params=None):
                ws.send(json.dumps({"id": i, "method": method, "params": params or {}}))
                while True:
                    reply = json.loads(ws.recv(timeout=4))
                    if reply.get("id") == i:
                        if "error" in reply:
                            raise RuntimeError(reply["error"].get("message", "CDP error"))
                        return reply.get("result", {})
            if desktop_available:
                window = call(1, "Browser.getWindowForTarget", {"targetId": target["id"]})
                call(2, "Browser.setWindowBounds", {"windowId": window["windowId"], "bounds": {"windowState": "normal"}})
                call(3, "Page.bringToFront")
            value = call(4, "Runtime.evaluate", {"expression": "document.visibilityState"})
            print("  pre-fire: native/CDP preparation; page visibility=" + str(value.get("result", {}).get("value", "unknown")))
    else:
        print("  pre-fire: no X tab yet; browser workflow will navigate and verify")
    print(f"SAVED_FRONTMOST_PID={saved_pid if desktop_available else ''}")


def main():
    if sys.argv[1:] and sys.argv[1] == "restore":
        saved, bot = map(int, sys.argv[2:4])
        current, bundle = frontmost()
        if current == bot and saved != bot and bundle != "com.apple.loginwindow":
            app = NSRunningApplication.runningApplicationWithProcessIdentifier_(saved)
            if app:
                app.activateWithOptions_(NSApplicationActivateAllWindows)
                print(f"  post-fire: requested native restore to PID={saved}")
        else:
            print("  post-fire: foreground changed or desktop unavailable; leaving it alone")
    else:
        prepare()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Focus is optional, page/auth/content verification is not.
        print(f"  window: native focus unavailable ({type(error).__name__}: {error}); workflow must verify page")
        if len(sys.argv) < 2 or sys.argv[1] != "restore":
            print("SAVED_FRONTMOST_PID=")
