import { mkdir, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

function auditFilename(runAt) {
  return `${runAt.replace(/[:+]/g, "-")}.json`;
}

export async function writeCandidateAudit(dir, audit, keep = 30) {
  await mkdir(dir, { recursive: true });
  const path = join(dir, auditFilename(audit.runAt));
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, `${JSON.stringify(audit, null, 2)}\n`, { mode: 0o600 });
  await rename(tmp, path);

  const files = (await readdir(dir))
    .filter((file) => file.endsWith(".json"))
    .sort()
    .reverse();
  await Promise.all(files.slice(keep).map((file) => rm(join(dir, file), { force: true })));
  return path;
}
