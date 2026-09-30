#!/usr/bin/python3
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
PROFILE = ROOT / "config/cards-agent.sb"
SANDBOX = "/usr/bin/sandbox-exec"


class AgentSandboxTests(unittest.TestCase):
    def run_sandboxed(self, *command):
        return subprocess.run(
            [SANDBOX, "-f", str(PROFILE), *command],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode

    def test_normal_process_execution_is_allowed(self):
        self.assertEqual(self.run_sandboxed("/usr/bin/true"), 0)

    def test_secret_reference_config_is_unreadable(self):
        self.assertNotEqual(
            self.run_sandboxed(
                "/bin/sh", "-c",
                "test -r /Users/pattybot/.config/cards/onepassword.conf",
            ),
            0,
        )

    def test_credential_tools_cannot_execute(self):
        for tool in (
            "/Users/pattybot/.local/bin/cards-keychain",
            "/Users/pattybot/.local/bin/op",
            "/usr/bin/security",
            "/usr/bin/osascript",
        ):
            with self.subTest(tool=tool):
                self.assertNotEqual(self.run_sandboxed(tool), 0)

    def test_security_controls_are_immutable(self):
        command = f"printf x >> {PROFILE}"
        self.assertNotEqual(self.run_sandboxed("/bin/sh", "-c", command), 0)

    def test_fire_wrapper_enforces_profile(self):
        wrapper = (ROOT / "bin/cards-fire.sh").read_text()
        self.assertIn('"$SANDBOX_EXEC" -f "$AGENT_SANDBOX" "$CODEX_BIN"', wrapper)

    def test_fire_wrapper_requires_current_success_state(self):
        wrapper = (ROOT / "bin/cards-fire.sh").read_text()
        self.assertIn('completed >= started and state.get("telegramOk") is True', wrapper)
        self.assertIn('Path(path).with_name("pending.json").unlink()', wrapper)
        self.assertIn('STATUS=4', wrapper)

    def test_fire_wrapper_reports_issuer_specific_auth_failure(self):
        wrapper = (ROOT / "bin/cards-fire.sh").read_text()
        self.assertIn('failures.append(f"{issuer} kind:{kind} — {message}")', wrapper)
        self.assertIn('write_failure "$AUTH_KIND" "$AUTH_SUMMARY"', wrapper)
        self.assertIn('Card offers paused: $AUTH_SUMMARY', wrapper)

    def test_fire_wrapper_continues_with_partial_authentication(self):
        wrapper = (ROOT / "bin/cards-fire.sh").read_text()
        self.assertIn('AUTH_READY_COUNT=', wrapper)
        self.assertIn('continuing with authenticated issuer(s)', wrapper)
        self.assertIn('Process only issuers marked available', wrapper)
        self.assertIn('CARDS_AVAILABLE_ISSUERS="$AUTH_AVAILABLE_ISSUERS"', wrapper)

    def test_fire_wrapper_logs_out_before_full_auth_failure_exit(self):
        wrapper = (ROOT / "bin/cards-fire.sh").read_text()
        failure_block = wrapper.index('if [[ "$AUTH_STATUS" != "0" && "$AUTH_READY_COUNT" -eq 0 ]]')
        logout = wrapper.index("perform_logout", failure_block)
        auth_exit = wrapper.index('exit "$AUTH_STATUS"', failure_block)
        self.assertLess(logout, auth_exit)

    def test_cards_prefire_has_cuadriver_fallback(self):
        prefire = (ROOT / "bin/cards-prefire.sh").read_text()
        self.assertIn("trying CuaDriver fallback", prefire)
        self.assertIn('"$CUA_DRIVER_BIN" call bring_to_front', prefire)
        self.assertIn('"$CUA_DRIVER_BIN" call click', prefire)


if __name__ == "__main__":
    unittest.main()
