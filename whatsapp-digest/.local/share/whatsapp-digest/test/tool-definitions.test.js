import test from "node:test";
import assert from "node:assert/strict";

import { toolDefinitions } from "../src/tool-definitions.js";

test("toolDefinitions exposes only read-only WhatsApp tools", () => {
  assert.deepEqual(
    toolDefinitions.map((tool) => tool.name),
    ["whatsapp_status", "whatsapp_list_groups", "whatsapp_read_group_messages"],
  );
});

test("read group messages tool requires a groupId", () => {
  const readTool = toolDefinitions.find((tool) => tool.name === "whatsapp_read_group_messages");

  assert.deepEqual(readTool.inputSchema.required, ["groupId"]);
  assert.equal(readTool.inputSchema.properties.groupId.type, "string");
});
