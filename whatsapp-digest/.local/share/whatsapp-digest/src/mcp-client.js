import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

export function mcpCallOptions(env = process.env) {
  const defaultTimeoutMs = 480000;
  const timeout = Number.parseInt(env.WHATSAPP_DIGEST_MCP_TIMEOUT_MS ?? String(defaultTimeoutMs), 10);
  return { timeout: Number.isFinite(timeout) && timeout > 0 ? timeout : defaultTimeoutMs };
}

export async function createWhatsAppMcpReader({
  command = "/Users/pattybot/bin/whatsapp-digest-mcp",
  env = {},
} = {}) {
  const client = new Client({ name: "whatsapp-digest-runner", version: "0.1.0" });
  const transport = new StdioClientTransport({
    command,
    env: { ...process.env, ...env },
  });
  await client.connect(transport);
  const callOptions = mcpCallOptions(env);

  return {
    async status() {
      const result = await client.callTool({ name: "whatsapp_status", arguments: {} }, undefined, callOptions);
      return JSON.parse(result.content[0].text);
    },
    async listGroups(args) {
      const result = await client.callTool({ name: "whatsapp_list_groups", arguments: args }, undefined, callOptions);
      return JSON.parse(result.content[0].text);
    },
    async readGroupMessages(args) {
      const result = await client.callTool({ name: "whatsapp_read_group_messages", arguments: args }, undefined, callOptions);
      return JSON.parse(result.content[0].text);
    },
    async close() {
      await client.close();
    },
  };
}
