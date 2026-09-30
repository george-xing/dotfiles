import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { discoverGroups } from "../src/discover-groups.js";

test("discoverGroups queries each configured group and writes candidate matches", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-discover-"));
  const groupsPath = join(dir, "groups.example.json");
  const outPath = join(dir, "groups.discovered.json");
  await writeFile(
    groupsPath,
    JSON.stringify({
      groups: [
        { name: "PEF NYC", query: "PEF NYC", groupId: null, enabled: true },
        { name: "Founders Club NY", query: "Founders", groupId: null, enabled: true },
      ],
    }),
  );

  const calls = [];
  const result = await discoverGroups({
    groupsPath,
    outPath,
    whatsApp: {
      async listGroups(args) {
        calls.push(args);
        return args.query === "PEF NYC"
          ? [{ id: "g1@g.us", name: "PEF NYC", unreadCount: 3, lastMessageAt: "2026-06-16T01:00:00.000Z" }]
          : [{ id: "g2@g.us", name: "Founders Club NY", unreadCount: 0, lastMessageAt: null }];
      },
    },
  });

  assert.deepEqual(calls, [
    { query: "PEF NYC", limit: 20 },
    { query: "Founders", limit: 20 },
  ]);
  assert.equal(result.discoveries.length, 2);
  assert.deepEqual(JSON.parse(await readFile(outPath, "utf8")), result);
});
