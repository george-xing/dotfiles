import test from "node:test";
import assert from "node:assert/strict";

import { mcpCallOptions } from "../src/mcp-client.js";

test("mcpCallOptions uses a longer WhatsApp restore timeout by default", () => {
  assert.deepEqual(mcpCallOptions({}), { timeout: 480000 });
});

test("mcpCallOptions accepts a positive env override", () => {
  assert.deepEqual(mcpCallOptions({ WHATSAPP_DIGEST_MCP_TIMEOUT_MS: "240000" }), { timeout: 240000 });
});
