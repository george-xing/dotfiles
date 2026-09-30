import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).parents[1] / "bin" / "twitter-browser.sh"


class BrowserIsolationTests(unittest.TestCase):
    def test_explicit_twitter_route_survives_an_inherited_default_session(self):
        with tempfile.TemporaryDirectory() as directory:
            client = Path(directory) / "client"
            client.write_text('#!/usr/bin/python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
            client.chmod(0o700)
            env = dict(os.environ, TWITTER_BROWSER_USE_BIN=str(client),
                       BROWSER_USE_SESSION="default", TWITTER_BROWSER_SESSION="twitter-test",
                       TWITTER_CDP_URL="http://127.0.0.1:9222")
            for command in (["open", "https://x.com/home"], ["eval", "'hello world'"], ["keys", "Escape"]):
                result = subprocess.run([str(HELPER), *command], env=env, capture_output=True, text=True, check=True)
                args = json.loads(result.stdout)
                self.assertEqual(args, ["--session", "twitter-test", "--cdp-url", env["TWITTER_CDP_URL"], *command])
            for invalid in (["--session", "default", "eval", "1"], ["close", "--all"]):
                result = subprocess.run([str(HELPER), *invalid], env=env, capture_output=True)
                self.assertEqual(result.returncode, 64)
            env["TWITTER_BROWSER_SESSION"] = "default"
            self.assertEqual(subprocess.run([str(HELPER), "eval", "1"], env=env, capture_output=True).returncode, 64)
