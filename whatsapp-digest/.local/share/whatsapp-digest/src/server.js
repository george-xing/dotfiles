#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import { dispatchToolCall } from "./dispatcher.js";
import { toolDefinitions } from "./tool-definitions.js";
import { createWhatsAppTools } from "./tools.js";
import { createWhatsAppSession } from "./whatsapp-session.js";

const session = createWhatsAppSession();
const tools = createWhatsAppTools({
  getClient: session.getClient,
  waitUntilReady: session.waitUntilReady,
});

const server = new Server(
  {
    name: "whatsapp-digest-mcp",
    version: "0.1.0",
  },
  {
    capabilities: {
      tools: {},
    },
  },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: toolDefinitions,
}));

server.setRequestHandler(CallToolRequestSchema, async (request) =>
  dispatchToolCall({
    name: request.params.name,
    args: request.params.arguments ?? {},
    status: session.status,
    tools,
  }),
);

process.on("unhandledRejection", (error) => {
  process.stderr.write(`whatsapp-digest-mcp: unhandled rejection: ${error}\n`);
});

process.on("uncaughtException", (error) => {
  process.stderr.write(`whatsapp-digest-mcp: uncaught exception: ${error}\n`);
});

async function shutdown(signal) {
  process.stderr.write(`whatsapp-digest-mcp: received ${signal}, closing WhatsApp session\n`);
  try {
    await session.destroy();
  } catch (error) {
    process.stderr.write(`whatsapp-digest-mcp: shutdown error: ${error.stack ?? error.message}\n`);
  }
  process.exit(0);
}

process.on("SIGINT", () => {
  void shutdown("SIGINT");
});

process.on("SIGTERM", () => {
  void shutdown("SIGTERM");
});

await server.connect(new StdioServerTransport());
session.initialize().catch((error) => {
  process.stderr.write(`whatsapp-digest-mcp: initialize failed: ${error.stack ?? error.message}\n`);
});
