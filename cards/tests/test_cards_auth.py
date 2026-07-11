#!/usr/bin/python3
import importlib.util
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "bin/cards-auth.py"
SPEC = importlib.util.spec_from_file_location("cards_auth", MODULE_PATH)
cards_auth = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = cards_auth
SPEC.loader.exec_module(cards_auth)


VALID_CONFIG = """\
CHASE_USERNAME_REF=op://Cards/Chase/username
CHASE_PASSWORD_REF=op://Cards/Chase/password
CHASE_OTP_REF=
AMEX_USERNAME_REF=op://Cards/Amex/username
AMEX_PASSWORD_REF=op://Cards/Amex/password
AMEX_OTP_REF=op://Cards/Amex/one-time%20password
"""


class ConfigTests(unittest.TestCase):
    def config_file(self, mode=0o600):
        tmp = tempfile.NamedTemporaryFile("w", delete=False)
        tmp.write(VALID_CONFIG)
        tmp.close()
        os.chmod(tmp.name, mode)
        self.addCleanup(lambda: os.path.exists(tmp.name) and os.unlink(tmp.name))
        return Path(tmp.name)

    def test_loads_references_only(self):
        cfg = cards_auth.load_config(self.config_file())
        self.assertEqual(cfg["CHASE_USERNAME_REF"], "op://Cards/Chase/username")
        self.assertEqual(cfg["CHASE_OTP_REF"], "")

    def test_rejects_group_or_world_access(self):
        with self.assertRaisesRegex(cards_auth.AuthError, "0600"):
            cards_auth.load_config(self.config_file(0o644))

    def test_rejects_non_reference_values(self):
        path = self.config_file()
        path.write_text(VALID_CONFIG.replace("op://Cards/Chase/username", "plaintext-user"))
        with self.assertRaisesRegex(cards_auth.AuthError, "invalid secret reference"):
            cards_auth.load_config(path)


class StateTests(unittest.TestCase):
    def issuer(self, name):
        return cards_auth.Issuer(name, "", "", "", "", "", None, "", "", "", "")

    def test_loading_is_not_authenticated(self):
        probe = {"hasPassword": False, "hasUsername": False, "textLen": 7,
                 "text": "loading", "url": "https://secure.chase.com/web/auth/dashboard#/dashboard/overview"}
        self.assertFalse(cards_auth.looks_logged_in(self.issuer("Chase"), probe))

    def test_login_form_requires_both_fields(self):
        self.assertTrue(cards_auth.login_form_ready({"hasUsername": True, "hasPassword": True}))
        self.assertFalse(cards_auth.login_form_ready({"hasUsername": True, "hasPassword": False}))

    def test_sign_out_control_is_positive_auth_evidence(self):
        issuer = self.issuer("Chase")
        issuer.needle = "chase.com"
        probe = {"hasPassword": False, "hasUsername": False, "hasSignOut": True,
                 "textLen": 33, "text": "Sign out", "url": "https://secure.chase.com/dashboard"}
        self.assertTrue(cards_auth.looks_logged_in(issuer, probe))

    def test_chase_logout_landing_is_logged_out(self):
        probe = {"hasPassword": False, "url": "https://www.chase.com/logout"}
        self.assertTrue(cards_auth.looks_logged_out(self.issuer("Chase"), probe))


class SecretHandlingTests(unittest.TestCase):
    def test_op_error_does_not_echo_reference_or_stderr(self):
        proc = mock.Mock(returncode=1, stdout="", stderr="server leaked details")
        with mock.patch.object(cards_auth.subprocess, "run", return_value=proc):
            with self.assertRaises(cards_auth.AuthError) as ctx:
                cards_auth.op_read("op://Private/Very Secret/password", "service-token")
        self.assertNotIn("Very Secret", str(ctx.exception))
        self.assertNotIn("server leaked", str(ctx.exception))

    def test_password_is_argument_not_javascript_source(self):
        class FakeCDP:
            def call_function(self, obj, fn, args):
                self.fn, self.args = fn, args
                return "submitted"
        cdp = FakeCDP()
        issuer = cards_auth.Issuer("Amex", "", "", "", "u", "p", None,
                                   "document", "#u", "#p", "#go")
        cards_auth.fill_and_submit(cdp, issuer, "user@example.com", "unique-password-value")
        self.assertNotIn("unique-password-value", cdp.fn)
        self.assertEqual(cdp.args[1], "unique-password-value")

    def test_totp_is_argument_not_javascript_source(self):
        class FakeCDP:
            def call_function(self, obj, fn, args):
                self.fn, self.args = fn, args
                return "submitted"
        cdp = FakeCDP()
        issuer = cards_auth.Issuer("Amex", "", "", "", "u", "p", None,
                                   "document", "#u", "#p", "#go")
        self.assertTrue(cards_auth.submit_totp(cdp, issuer, "654321"))
        self.assertNotIn("654321", cdp.fn)
        self.assertEqual(cdp.args, ["654321"])


if __name__ == "__main__":
    unittest.main()
