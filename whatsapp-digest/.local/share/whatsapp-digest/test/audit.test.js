import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { writeCandidateAudit } from "../src/audit.js";

test("writeCandidateAudit persists considered and selected outcomes", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-audit-"));

  const path = await writeCandidateAudit(dir, {
    runAt: "2026-06-16T02:00:00.000Z",
    dryRun: true,
    groupsScanned: 1,
    messagesReviewed: 2,
    candidates: [
      { groupName: "PEF NYC", text: "Anyone have tickets?", selected: true, rejectionReason: null },
      { groupName: "PEF NYC", text: "lol", selected: false, rejectionReason: "low_signal" },
    ],
    sections: [{ name: "Needs attention", itemCount: 1 }],
  });

  assert.deepEqual(await readdir(dir), ["2026-06-16T02-00-00.000Z.json"]);
  const audit = JSON.parse(await readFile(path, "utf8"));
  assert.equal(audit.candidates.length, 2);
  assert.equal(audit.candidates[0].selected, true);
  assert.equal(audit.candidates[1].rejectionReason, "low_signal");
});
