import { readFile } from "node:fs/promises";

export async function loadGroupConfig(path) {
  const raw = await readFile(path, "utf8");
  const parsed = JSON.parse(raw);
  if (!Array.isArray(parsed.groups)) {
    throw new Error(`${path} must contain a groups array`);
  }

  return parsed.groups
    .map((group) => ({
      name: String(group.name ?? "").trim(),
      query: String(group.query ?? group.name ?? "").trim(),
      groupId: typeof group.groupId === "string" ? group.groupId.trim() : null,
      enabled: group.enabled !== false,
      limit: Number.isFinite(group.limit) ? Math.max(1, Math.min(500, Math.trunc(group.limit))) : 200,
    }))
    .filter((group) => group.enabled)
    .map((group) => {
      if (!group.name) throw new Error("Enabled WhatsApp group is missing name");
      if (!group.groupId) throw new Error(`${group.name} is enabled but missing groupId`);
      if (!group.groupId.endsWith("@g.us")) throw new Error(`${group.name} groupId must end with @g.us`);
      return group;
    });
}
