#!/usr/bin/env python3
"""Validate that composed digest HTML matches a twitter-digest audit."""

import html
import json
import re
import sys
from pathlib import Path


TWEET_BULLET_RE = re.compile(
    r"^\s*•\s*<a\s+href=[\"'](https://(?:x|twitter)\.com/[^\"']+/status/\d+)[\"'][^>]*>.*?</a>:",
    re.MULTILINE,
)


def canonical_url(url):
    return html.unescape(url).replace("https://twitter.com/", "https://x.com/")


def issue(kind, message):
    return f"{kind}: {message}"


def validate(audit, digest_html):
    errors = []
    warnings = []

    shipped_urls = audit.get("shippedUrls")
    if not isinstance(shipped_urls, list) or not all(isinstance(u, str) for u in shipped_urls):
        errors.append(issue("error", "shippedUrls must be an array of strings"))
        shipped_urls = []

    shipped_count = audit.get("shippedCount")
    if not isinstance(shipped_count, int):
        errors.append(issue("error", "shippedCount must be an integer"))
        shipped_count = len(shipped_urls)

    expected_urls = sorted(canonical_url(u) for u in shipped_urls)
    observed_urls = sorted(canonical_url(u) for u in TWEET_BULLET_RE.findall(digest_html))
    tweet_bullet_count = len(TWEET_BULLET_RE.findall(digest_html))

    if "<missing summary>" in digest_html:
        errors.append(issue("error", "digest contains missing-summary placeholder"))

    if observed_urls != expected_urls:
        missing = sorted(set(expected_urls) - set(observed_urls))
        extra = sorted(set(observed_urls) - set(expected_urls))
        detail = []
        if missing:
            detail.append(f"missing={missing[:5]}")
        if extra:
            detail.append(f"extra={extra[:5]}")
        suffix = f" ({'; '.join(detail)})" if detail else ""
        errors.append(issue("error", f"digest tweet URLs do not match shippedUrls{suffix}"))

    if tweet_bullet_count != shipped_count:
        errors.append(
            issue("error", f"digest bullet count does not match shippedCount ({tweet_bullet_count} != {shipped_count})")
        )

    if len(observed_urls) != len(set(observed_urls)):
        warnings.append(issue("warning", "digest contains duplicate tweet links"))

    return errors, warnings


def main(argv):
    if len(argv) != 3:
        print("usage: validate-digest-output.py <audit.json> <digest.html>", file=sys.stderr)
        return 2

    try:
        audit = json.loads(Path(argv[1]).read_text())
    except Exception as exc:
        print(f"error: failed to parse audit JSON: {exc}")
        return 1

    try:
        digest_html = Path(argv[2]).read_text()
    except Exception as exc:
        print(f"error: failed to read digest HTML: {exc}")
        return 1

    errors, warnings = validate(audit, digest_html)
    for line in errors + warnings:
        print(line)
    print(f"errors: {len(errors)}")
    print(f"warnings: {len(warnings)}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
