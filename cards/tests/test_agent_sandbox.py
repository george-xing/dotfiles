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


if __name__ == "__main__":
    unittest.main()
