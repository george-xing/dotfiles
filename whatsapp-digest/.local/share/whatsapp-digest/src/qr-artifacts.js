import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

import QRCode from "qrcode";

export async function writeQrArtifacts(dir, qr) {
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const textPath = join(dir, "qr.txt");
  const pngPath = join(dir, "qr.png");
  await writeFile(textPath, `${qr}\n`, { mode: 0o600 });
  await QRCode.toFile(pngPath, qr, {
    type: "png",
    margin: 4,
    width: 1024,
  });
  return { textPath, pngPath };
}
