#!/usr/bin/env python3
"""Verify and reconcile Twitter fire delivery state.

The model-driven workflow writes state, while the production wrapper decides
the final process status.  This helper keeps timestamp parsing and the one
safe reconciliation case deterministic: Telegram returned ``ok: true`` for a
fresh search run, but the model failed to finalize ``last-success.json``.
"""

import argparse
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def parse_iso(value):
    value = str(value).strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def load_json(path):
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


def atomic_write_json(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def is_fresh(path, field, started_at, require_telegram_ok=False):
    try:
        data = load_json(path)
        fresh = parse_iso(data[field]) >= parse_iso(started_at)
        if require_telegram_ok:
            fresh = fresh and data.get("telegramOk") is True
        return fresh
    except Exception:
        return False


def reconcile_search(state_dir, response_file, started_at, expected_chat_id):
    state_dir = Path(state_dir)
    pending_path = state_dir / "pending.json"
    response_path = Path(response_file)
    try:
        started = parse_iso(started_at)
        pending = load_json(pending_path)
        pending_at = parse_iso(pending["runAt"])
        response = load_json(response_path)
        result = response.get("result") or {}
        chat = result.get("chat") or {}
        response_date = datetime.fromtimestamp(float(result["date"]), tz=timezone.utc)
        response_mtime = datetime.fromtimestamp(response_path.stat().st_mtime, tz=timezone.utc)

        valid = (
            pending_at >= started
            and response.get("ok") is True
            and isinstance(result.get("message_id"), int)
            and str(chat.get("id")) == str(expected_chat_id)
            and response_date >= started
            and response_mtime >= started
        )
        if not valid:
            return False

        pending["telegramOk"] = True
        atomic_write_json(state_dir / "last-success.json", pending)
        pending_path.unlink()

        # A model may have recorded a false Telegram/agent failure after the
        # successful API response. Remove only a failure from this same run.
        failure_path = state_dir / "last-failure.json"
        try:
            failure = load_json(failure_path)
            if (
                parse_iso(failure["at"]) >= pending_at
                and failure.get("kind") in {"telegram", "agent"}
            ):
                failure_path.unlink()
        except Exception:
            pass
        return True
    except Exception:
        return False


def clear_superseded_failure(state_dir, started_at):
    state_dir = Path(state_dir)
    try:
        started = parse_iso(started_at)
        success = load_json(state_dir / "last-success.json")
        failure_path = state_dir / "last-failure.json"
        failure = load_json(failure_path)
        success_at = parse_iso(success["runAt"])
        failure_at = parse_iso(failure["at"])
        # Once this run has fresh, Telegram-confirmed success, any older
        # failure in the same skill state directory is historical and
        # superseded. The append-only fire log retains that forensic record;
        # leaving stale failure JSON beside newer success misleads operators
        # and dispatchers that inspect the state directory directly.
        if (
            success.get("telegramOk") is True
            and success_at >= started
            and failure_at <= success_at
        ):
            failure_path.unlink()
            return True
    except Exception:
        pass
    return False


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    fresh_parser = subparsers.add_parser("fresh")
    fresh_parser.add_argument("path")
    fresh_parser.add_argument("field")
    fresh_parser.add_argument("started_at")
    fresh_parser.add_argument("--require-telegram-ok", action="store_true")

    reconcile_parser = subparsers.add_parser("reconcile-search")
    reconcile_parser.add_argument("state_dir")
    reconcile_parser.add_argument("response_file")
    reconcile_parser.add_argument("started_at")
    reconcile_parser.add_argument("expected_chat_id")

    cleanup_parser = subparsers.add_parser("clear-superseded-failure")
    cleanup_parser.add_argument("state_dir")
    cleanup_parser.add_argument("started_at")

    args = parser.parse_args()
    if args.command == "fresh":
        result = is_fresh(
            args.path,
            args.field,
            args.started_at,
            require_telegram_ok=args.require_telegram_ok,
        )
    elif args.command == "reconcile-search":
        result = reconcile_search(
            args.state_dir,
            args.response_file,
            args.started_at,
            args.expected_chat_id,
        )
    else:
        result = clear_superseded_failure(args.state_dir, args.started_at)
    print("1" if result else "0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
