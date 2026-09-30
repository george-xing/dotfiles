import { mkdir, rm, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

import { writeCandidateAudit } from "./audit.js";
import { isDirectRun } from "./cli-main.js";
import { loadCursors, nextCursorFromMessages, saveCursors } from "./cursors.js";
import { composeDigest, scoreAndSectionMessages } from "./compose-digest.js";
import { loadGroupConfig } from "./group-config.js";
import { createWhatsAppMcpReader } from "./mcp-client.js";
import { sendTelegram } from "./telegram.js";

const DEFAULT_ROOT = "/Users/pattybot/.claude/skills/whatsapp-digest";

async function writeJsonAtomic(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(tmp, path);
}

function dateLabel(now) {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    month: "short",
    day: "numeric",
    year: "numeric",
  }).format(now);
}

function toCandidateMessages(group, messages) {
  return messages.map((message) => ({
    ...message,
    groupName: group.name,
    groupId: group.groupId,
  }));
}

async function writeFailure(stateDir, failure) {
  await writeJsonAtomic(join(stateDir, "last-failure.json"), {
    at: new Date().toISOString(),
    ...failure,
  });
}

export async function runDigest({
  dryRun = false,
  groupsPath = join(DEFAULT_ROOT, "references", "groups.json"),
  stateDir = join(DEFAULT_ROOT, "state"),
  runDir = "/tmp/whatsapp-digest-run",
  now = new Date(),
  whatsApp,
  telegram,
} = {}) {
  const closeReader = !whatsApp;
  const reader = whatsApp ?? (await createWhatsAppMcpReader());
  const send = telegram ?? sendTelegram;

  try {
    await mkdir(runDir, { recursive: true });
    await mkdir(stateDir, { recursive: true });
    const groups = await loadGroupConfig(groupsPath);
    const cursorPath = join(stateDir, "group-cursors.json");
    const cursors = await loadCursors(cursorPath);

    const perGroup = [];
    for (const group of groups) {
      const afterTimestamp = Number.isFinite(cursors[group.groupId]) ? cursors[group.groupId] : 0;
      const result = await reader.readGroupMessages({
        groupId: group.groupId,
        limit: group.limit,
        afterTimestamp,
      });
      perGroup.push({
        group,
        messages: result.messages ?? [],
      });
    }

    const messages = perGroup.flatMap(({ group, messages: groupMessages }) =>
      toCandidateMessages(group, groupMessages),
    );
    const scored = scoreAndSectionMessages(messages);
    const digest = composeDigest({
      dateLabel: dateLabel(now),
      sections: scored.sections,
      groupsScanned: groups.length,
      messagesReviewed: messages.length,
    });

    const htmlPath = join(runDir, "digest.html");
    const textPath = join(runDir, "digest.txt");
    await writeFile(htmlPath, digest.html, { mode: 0o600 });
    await writeFile(textPath, digest.text, { mode: 0o600 });

    const runAt = now.toISOString();
    const auditPath = await writeCandidateAudit(join(stateDir, "candidate-audits"), {
      runAt,
      dryRun,
      groupsScanned: groups.length,
      messagesReviewed: messages.length,
      selectedCount: scored.selected.length,
      rejectedCount: scored.rejected.length,
      sections: scored.sections.map((section) => ({
        name: section.name,
        itemCount: section.items.length,
      })),
      candidates: scored.candidates.map((candidate) => ({
        groupName: candidate.groupName,
        groupId: candidate.groupId,
        messageId: candidate.id,
        senderId: candidate.senderId,
        senderName: candidate.senderName,
        sentAt: candidate.sentAt,
        sourceUrl: candidate.sourceUrl,
        text: candidate.text,
        selected: candidate.selected,
        section: candidate.sectionName,
        score: candidate.score,
        rejectionReason: candidate.rejectionReason,
      })),
    });

    if (dryRun) {
      return {
        dryRun: true,
        telegramSent: false,
        auditPath,
        htmlPath,
        textPath,
        selectedCount: scored.selected.length,
      };
    }

    const pending = {
      runAt,
      groupsScanned: groups.length,
      messagesReviewed: messages.length,
      selectedCount: scored.selected.length,
      auditPath,
      telegramOk: null,
    };
    await writeJsonAtomic(join(stateDir, "pending.json"), pending);

    const telegramExit = await send({ htmlPath, textPath, runDir });
    if (telegramExit !== 0) {
      await writeFailure(stateDir, {
        kind: "telegram",
        message: `Telegram delivery failed with exit ${telegramExit}`,
        auditPath,
      });
      throw new Error(`Telegram delivery failed with exit ${telegramExit}`);
    }

    const nextCursors = { ...cursors };
    for (const { group, messages: groupMessages } of perGroup) {
      nextCursors[group.groupId] = nextCursorFromMessages(nextCursors[group.groupId] ?? 0, groupMessages);
    }
    await saveCursors(cursorPath, nextCursors);
    await writeJsonAtomic(join(stateDir, "last-success.json"), {
      ...pending,
      telegramOk: true,
    });
    await rm(join(stateDir, "pending.json"), { force: true });

    return {
      dryRun: false,
      telegramSent: true,
      auditPath,
      htmlPath,
      textPath,
      selectedCount: scored.selected.length,
    };
  } finally {
    if (closeReader && typeof reader.close === "function") await reader.close();
  }
}

export async function main(argv = process.argv.slice(2)) {
  const dryRun = argv.includes("--dry-run");
  const result = await runDigest({ dryRun });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (isDirectRun({ importMetaUrl: import.meta.url })) {
  main().catch((error) => {
    process.stderr.write(`whatsapp-digest: ${error.stack ?? error.message}\n`);
    process.exit(1);
  });
}
