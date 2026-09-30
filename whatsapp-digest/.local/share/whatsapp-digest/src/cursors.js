import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export async function loadCursors(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return {};
    throw error;
  }
}

export function epochSecondsFromIso(value) {
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) return null;
  return Math.floor(ms / 1000);
}

export function nextCursorFromMessages(previousCursor, messages) {
  return messages.reduce((cursor, message) => {
    const seconds = epochSecondsFromIso(message.sentAt);
    return Number.isFinite(seconds) && seconds > cursor ? seconds : cursor;
  }, Number.isFinite(previousCursor) ? previousCursor : 0);
}

export async function saveCursors(path, cursors) {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, `${JSON.stringify(cursors, null, 2)}\n`, { mode: 0o600 });
  await rename(tmp, path);
}
