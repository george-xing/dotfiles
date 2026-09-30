import test from "node:test";
import assert from "node:assert/strict";

import { dispatchToolCall } from "../src/dispatcher.js";

test("dispatchToolCall returns JSON text content for status", async () => {
  const result = await dispatchToolCall({
    name: "whatsapp_status",
    args: {},
    status: () => ({ ready: true, state: "ready" }),
    tools: {},
  });

  assert.deepEqual(result, {
    content: [
      {
        type: "text",
        text: JSON.stringify({ ready: true, state: "ready" }, null, 2),
      },
    ],
  });
});

test("dispatchToolCall routes group listing to tools", async () => {
  const result = await dispatchToolCall({
    name: "whatsapp_list_groups",
    args: { query: "pef" },
    status: () => ({ ready: true }),
    tools: {
      async listGroups(args) {
        return [{ id: "g1@g.us", name: args.query }];
      },
    },
  });

  assert.equal(JSON.parse(result.content[0].text)[0].name, "pef");
});

test("dispatchToolCall rejects unknown tools", async () => {
  await assert.rejects(
    () =>
      dispatchToolCall({
        name: "whatsapp_send_message",
        args: {},
        status: () => ({}),
        tools: {},
      }),
    /Unknown tool/,
  );
});
