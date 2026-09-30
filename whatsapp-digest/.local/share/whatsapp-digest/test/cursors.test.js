import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { loadCursors, nextCursorFromMessages, saveCursors } from "../src/cursors.js";

test("loadCursors returns an empty cursor set when no file exists", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-cursors-"));

  assert.deepEqual(await loadCursors(join(dir, "group-cursors.json")), {});
});

test("nextCursorFromMessages advances to the newest sentAt timestamp", () => {
  const cursor = nextCursorFromMessages(100, [
    { sentAt: "2026-06-16T02:00:00.000Z" },
    { sentAt: "2026-06-16T02:05:00.000Z" },
    { sentAt: null },
  ]);

  assert.equal(cursor, 1781575500);
});

test("saveCursors writes atomically readable JSON", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-cursors-"));
  const path = join(dir, "group-cursors.json");

  await saveCursors(path, { "g1@g.us": 1781575500 });

  assert.deepEqual(JSON.parse(await readFile(path, "utf8")), { "g1@g.us": 1781575500 });
});
