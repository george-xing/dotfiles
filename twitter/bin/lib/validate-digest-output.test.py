#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate-digest-output.py")


def write_temp(suffix, content):
    tmp = tempfile.NamedTemporaryFile("w", suffix=suffix, delete=False)
    with tmp:
        tmp.write(content)
    return Path(tmp.name)


def audit(shipped_urls):
    return {
        "shippedCount": len(shipped_urls),
        "shippedUrls": shipped_urls,
        "candidates": [
            {"statusUrl": url, "shipped": True}
            for url in shipped_urls
        ],
    }


class ValidateDigestOutputTest(unittest.TestCase):
    def run_validator(self, audit_data, html):
        audit_path = write_temp(".json", json.dumps(audit_data))
        html_path = write_temp(".html", html)
        try:
            return subprocess.run(
                [str(SCRIPT), str(audit_path), str(html_path)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        finally:
            audit_path.unlink(missing_ok=True)
            html_path.unlink(missing_ok=True)

    def test_digest_matching_shipped_urls_passes(self):
        result = self.run_validator(
            audit([
                "https://x.com/a/status/1",
                "https://x.com/b/status/2",
            ]),
            """<b>Digest</b>
• <a href="https://x.com/a/status/1">@a tweeted</a>: useful item
• <a href="https://x.com/b/status/2">@b tweeted</a>: another useful item
""",
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("errors: 0", result.stdout)

    def test_missing_summary_placeholder_fails(self):
        result = self.run_validator(
            audit(["https://x.com/a/status/1"]),
            '• <a href="https://x.com/a/status/1">@a tweeted</a>: <missing summary>',
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("digest contains missing-summary placeholder", result.stdout)

    def test_digest_urls_must_match_shipped_urls(self):
        result = self.run_validator(
            audit(["https://x.com/a/status/1"]),
            '• <a href="https://x.com/b/status/2">@b tweeted</a>: wrong item',
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("digest tweet URLs do not match shippedUrls", result.stdout)

    def test_digest_bullet_count_must_match_shipped_count(self):
        result = self.run_validator(
            audit(["https://x.com/a/status/1"]),
            "",
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("digest bullet count does not match shippedCount", result.stdout)


if __name__ == "__main__":
    unittest.main()
