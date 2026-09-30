#!/usr/bin/env python3
"""Idempotently install the daily Hermes maintenance job into this profile."""
import argparse
import os
from pathlib import Path
import shlex
import sys

REPO = Path(__file__).resolve().parents[2]
HERMES = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
sys.path.insert(0, str(HERMES / "hermes-agent"))


def main():
    from cron.jobs import create_job, list_jobs, update_job
    parser = argparse.ArgumentParser()
    parser.add_argument("--deliver", help="Hermes target; defaults to existing cards job's target")
    parser.add_argument("--schedule", default="0 9 * * *", help="Uses the gateway's local timezone")
    args = parser.parse_args()
    jobs = list_jobs(include_disabled=True)
    cards = next((j for j in jobs if "credit-card-offers" in j.get("skills", [])), {})
    deliver = args.deliver or cards.get("deliver")
    if not deliver:
        parser.error("Pass --deliver telegram:CHAT_ID (or local)")
    skill = REPO / "automation/.hermes/skills/hermes-maintenance"
    link = HERMES / "skills/hermes-maintenance"
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.exists() or link.is_symlink():
        if link.resolve() != skill.resolve():
            raise RuntimeError(f"Existing skill at {link} points elsewhere")
    else:
        link.symlink_to(skill, target_is_directory=True)
    scripts = HERMES / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    # Hermes requires a real script inside its scripts directory, not a symlink
    # escaping it. The wrapper calls the maintained source in the dotfiles repo.
    wrapper = scripts / "automation_health.sh"
    interpreter = HERMES / "hermes-agent/venv/bin/python"
    helper = REPO / "automation/bin/hermes_health.py"
    wrapper.write_text("#!/bin/bash\nset -euo pipefail\nexec " + shlex.quote(str(interpreter)) + " " + shlex.quote(str(helper)) + " check\n")
    wrapper.chmod(0o700)
    settings = dict(name="Daily Hermes maintenance", schedule=args.schedule,
                    prompt="Check all enabled Hermes jobs. Follow hermes-maintenance to diagnose failures, repair the local source, test and rerun supported workflows until healthy or a documented stopping condition. Return only verified outcomes or required user action.",
                    skills=["hermes-maintenance"], script=wrapper.name,
                    deliver=deliver, enabled_toolsets=["terminal", "file", "skills", "browser"],
                    workdir=str(REPO))
    existing = [j for j in jobs if "hermes-maintenance" in j.get("skills", [])]
    if len(existing) > 1:
        raise RuntimeError("Multiple maintenance jobs exist; resolve duplicates first")
    if existing:
        job = update_job(existing[0]["id"], {**settings, "enabled": True})
    else:
        job = create_job(**settings)
    print(f"Installed {job['id']}: {args.schedule}; delivery {deliver}")


if __name__ == "__main__":
    main()
