import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { loadGroupConfig } from "../src/group-config.js";

test("loadGroupConfig rejects enabled groups without a groupId", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-groups-"));
  const path = join(dir, "groups.json");
  await writeFile(
    path,
    JSON.stringify({
      groups: [{ name: "PEF NYC", query: "PEF NYC", groupId: null, enabled: true }],
    }),
  );

  await assert.rejects(() => loadGroupConfig(path), /PEF NYC.*groupId/);
});

test("loadGroupConfig returns only enabled groups with stable defaults", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-groups-"));
  const path = join(dir, "groups.json");
  await writeFile(
    path,
    JSON.stringify({
      groups: [
        { name: "PEF NYC", query: "PEF NYC", groupId: "g1@g.us", enabled: true },
        { name: "Muted", query: "Muted", groupId: "g2@g.us", enabled: false },
      ],
    }),
  );

  const groups = await loadGroupConfig(path);

  assert.deepEqual(groups, [
    {
      name: "PEF NYC",
      query: "PEF NYC",
      groupId: "g1@g.us",
      enabled: true,
      limit: 200,
    },
  ]);
});
