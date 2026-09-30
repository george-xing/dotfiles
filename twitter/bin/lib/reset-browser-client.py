#!/usr/bin/env python3
"""Disconnect a wedged twitter-production client without closing Chrome."""
from pathlib import Path
import os
import shlex
import signal
import subprocess
import time


def is_twitter_client(command):
    parts = shlex.split(command)
    required = {"-m": "browser_use.skill_cli.daemon", "--session": "twitter-production",
                "--cdp-url": "http://127.0.0.1:9222"}
    return all(parts.count(flag) == 1 and parts.index(flag) + 1 < len(parts)
               and parts[parts.index(flag) + 1] == value for flag, value in required.items())


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def main():
    lock = Path.home() / ".claude/skills/.twitter-fire.lock"
    if lock.exists():
        pid = int(lock.read_text().strip().split()[0])
        if pid <= 1 or alive(pid):
            raise RuntimeError("Twitter workflow is active; do not reset its client")
    path = Path.home() / ".browser-use/twitter-production.pid"
    if not path.exists():
        print("No Twitter client to reset")
        return
    pid = int(path.read_text().strip())
    if pid <= 1:
        raise RuntimeError("Invalid client PID")
    if not alive(pid):
        print("Twitter client has already exited")
        return
    result = subprocess.run(["ps", "-p", str(pid), "-o", "args="], capture_output=True, text=True, check=True)
    if not is_twitter_client(result.stdout):
        raise RuntimeError("PID does not match the isolated Twitter CDP client")
    # This CLI's external-CDP shutdown calls BrowserSession.stop(), which
    # disconnects; only a locally launched browser would be killed by shutdown.
    os.kill(pid, signal.SIGTERM)
    for _ in range(15):
        if not alive(pid):
            print("Twitter client disconnected; Chrome and its login profile remain running")
            return
        time.sleep(1)
    raise RuntimeError("Client did not exit; investigate without killing Chrome")


if __name__ == "__main__":
    main()
