import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


HELPER = Path(__file__).parents[1] / "bin" / "lib" / "verify-delivery-state.py"


class VerifyDeliveryStateTests(unittest.TestCase):
    def run_helper(self, *args):
        return subprocess.run(
            [sys.executable, str(HELPER), *map(str, args)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

    def test_fresh_accepts_zulu_timestamp_on_python_39(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            state.write_text('{"at":"2026-08-04T02:33:02.560186Z"}\n')
            result = self.run_helper(
                "fresh", state, "at", "2026-08-04T02:31:32.887567+00:00"
            )
            self.assertEqual(result, "1")

    def test_reconciles_fresh_confirmed_search_delivery(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state_dir = root / "state"
            state_dir.mkdir()
            started = "2026-08-04T02:18:37+00:00"
            pending_at = "2026-08-04T02:22:07Z"
            (state_dir / "pending.json").write_text(
                json.dumps(
                    {
                        "runAt": pending_at,
                        "query": "Anthropic",
                        "scrolledFor": 0.61,
                        "resultCount": 13,
                        "telegramOk": None,
                    }
                )
            )
            (state_dir / "last-failure.json").write_text(
                json.dumps(
                    {
                        "kind": "telegram",
                        "at": "2026-08-04T02:22:14Z",
                        "message": "false negative",
                    }
                )
            )
            response = root / "tg_response.json"
            response.write_text(
                json.dumps(
                    {
                        "ok": True,
                        "result": {
                            "message_id": 966,
                            "date": 1785810127,
                            "chat": {"id": 7953915703},
                        },
                    }
                )
            )
            timestamp = datetime(2026, 8, 4, 2, 22, 7, tzinfo=timezone.utc).timestamp()
            response.touch()
            import os

            os.utime(response, (timestamp, timestamp))

            result = self.run_helper(
                "reconcile-search", state_dir, response, started, "7953915703"
            )
            self.assertEqual(result, "1")
            success = json.loads((state_dir / "last-success.json").read_text())
            self.assertTrue(success["telegramOk"])
            self.assertEqual(success["query"], "Anthropic")
            self.assertFalse((state_dir / "pending.json").exists())
            self.assertFalse((state_dir / "last-failure.json").exists())

    def test_does_not_reconcile_stale_pending_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state_dir = root / "state"
            state_dir.mkdir()
            (state_dir / "pending.json").write_text(
                json.dumps(
                    {
                        "runAt": "2026-08-04T02:22:07Z",
                        "query": "Anthropic",
                        "telegramOk": None,
                    }
                )
            )
            response = root / "tg_response.json"
            response.write_text(
                json.dumps(
                    {
                        "ok": True,
                        "result": {
                            "message_id": 966,
                            "date": 1785810127,
                            "chat": {"id": 7953915703},
                        },
                    }
                )
            )
            result = self.run_helper(
                "reconcile-search",
                state_dir,
                response,
                "2026-08-04T02:31:32+00:00",
                "7953915703",
            )
            self.assertEqual(result, "0")
            self.assertFalse((state_dir / "last-success.json").exists())

    def test_clears_failure_superseded_by_confirmed_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            (state_dir / "last-failure.json").write_text(
                json.dumps(
                    {
                        "kind": "visibility",
                        "at": "2026-08-04T02:42:36Z",
                        "message": "provisional failure",
                    }
                )
            )
            (state_dir / "last-success.json").write_text(
                json.dumps(
                    {
                        "runAt": "2026-08-04T02:43:30Z",
                        "query": "stripe",
                        "telegramOk": True,
                    }
                )
            )
            result = self.run_helper(
                "clear-superseded-failure",
                state_dir,
                "2026-08-04T02:40:00+00:00",
            )
            self.assertEqual(result, "1")
            self.assertFalse((state_dir / "last-failure.json").exists())

    def test_keeps_failure_newer_than_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            (state_dir / "last-failure.json").write_text(
                json.dumps(
                    {
                        "kind": "telegram",
                        "at": "2026-08-04T02:44:00Z",
                        "message": "real later failure",
                    }
                )
            )
            (state_dir / "last-success.json").write_text(
                json.dumps(
                    {
                        "runAt": "2026-08-04T02:43:30Z",
                        "query": "stripe",
                        "telegramOk": True,
                    }
                )
            )
            result = self.run_helper(
                "clear-superseded-failure",
                state_dir,
                "2026-08-04T02:40:00+00:00",
            )
            self.assertEqual(result, "0")
            self.assertTrue((state_dir / "last-failure.json").exists())

    def test_clears_historical_failure_after_new_confirmed_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            (state_dir / "last-failure.json").write_text(
                json.dumps(
                    {
                        "kind": "timeout",
                        "at": "2026-08-07T02:11:00Z",
                        "message": "previous scheduled fire timed out",
                    }
                )
            )
            (state_dir / "last-success.json").write_text(
                json.dumps(
                    {
                        "runAt": "2026-08-07T03:08:22Z",
                        "telegramOk": True,
                    }
                )
            )
            result = self.run_helper(
                "clear-superseded-failure",
                state_dir,
                "2026-08-07T03:04:01+00:00",
            )
            self.assertEqual(result, "1")
            self.assertFalse((state_dir / "last-failure.json").exists())


if __name__ == "__main__":
    unittest.main()
