import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const DEFAULT_MAX_TELEGRAM_CHARS = 3500;

function joinedLength(lines, nextLine) {
  if (lines.length === 0) return nextLine.length;
  return lines.join("\n").length + 1 + nextLine.length;
}

export function splitTelegramMessages({ html, text, maxChars = DEFAULT_MAX_TELEGRAM_CHARS }) {
  if (html.length <= maxChars && text.length <= maxChars) {
    return [{ html, text }];
  }

  const htmlLines = html.split("\n");
  const textLines = text.split("\n");
  const lineCount = Math.max(htmlLines.length, textLines.length);
  const chunks = [];
  let currentHtml = [];
  let currentText = [];

  function pushCurrent() {
    if (currentHtml.length === 0 && currentText.length === 0) return;
    chunks.push({
      html: currentHtml.join("\n"),
      text: currentText.join("\n"),
    });
    currentHtml = [];
    currentText = [];
  }

  for (let index = 0; index < lineCount; index += 1) {
    const htmlLine = htmlLines[index] ?? "";
    const textLine = textLines[index] ?? "";
    const htmlWouldOverflow = currentHtml.length > 0 && joinedLength(currentHtml, htmlLine) > maxChars;
    const textWouldOverflow = currentText.length > 0 && joinedLength(currentText, textLine) > maxChars;
    if (htmlWouldOverflow || textWouldOverflow) {
      pushCurrent();
    }
    currentHtml.push(htmlLine);
    currentText.push(textLine);
  }
  pushCurrent();

  return chunks;
}

function sendTelegramFileSet({ chatId, htmlPath, textPath, runDir, helper }) {
  return new Promise((resolve, reject) => {
    const child = spawn(helper, {
      stdio: "inherit",
      env: {
        ...process.env,
        TELEGRAM_CHAT_ID: chatId,
        TELEGRAM_MESSAGE_FILE: htmlPath,
        TELEGRAM_MESSAGE_PLAIN_FILE: textPath,
        RUN_DIR: runDir,
      },
    });
    child.on("error", reject);
    child.on("close", (code) => resolve(code ?? 2));
  });
}

export async function sendTelegram({
  chatId = "7953915703",
  htmlPath,
  textPath,
  runDir,
  helper = "/Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh",
  maxChars = DEFAULT_MAX_TELEGRAM_CHARS,
} = {}) {
  const [html, text] = await Promise.all([
    readFile(htmlPath, "utf8"),
    readFile(textPath, "utf8"),
  ]);
  const chunks = splitTelegramMessages({ html, text, maxChars });
  if (chunks.length === 1) {
    return sendTelegramFileSet({ chatId, htmlPath, textPath, runDir, helper });
  }

  const partsDir = join(runDir, "telegram-parts");
  await mkdir(partsDir, { recursive: true });
  for (const [index, chunk] of chunks.entries()) {
    const partHtmlPath = join(partsDir, `digest-${index + 1}.html`);
    const partTextPath = join(partsDir, `digest-${index + 1}.txt`);
    await Promise.all([
      writeFile(partHtmlPath, chunk.html),
      writeFile(partTextPath, chunk.text),
    ]);
    const code = await sendTelegramFileSet({
      chatId,
      htmlPath: partHtmlPath,
      textPath: partTextPath,
      runDir,
      helper,
    });
    if (code !== 0) return code;
  }
  return 0;
}
