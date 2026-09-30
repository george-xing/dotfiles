import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { runDigest } from "../src/digest-cli.js";

function configWithOneGroup() {
  return JSON.stringify({
    groups: [{ name: "PEF NYC", query: "PEF NYC", groupId: "g1@g.us", enabled: true }],
  });
}

function fakeWhatsApp() {
  return {
    async readGroupMessages() {
      return {
        group: { id: "g1@g.us", name: "PEF NYC" },
        messages: [
          {
            id: "m1",
            chatId: "g1@g.us",
            senderId: "a@c.us",
            sentAt: "2026-06-16T11:00:00.000Z",
            text: "Hiring a staff engineer, any referrals?",
            type: "chat",
            hasMedia: false,
            fromMe: false,
          },
        ],
      };
    },
  };
}

test("runDigest advances cursors after Telegram success", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-delivery-"));
  const groupsPath = join(dir, "groups.json");
  const stateDir = join(dir, "state");
  await writeFile(groupsPath, configWithOneGroup());

  await runDigest({
    dryRun: false,
    groupsPath,
    stateDir,
    runDir: join(dir, "run"),
    now: new Date("2026-06-16T12:00:00.000Z"),
    whatsApp: fakeWhatsApp(),
    telegram: async () => 0,
  });

  assert.deepEqual(JSON.parse(await readFile(join(stateDir, "group-cursors.json"), "utf8")), {
    "g1@g.us": 1781607600,
  });
  assert.equal(JSON.parse(await readFile(join(stateDir, "last-success.json"), "utf8")).telegramOk, true);
});

test("runDigest preserves cursors when Telegram fails", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-delivery-"));
  const groupsPath = join(dir, "groups.json");
  const stateDir = join(dir, "state");
  await writeFile(groupsPath, configWithOneGroup());

  await assert.rejects(
    () =>
      runDigest({
        dryRun: false,
        groupsPath,
        stateDir,
        runDir: join(dir, "run"),
        now: new Date("2026-06-16T12:00:00.000Z"),
        whatsApp: fakeWhatsApp(),
        telegram: async () => 2,
      }),
    /Telegram delivery failed/,
  );

  await assert.rejects(() => readFile(join(stateDir, "group-cursors.json"), "utf8"), /ENOENT/);
  assert.equal(JSON.parse(await readFile(join(stateDir, "last-failure.json"), "utf8")).kind, "telegram");
});
