"""Secret-free, atomic bookkeeping for Hermes's native browser workflow.

This module never opens a browser or reads credentials. Import it from
browser_exec so persistence does not depend on shell heredoc approvals.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import tempfile


def now():
    return datetime.now(timezone.utc).isoformat()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".journal-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class Journal:
    def __init__(self, path):
        self.path = Path(path).expanduser()

    @contextmanager
    def transaction(self):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.path.with_suffix(".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            data = json.loads(self.path.read_text()) if self.path.exists() else {
                "started_at": now(), "status": "running", "issuers": {},
                "activations": [], "failures": [],
            }
            yield data
            data["updated_at"] = now()
            atomic_json(self.path, data)

    def prepare(self):
        """Exercise the actual persistence path before any bank mutation."""
        with self.transaction():
            pass

    def issuer(self, name, **fields):
        if name not in ("chase", "amex"):
            raise ValueError("Unknown issuer")
        with self.transaction() as data:
            current = data["issuers"].setdefault(name, {"login_submissions": 0, "status": "running"})
            if "login_submissions" in fields:
                raise ValueError("Use reserve_login to record submissions")
            current.update(fields)

    def reserve_login(self, name):
        with self.transaction() as data:
            issuer = data["issuers"][name]
            if issuer.get("login_submissions", 0):
                raise ValueError("Login submission already reserved for this run")
            issuer.update(login_submissions=1, submission_recorded_at=now())

    def reserve_offer(self, name, key):
        """Persist click intent first. An uncertain click must only be probed."""
        with self.transaction() as data:
            issuer = data["issuers"][name]
            attempted = issuer.setdefault("attempted_offers", [])
            if key in attempted:
                raise ValueError("Offer already attempted; inspect its live state without clicking")
            attempted.append(key)
            issuer["pending_offer"] = key

    def record(self, name, key, **offer):
        # Whitelist nonsecret metadata; callers cannot accidentally dump tool results.
        allowed = {k: offer[k] for k in ("merchant", "deal", "offer_id", "card_id", "proof") if k in offer}
        with self.transaction() as data:
            issuer = data["issuers"][name]
            if issuer.get("pending_offer") not in (None, key):
                raise ValueError("Verified offer does not match reserved click")
            if not any(a.get("key") == key and a.get("issuer") == name for a in data["activations"]):
                data["activations"].append({"issuer": name, "key": key, "verified_at": now(), **allowed})
            issuer.pop("pending_offer", None)
            issuer["activation_count"] = sum(a["issuer"] == name for a in data["activations"])
        # The journal is canonical. A failed legacy-index write cannot erase proof.
        dedup = self.path.parent.parent / f"{name}-activated.json"
        with dedup.with_suffix(".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            values = json.loads(dedup.read_text()) if dedup.exists() else []
            if not isinstance(values, list):
                raise ValueError("Invalid legacy activation index")
            if not any(v.get("url") == key for v in values):
                values.append({"url": key, "digestedAt": now()})
                atomic_json(dedup, values)

    def finish(self):
        with self.transaction() as data:
            # A later read-only probe can verify sign-out after a transient
            # redirect. Preserve that history without reporting it unresolved.
            for failure in data["failures"]:
                if (isinstance(failure, dict)
                        and failure.get("reason") == "sign-out not verified"
                        and data["issuers"].get(failure.get("issuer"), {}).get("sign_out") == "verified"):
                    failure.update(resolved=True, resolved_at=now(), proof="subsequent sign_out verified")
            unresolved = any(not isinstance(f, dict) or not f.get("resolved") for f in data["failures"])
            complete = not unresolved and all(
                data["issuers"].get(name, {}).get("status") == "completed"
                and data["issuers"][name].get("sign_out") == "verified"
                and not data["issuers"][name].get("pending_offer")
                for name in ("chase", "amex")
            )
            data["status"] = "completed" if complete else "partial"
            data["ended_at"] = now()
        return data["status"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["prepare", "finish"])
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    journal = Journal(args.path)
    print(journal.prepare() if args.action == "prepare" else journal.finish())
