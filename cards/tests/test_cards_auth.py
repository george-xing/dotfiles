#!/usr/bin/python3
import importlib.util
import json
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

    def test_amex_login_page_is_not_a_ready_offers_page(self):
        issuer = self.issuer("Amex")
        issuer.needle = "americanexpress.com"
        probe = {"hasPassword": True, "hasUsername": True, "hasSignOut": True,
                 "textLen": 500, "text": "Log In to My Account",
                 "url": "https://www.americanexpress.com/en-US/account/login"}
        self.assertFalse(cards_auth.offers_page_ready(issuer, probe))

    def test_amex_login_header_is_not_auth_evidence_when_inputs_are_transiently_missing(self):
        issuer = self.issuer("Amex")
        issuer.needle = "americanexpress.com"
        probe = {"hasPassword": False, "hasUsername": False, "hasSignOut": True,
                 "textLen": 500, "text": "Log Out Log In to My Account",
                 "url": "https://www.americanexpress.com/en-US/account/login"}
        self.assertFalse(cards_auth.looks_logged_in(issuer, probe))

    def test_amex_protected_offers_page_is_ready(self):
        issuer = self.issuer("Amex")
        issuer.needle = "americanexpress.com"
        probe = {"hasPassword": False, "hasUsername": False, "hasSignOut": True,
                 "textLen": 500, "text": "Amex Offers Added to Card",
                 "url": "https://global.americanexpress.com/offers/eligible"}
        self.assertTrue(cards_auth.offers_page_ready(issuer, probe))

    def test_amex_intermediate_authenticated_page_waits_for_destination(self):
        issuer = self.issuer("Amex")
        issuer.needle = "americanexpress.com"
        probe = {"hasPassword": False, "hasUsername": False, "hasSignOut": True,
                 "textLen": 500, "text": "Account Summary Membership Rewards",
                 "url": "https://global.americanexpress.com/dashboard"}
        self.assertFalse(cards_auth.login_transition_settled(issuer, probe, 5))
        self.assertTrue(cards_auth.login_transition_settled(
            issuer, probe, cards_auth.AMEX_DESTINATION_GRACE_SECONDS
        ))

    def test_amex_natural_offers_destination_settles_immediately(self):
        issuer = self.issuer("Amex")
        issuer.needle = "americanexpress.com"
        probe = {"hasPassword": False, "hasUsername": False, "hasSignOut": True,
                 "textLen": 500, "text": "Amex Offers Added to Card",
                 "url": "https://global.americanexpress.com/offers/eligible"}
        self.assertTrue(cards_auth.login_transition_settled(issuer, probe, 2))

    def test_amex_returned_login_form_honors_rejection_grace(self):
        issuer = self.issuer("Amex")
        probe = {"hasPassword": True, "hasUsername": True, "textLen": 500,
                 "text": "Log In to My Account", "url": "https://www.americanexpress.com/account/login"}
        self.assertFalse(cards_auth.login_transition_settled(issuer, probe, 5))
        self.assertTrue(cards_auth.login_transition_settled(
            issuer, probe, cards_auth.LOGIN_REJECTION_GRACE_SECONDS
        ))

    def test_partial_authentication_is_not_success(self):
        results = [
            {"issuer": "Chase", "status": "authenticated"},
            {"issuer": "Amex", "status": "error", "kind": "auth"},
        ]
        self.assertFalse(cards_auth.authentication_succeeded(results))

    def test_both_issuers_must_authenticate(self):
        results = [
            {"issuer": "Chase", "status": "authenticated"},
            {"issuer": "Amex", "status": "already_authenticated"},
        ]
        self.assertTrue(cards_auth.authentication_succeeded(results))

    def test_auth_event_url_redacts_query_and_fragment(self):
        value = cards_auth.redacted_url(
            "https://example.com/login?token=secret#session"
        )
        self.assertEqual(value, "https://example.com/login")

    def test_final_amex_redirect_to_login_is_rejected(self):
        issuer = self.issuer("Amex")
        issuer.needle = "americanexpress.com"
        issuer.login_url = "https://www.americanexpress.com/en-us/account/login"
        issuer.offers_url = "https://global.americanexpress.com/offers/eligible"

        class FakeCDP:
            def eval(self, expression):
                return issuer.login_url

            def navigate(self, url):
                self.navigated = url

        authenticated_probe = json.dumps({
            "hasPassword": False, "hasUsername": False, "hasSignOut": True,
            "textLen": 500, "text": "Account Summary Membership Rewards",
            "url": "https://global.americanexpress.com/dashboard",
        })
        login_probe = json.dumps({
            "hasPassword": True, "hasUsername": True, "hasSignOut": True,
            "textLen": 500, "text": "Log In to My Account", "url": issuer.login_url,
        })
        with mock.patch.object(cards_auth.time, "sleep"), \
                mock.patch.object(cards_auth, "page_probe", side_effect=[
                    authenticated_probe, authenticated_probe, login_probe,
                ]), \
                mock.patch.object(cards_auth, "wait_until", side_effect=lambda fn, **kwargs: fn()):
            with self.assertRaisesRegex(cards_auth.AuthError, "redirected back"):
                cards_auth.finish_authenticated_navigation(FakeCDP(), issuer)


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

    def test_auth_failure_screenshot_clears_all_inputs_first(self):
        calls = []

        class FakeCDP:
            def eval(self, expression):
                calls.append(("eval", expression))
                return True

            def screenshot(self, label):
                calls.append(("screenshot", label))
                return "/tmp/scrubbed.png"

        issuer = cards_auth.Issuer("Amex", "", "", "", "u", "p", None,
                                   "document", "#u", "#p", "#go")
        error = cards_auth.auth_failure_with_screenshot(FakeCDP(), issuer, "rejected")
        self.assertEqual(calls[0][0], "eval")
        self.assertIn("querySelectorAll('input')", calls[0][1])
        self.assertEqual(calls[1], ("screenshot", "amex-auth"))
        self.assertIn("scrubbed.png", str(error))

    def test_auth_event_contains_no_query_or_page_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth-events.jsonl"
            with mock.patch.object(cards_auth, "AUTH_EVENTS", path):
                cards_auth.record_auth_event(
                    "Amex",
                    "probe",
                    url="https://example.com/login?token=secret",
                    status="authenticated",
                    text="sensitive page text",
                )
            event = json.loads(path.read_text())
            self.assertEqual(event["url"], "https://example.com/login")
            self.assertNotIn("text", event)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
