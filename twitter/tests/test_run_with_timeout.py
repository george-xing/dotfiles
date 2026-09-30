import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


RUNNER = Path(__file__).parents[1] / "bin" / "lib" / "run-with-timeout.py"


class RunWithTimeoutTests(unittest.TestCase):
    def run_runner(self, timeout, *command):
        return subprocess.run(
            [sys.executable, str(RUNNER), "--timeout", str(timeout), "--grace", "0.2", "--", *command],
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_preserves_child_exit_code(self):
        result = self.run_runner(2, "/bin/sh", "-c", "exit 7")
        self.assertEqual(result.returncode, 7)

    def test_timeout_returns_124(self):
        result = self.run_runner(0.2, "/bin/sh", "-c", "sleep 5")
        self.assertEqual(result.returncode, 124)
        self.assertIn("timed out after 0.2s", result.stderr)

    def test_timeout_reaps_descendant_process_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / "child.pid"
            script = (
                "import pathlib,subprocess,time; "
                f"p=subprocess.Popen(['/bin/sleep','5']); pathlib.Path({str(pid_file)!r}).write_text(str(p.pid)); "
                "time.sleep(5)"
            )
            result = self.run_runner(0.4, sys.executable, "-c", script)
            self.assertEqual(result.returncode, 124)
            child_pid = int(pid_file.read_text())
            time.sleep(0.1)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)


if __name__ == "__main__":
    unittest.main()
