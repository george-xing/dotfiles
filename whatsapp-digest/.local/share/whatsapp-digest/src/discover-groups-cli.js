import { join } from "node:path";

import { isDirectRun } from "./cli-main.js";
import { discoverGroups } from "./discover-groups.js";
import { createWhatsAppMcpReader } from "./mcp-client.js";

const DEFAULT_ROOT = "/Users/pattybot/.claude/skills/whatsapp-digest";

function argValue(argv, name, fallback) {
  const index = argv.indexOf(name);
  if (index === -1) return fallback;
  const value = argv[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${name} requires a value`);
  return value;
}

export async function main(argv = process.argv.slice(2)) {
  const groupsPath = argValue(argv, "--groups", join(DEFAULT_ROOT, "references", "groups.example.json"));
  const outPath = argValue(argv, "--out", join(DEFAULT_ROOT, "references", "groups.discovered.json"));
  const limit = Number.parseInt(argValue(argv, "--limit", "20"), 10);
  if (!Number.isFinite(limit) || limit < 1) throw new Error("--limit must be a positive integer");

  const reader = await createWhatsAppMcpReader();
  try {
    const result = await discoverGroups({ groupsPath, outPath, whatsApp: reader, limit });
    process.stdout.write(`${JSON.stringify({ ...result, outPath }, null, 2)}\n`);
  } finally {
    if (typeof reader.close === "function") await reader.close();
  }
}

if (isDirectRun({ importMetaUrl: import.meta.url })) {
  main().catch((error) => {
    process.stderr.write(`whatsapp-digest-groups: ${error.stack ?? error.message}\n`);
    process.exit(1);
  });
}
