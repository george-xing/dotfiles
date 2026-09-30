# Daily Hermes maintenance

Checks every enabled job at 09:00 in the gateway's local timezone (New York on
this Mac). Healthy days skip the model and notification. Failures wake the
`hermes-maintenance` skill to diagnose, patch, test and rerun supported workflows.

The health check combines Hermes execution/delivery status with the latest
cards journal. A partial bank run counts as a failure even when an older cron
prompt reported success. Running jobs are left alone. Readiness, local source,
dependency and persistence failures are repairable; actual MFA or credential
rejection requires human action.

```sh
~/.hermes/hermes-agent/venv/bin/python automation/bin/install_maintenance.py --deliver telegram:YOUR_CHAT_ID
~/.hermes/hermes-agent/venv/bin/python automation/bin/hermes_health.py check
~/.hermes/hermes-agent/venv/bin/python automation/bin/hermes_health.py test cards
~/.hermes/hermes-agent/venv/bin/python automation/bin/hermes_health.py retry JOB_ID
```

Run from the repository root. The installer creates a skill symlink and a real
gate script under the active Hermes profile, then creates/updates one cron job.
Use the gateway's venv so imports match the actual scheduler. AgentMail's extra
dependency is pinned in `requirements-agentmail.txt`; reinstall it in this venv
after an environment replacement. The helper and cron APIs are validated against
the locally installed Hermes; updates to Hermes may require revalidation.

Replay adapters currently cover cards, Twitter digest and AgentMail. Other
jobs are monitored and diagnosed, but need an adapter that understands their
side effects before automatic replay. Each replay runs relevant tests, requires
changed source or a repaired dependency/client since a failed attempt, uses an
exclusive lock, and charges one of three daily attempts before launch. It then checks the resulting journal and
execution status. Private replay records and logs live in ignored `state/`.
Delivery-only failures use existing receipt/outbox recovery rather than repeating
business actions. Maintenance does not auto-push code or loosen approval rules.

The check is hosted by Hermes, so a completely stopped gateway cannot run it.
The existing launchd gateway service remains responsible for process restart.
