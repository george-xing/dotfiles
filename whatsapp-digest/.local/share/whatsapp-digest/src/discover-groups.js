import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

function normalizeGroupRequest(group) {
  const name = String(group.name ?? "").trim();
  const query = String(group.query ?? group.name ?? "").trim();
  if (!name) throw new Error("Configured WhatsApp group is missing name");
  if (!query) throw new Error(`${name} is missing a discovery query`);

  return {
    name,
    query,
    configuredGroupId: typeof group.groupId === "string" && group.groupId.trim() ? group.groupId.trim() : null,
    enabled: group.enabled !== false,
  };
}

async function writeJsonAtomic(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(tmp, path);
}

export async function discoverGroups({ groupsPath, outPath, whatsApp, limit = 20 } = {}) {
  if (!groupsPath) throw new Error("discoverGroups requires groupsPath");
  if (!whatsApp || typeof whatsApp.listGroups !== "function") {
    throw new Error("discoverGroups requires a WhatsApp reader with listGroups()");
  }

  const raw = await readFile(groupsPath, "utf8");
  const parsed = JSON.parse(raw);
  if (!Array.isArray(parsed.groups)) {
    throw new Error(`${groupsPath} must contain a groups array`);
  }

  const discoveries = [];
  for (const group of parsed.groups.map(normalizeGroupRequest).filter((entry) => entry.enabled)) {
    const matches = await whatsApp.listGroups({ query: group.query, limit });
    discoveries.push({
      name: group.name,
      query: group.query,
      configuredGroupId: group.configuredGroupId,
      matches,
    });
  }

  const result = { discoveries };
  if (outPath) await writeJsonAtomic(outPath, result);
  return result;
}
