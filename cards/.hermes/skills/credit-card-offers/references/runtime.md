# Bookkeeping and recovery

Use this helper inside the same native `browser_exec` session as bank actions.
It does no navigation, credential access or activation. It replaces repeated
shell heredocs that unattended cron rejects, and persists each result as it
happens. Keep the existing cron approval policy.

```python
from pathlib import Path
from datetime import datetime, timezone
import sys
sys.path.insert(0, str(Path.home() / "dotfiles/cards/bin"))
from cards_journal import Journal
stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
journal = Journal(Path.home() / ".claude/skills/credit-card-offers/state/hermes-runs" / (stamp + ".json"))
journal.prepare()  # Fail before bank actions if this write is unavailable.
journal.issuer("chase", tab_id=chase_target_id)
journal.issuer("amex", tab_id=amex_target_id)
```

Keep this journal path for the whole run. Before the single login submission,
call `journal.reserve_login(issuer)`. Use `journal.issuer(issuer, **fields)` to
record the fill results, verified offers page, failure reason, or sign-out.
Never include credentials or full tool receipts.

For each observed available offer: calculate its existing dedup key, call
`journal.reserve_offer(issuer, key)`, click once, and verify through read-only
polls. On proof, call
`journal.record(issuer, key, merchant=merchant, deal=deal, offer_id=offer_id)`;
Amex uses `card_id=card_label`. This writes the canonical journal before the
legacy index. If index persistence fails, stop further clicks; the verified
record remains available for repair. Do not replay an uncertain click.

Handle each issuer independently but finish its activation loop before moving
to the other issuer. With 40 model turns, aim to reach the first issuer's loop
by turn 12, the second by turn 25, and sign-out/finalization by turn 35. These
are planning targets, not reasons to skip available offers or claim completion.
Use the named native browser session's Python loop to batch work. Test syntax
before any side effects; Python uses `"log in" in title.lower()`, never `/log in/i`.

A read timeout before a mutation can be retried up to three times, reattaching
to the same target with `switch_tab` and using a small serializable probe.
After a click or navigation timeout, first inspect the live target to determine
whether the action happened; retry only reads. Never resubmit a login or offer.
Stop on real rejection, MFA, CAPTCHA, or device verification.

After exhausting available offers and verifying sign-out:
`journal.issuer(issuer, status="completed", sign_out="verified")`.
Use `partial` or a specific blocked status otherwise. End with `journal.finish()`;
it requires both completed issuers and verified sign-out for overall completion.
An interrupted journal remains partial/running and wakes daily maintenance.
Sign-out redirects can hydrate slowly too: poll the login wall read-only before
recording failure. A later verified sign-out resolves the exact transient
`sign-out not verified` journal failure during `finish()`, preserving its history.
