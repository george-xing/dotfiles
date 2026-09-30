import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { writeQrArtifacts } from "../src/qr-artifacts.js";

test("writeQrArtifacts persists QR payload and png for easier scanning", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-qr-"));

  const result = await writeQrArtifacts(dir, "sample-qr-payload");

  assert.equal(await readFile(result.textPath, "utf8"), "sample-qr-payload\n");
  assert.ok((await stat(result.pngPath)).size > 0);
});
