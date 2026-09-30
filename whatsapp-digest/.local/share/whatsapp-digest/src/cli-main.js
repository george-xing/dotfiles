import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

export function isDirectRun({ importMetaUrl, argvPath = process.argv[1], realpath = realpathSync } = {}) {
  if (!argvPath) return false;

  try {
    return realpath(fileURLToPath(importMetaUrl)) === realpath(argvPath);
  } catch {
    return false;
  }
}
