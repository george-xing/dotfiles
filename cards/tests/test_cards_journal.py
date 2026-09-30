import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("cards_journal", Path(__file__).parents[1] / "bin/cards_journal.py")
journal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(journal)


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "hermes-runs/run.json"
        self.j = journal.Journal(self.path)
        self.j.prepare()
        self.j.issuer("chase", tab_id="test")

    def test_login_reservation_survives_restart(self):
        self.j.reserve_login("chase")
        with self.assertRaises(ValueError):
            journal.Journal(self.path).reserve_login("chase")

    def test_uncertain_click_cannot_be_repeated(self):
        self.j.reserve_offer("chase", "chase::example")
        with self.assertRaises(ValueError):
            journal.Journal(self.path).reserve_offer("chase", "chase::example")
        self.assertEqual(self.j.finish(), "partial")

    def test_record_is_idempotent_and_omits_unknown_fields(self):
        for _ in range(2):
            self.j.record("chase", "chase::example", merchant="Example", password="not-a-real-secret")
        data = json.loads(self.path.read_text())
        self.assertEqual(len(data["activations"]), 1)
        self.assertNotIn("password", data["activations"][0])
        self.assertEqual(len(json.loads((Path(self.tmp.name) / "chase-activated.json").read_text())), 1)

    def test_persistence_failure_retains_canonical_verified_record(self):
        (Path(self.tmp.name) / "chase-activated.json").write_text("broken")
        with self.assertRaises(ValueError):
            self.j.record("chase", "chase::example", merchant="Example")
        self.assertEqual(len(json.loads(self.path.read_text())["activations"]), 1)

    def test_completion_requires_both_issuers_and_signout(self):
        self.j.issuer("chase", status="completed", sign_out="verified")
        self.assertEqual(self.j.finish(), "partial")
        self.j.issuer("amex", status="completed", sign_out="verified")
        self.assertEqual(self.j.finish(), "completed")

    def test_failed_transaction_keeps_previous_document(self):
        before = self.path.read_bytes()
        with self.assertRaises(RuntimeError), self.j.transaction() as data:
            data["status"] = "completed"
            raise RuntimeError("interrupted")
        self.assertEqual(self.path.read_bytes(), before)

    def test_later_verified_signout_resolves_only_its_transient_failure(self):
        with self.j.transaction() as data:
            data["failures"].append({"issuer": "chase", "reason": "sign-out not verified"})
        for name in ("chase", "amex"):
            self.j.issuer(name, status="completed", sign_out="verified")
        self.assertEqual(self.j.finish(), "completed")
        self.assertTrue(json.loads(self.path.read_text())["failures"][0]["resolved"])
        with self.j.transaction() as data:
            data["failures"].append({"issuer": "amex", "reason": "persistence gap"})
        self.assertEqual(self.j.finish(), "partial")
