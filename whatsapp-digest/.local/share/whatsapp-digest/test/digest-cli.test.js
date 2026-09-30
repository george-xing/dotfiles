import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { runDigest } from "../src/digest-cli.js";

test("runDigest dry-run writes audit and digest files without advancing success cursors", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-digest-"));
  const groupsPath = join(dir, "groups.json");
  const stateDir = join(dir, "state");
  const runDir = join(dir, "run");
  await writeFile(
    groupsPath,
    JSON.stringify({
      groups: [{ name: "PEF NYC", query: "PEF NYC", groupId: "g1@g.us", enabled: true }],
    }),
  );

  const result = await runDigest({
    dryRun: true,
    groupsPath,
    stateDir,
    runDir,
    now: new Date("2026-06-16T12:00:00.000Z"),
    whatsApp: {
      async readGroupMessages() {
        return {
          group: { id: "g1@g.us", name: "PEF NYC" },
          messages: [
            {
              id: "m1",
              chatId: "g1@g.us",
              senderId: "a@c.us",
              sentAt: "2026-06-16T11:00:00.000Z",
              text: "Anyone have June 25 tickets?",
              type: "chat",
              hasMedia: false,
              fromMe: false,
            },
          ],
        };
      },
    },
    telegram: async () => {
      throw new Error("telegram should not be called in dry-run");
    },
  });

  assert.equal(result.telegramSent, false);
  assert.match(await readFile(join(runDir, "digest.html"), "utf8"), /WhatsApp digest/);
  await assert.rejects(() => readFile(join(stateDir, "last-success.json"), "utf8"), /ENOENT/);
});
