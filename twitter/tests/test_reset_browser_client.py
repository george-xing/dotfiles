import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("reset_client", Path(__file__).parents[1] / "bin/lib/reset-browser-client.py")
reset = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reset)


class ClientIdentityTests(unittest.TestCase):
    def test_only_named_twitter_daemon_at_dedicated_endpoint_is_allowed(self):
        good = "python -m browser_use.skill_cli.daemon --session twitter-production --cdp-url http://127.0.0.1:9222"
        self.assertTrue(reset.is_twitter_client(good))
        for bad in [good.replace("twitter-production", "default"), good.replace("9222", "19223"),
                    good.replace("skill_cli.daemon", "skill_cli.main"), good + " --session other",
                    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "python --session"]:
            with self.subTest(command=bad):
                self.assertFalse(reset.is_twitter_client(bad))
