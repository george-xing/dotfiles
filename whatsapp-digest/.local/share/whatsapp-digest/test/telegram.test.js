import test from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdtemp, readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { sendTelegram, splitTelegramMessages } from "../src/telegram.js";

test("splitTelegramMessages keeps line-paired chunks below the configured size", () => {
  const html = ["<b>Digest</b>", ...Array.from({ length: 8 }, (_, index) => `• <b>Item ${index}</b>: ${"x".repeat(120)}`)].join("\n");
  const text = ["Digest", ...Array.from({ length: 8 }, (_, index) => `• Item ${index}: ${"x".repeat(120)}`)].join("\n");

  const chunks = splitTelegramMessages({ html, text, maxChars: 420 });

  assert.equal(chunks.length, 3);
  assert.ok(chunks.every((chunk) => chunk.html.length <= 420));
  assert.ok(chunks.every((chunk) => chunk.text.length <= 420));
  assert.equal(chunks.map((chunk) => chunk.text).join("\n"), text);
});

test("sendTelegram sends each oversized digest chunk with the shared helper", async () => {
  const dir = await mkdtemp(join(tmpdir(), "wa-telegram-"));
  const runDir = join(dir, "run");
  const helper = join(dir, "fake-telegram-helper.sh");
  const htmlPath = join(dir, "digest.html");
  const textPath = join(dir, "digest.txt");
  await writeFile(
    helper,
    "#!/bin/sh\nmkdir -p \"$RUN_DIR/sent\"\nidx=$(ls \"$RUN_DIR/sent\" | wc -l | tr -d ' ')\ncp \"$TELEGRAM_MESSAGE_FILE\" \"$RUN_DIR/sent/$idx.html\"\ncp \"$TELEGRAM_MESSAGE_PLAIN_FILE\" \"$RUN_DIR/sent/$idx.txt\"\n",
  );
  await chmod(helper, 0o755);
  await writeFile(htmlPath, ["<b>Digest</b>", ...Array.from({ length: 6 }, (_, index) => `• <b>Item ${index}</b>: ${"x".repeat(120)}`)].join("\n"));
  await writeFile(textPath, ["Digest", ...Array.from({ length: 6 }, (_, index) => `• Item ${index}: ${"x".repeat(120)}`)].join("\n"));

  const code = await sendTelegram({
    htmlPath,
    textPath,
    runDir,
    helper,
    maxChars: 360,
  });

  assert.equal(code, 0);
  const sent = await readdir(join(runDir, "sent"));
  assert.equal(sent.filter((name) => name.endsWith(".html")).length, 3);
  assert.equal(await readFile(join(runDir, "sent", "0.txt"), "utf8"), "Digest\n• Item 0: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n• Item 1: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
});
