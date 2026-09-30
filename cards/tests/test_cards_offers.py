#!/usr/bin/python3
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "bin/cards-offers.py"
SPEC = importlib.util.spec_from_file_location("cards_offers", MODULE_PATH)
cards_offers = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = cards_offers
SPEC.loader.exec_module(cards_offers)


class PartialAuthenticationTests(unittest.TestCase):
    def run_dry(self, available, failures):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(cards_offers, "STATE", Path(tmp)), \
                mock.patch.dict(os.environ, {
                    "CARDS_AVAILABLE_ISSUERS": available,
                    "CARDS_AUTH_FAILURES_JSON": json.dumps(failures),
                }, clear=False), \
                mock.patch.object(sys, "argv", ["cards-offers.py", "--dry-run"]), \
                contextlib.redirect_stdout(output):
            status = cards_offers.main()
        return status, json.loads(output.getvalue())

    def test_unavailable_issuer_is_not_probed(self):
        chase_result = {
            "issuer": "Chase",
            "ok": True,
            "available": 0,
            "activated": [],
            "failures": [],
        }
        with mock.patch.object(cards_offers, "chase", return_value=chase_result), \
                mock.patch.object(cards_offers, "amex", side_effect=AssertionError("must not run")):
            status, summary = self.run_dry(
                "Chase",
                [{"issuer": "Amex", "kind": "auth", "message": "login unavailable"}],
            )
        self.assertEqual(status, 0)
        self.assertEqual(summary["results"][0]["issuer"], "Chase")
        self.assertEqual(summary["errors"][0]["issuer"], "Amex")
        self.assertEqual(summary["errors"][0]["kind"], "auth")

    def test_both_unavailable_remains_failure(self):
        failures = [
            {"issuer": "Chase", "kind": "auth", "message": "login unavailable"},
            {"issuer": "Amex", "kind": "auth", "message": "login unavailable"},
        ]
        with mock.patch.object(cards_offers, "chase", side_effect=AssertionError("must not run")), \
                mock.patch.object(cards_offers, "amex", side_effect=AssertionError("must not run")):
            status, summary = self.run_dry("", failures)
        self.assertEqual(status, 2)
        self.assertEqual(len(summary["errors"]), 2)


if __name__ == "__main__":
    unittest.main()
