import { mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

import qrcode from "qrcode-terminal";

import { writeQrArtifacts } from "./qr-artifacts.js";

function defaultAuthDir() {
  return join(homedir(), ".local", "state", "whatsapp-digest", "auth");
}

function envFlag(value, fallback) {
  if (value == null || value === "") return fallback;
  return !["0", "false", "no", "off"].includes(String(value).trim().toLowerCase());
}

export const defaultChromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
export const defaultReadyTimeoutMs = 420000;
export const defaultReadyProbeIntervalMs = 10000;
export const defaultReadyProbeTimeoutMs = 15000;

export function buildPuppeteerOptions(env = process.env, { existsSync: pathExists = existsSync } = {}) {
  const options = {
    headless: envFlag(env.WHATSAPP_DIGEST_HEADLESS, true),
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
  };

  const chromePath = env.WHATSAPP_DIGEST_CHROME_PATH || (pathExists(defaultChromePath) ? defaultChromePath : "");
  if (chromePath) {
    options.executablePath = chromePath;
  }

  return options;
}

export function shouldAutoOpenQr(env = process.env) {
  return envFlag(env.WHATSAPP_DIGEST_OPEN_QR, false);
}

export function buildPairWithPhoneNumberOptions(env = process.env) {
  const phoneNumber = String(env.WHATSAPP_DIGEST_PHONE_NUMBER ?? "").replace(/\D/g, "");
  if (!phoneNumber) return undefined;

  const intervalMs = Number.parseInt(env.WHATSAPP_DIGEST_PAIR_INTERVAL_MS ?? "180000", 10);
  return {
    phoneNumber,
    showNotification: true,
    intervalMs: Number.isFinite(intervalMs) && intervalMs > 0 ? intervalMs : 180000,
  };
}

export function exitAfterReadyMs(env = process.env) {
  const ms = Number.parseInt(env.WHATSAPP_DIGEST_EXIT_AFTER_READY_MS ?? "", 10);
  return Number.isFinite(ms) && ms > 0 ? ms : null;
}

function positiveInt(value, fallback) {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function withTimeout(promise, timeoutMs, label) {
  let timeout = null;
  return Promise.race([
    promise.finally(() => {
      if (timeout) clearTimeout(timeout);
    }),
    new Promise((_, reject) => {
      timeout = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs);
    }),
  ]);
}

function openQrImage(pngPath) {
  const child = spawn("open", [pngPath], {
    detached: true,
    stdio: "ignore",
  });
  child.unref();
}

export function createWhatsAppSession({
  authDir = process.env.WHATSAPP_DIGEST_AUTH_DIR ?? defaultAuthDir(),
  readyTimeoutMs = Number(process.env.WHATSAPP_DIGEST_READY_TIMEOUT_MS ?? defaultReadyTimeoutMs),
  readyProbeIntervalMs = positiveInt(process.env.WHATSAPP_DIGEST_READY_PROBE_INTERVAL_MS, defaultReadyProbeIntervalMs),
  readyProbeTimeoutMs = positiveInt(process.env.WHATSAPP_DIGEST_READY_PROBE_TIMEOUT_MS, defaultReadyProbeTimeoutMs),
} = {}) {
  let client = null;
  let initializePromise = null;
  let lastReadyProbeAt = 0;
  const state = {
    authDir,
    ready: false,
    initializing: false,
    authenticated: false,
    lastLoadingPercent: null,
    lastQrAt: null,
    lastError: null,
    clientInfo: null,
  };

  function markReady(reason = "ready_event") {
    state.ready = true;
    state.initializing = false;
    state.lastError = null;
    state.clientInfo = client?.info
      ? {
          wid: client.info.wid?._serialized ?? null,
          pushname: client.info.pushname ?? null,
          platform: client.info.platform ?? null,
        }
      : null;
    process.stderr.write(`whatsapp-digest: WhatsApp Web session ready (${reason})\n`);
  }

  async function probeReadiness() {
    if (!client || state.ready) return state.ready;
    const now = Date.now();
    if (now - lastReadyProbeAt < readyProbeIntervalMs) return false;
    if (!state.authenticated && (state.lastLoadingPercent ?? 0) < 99) return false;
    lastReadyProbeAt = now;

    try {
      const waState = typeof client.getState === "function"
        ? await withTimeout(client.getState(), readyProbeTimeoutMs, "WhatsApp state probe")
        : null;
      if (waState) {
        process.stderr.write(`whatsapp-digest: WhatsApp Web state probe: ${waState}\n`);
      }
      if (waState === "CONNECTED") {
        markReady("state_probe");
        return true;
      }

      if (typeof client.getChats === "function") {
        const chats = await withTimeout(client.getChats(), readyProbeTimeoutMs, "WhatsApp chats probe");
        if (Array.isArray(chats)) {
          markReady("chats_probe");
          return true;
        }
      }
    } catch (error) {
      process.stderr.write(`whatsapp-digest: readiness probe failed: ${error.message}\n`);
    }

    return false;
  }

  async function initialize() {
    if (initializePromise) return initializePromise;

    initializePromise = (async () => {
      state.initializing = true;
      await mkdir(authDir, { recursive: true, mode: 0o700 });

      const whatsapp = await import("whatsapp-web.js");
      const { Client, LocalAuth } = whatsapp.default ?? whatsapp;
      client = new Client({
        authStrategy: new LocalAuth({
          clientId: "whatsapp-digest",
          dataPath: authDir,
        }),
        puppeteer: buildPuppeteerOptions(),
        pairWithPhoneNumber: buildPairWithPhoneNumberOptions(),
      });

      client.on("qr", (qr) => {
        state.lastQrAt = new Date().toISOString();
        process.stderr.write("\nwhatsapp-digest: scan this QR in WhatsApp > Linked devices\n\n");
        qrcode.generate(qr, { small: true }, (text) => process.stderr.write(`${text}\n`));
        writeQrArtifacts(join(authDir, ".."), qr)
          .then(({ pngPath, textPath }) => {
            process.stderr.write(`whatsapp-digest: latest QR image: ${pngPath}\n`);
            process.stderr.write(`whatsapp-digest: latest QR payload: ${textPath}\n`);
            if (shouldAutoOpenQr()) openQrImage(pngPath);
          })
          .catch((error) => {
            process.stderr.write(`whatsapp-digest: failed writing QR artifacts: ${error.message}\n`);
          });
      });

      client.on("loading_screen", (percent, message) => {
        state.lastLoadingPercent = Number.isFinite(percent) ? percent : state.lastLoadingPercent;
        process.stderr.write(`whatsapp-digest: loading ${percent}% ${message ?? ""}\n`);
      });

      client.on("authenticated", () => {
        state.authenticated = true;
        process.stderr.write("whatsapp-digest: WhatsApp Web session authenticated\n");
      });

      client.on("code", (code) => {
        process.stderr.write(`whatsapp-digest: WhatsApp pairing code: ${code}\n`);
        process.stderr.write("whatsapp-digest: enter it in WhatsApp > Linked Devices > Link with phone number instead\n");
      });

      client.on("change_state", (newState) => {
        process.stderr.write(`whatsapp-digest: WhatsApp Web state changed: ${newState}\n`);
      });

      client.on("ready", () => {
        markReady();
        const exitMs = exitAfterReadyMs();
        if (exitMs != null) {
          process.stderr.write(`whatsapp-digest: closing session in ${exitMs}ms after ready\n`);
          setTimeout(() => {
            destroy()
              .then(() => process.exit(0))
              .catch((error) => {
                process.stderr.write(`whatsapp-digest: exit-after-ready shutdown failed: ${error.stack ?? error.message}\n`);
                process.exit(1);
              });
          }, exitMs).unref();
        }
      });

      client.on("auth_failure", (message) => {
        state.ready = false;
        state.authenticated = false;
        state.lastError = `auth_failure: ${message}`;
        process.stderr.write(`whatsapp-digest: auth failure: ${message}\n`);
      });

      client.on("disconnected", (reason) => {
        state.ready = false;
        state.initializing = false;
        state.authenticated = false;
        state.lastError = `disconnected: ${reason}`;
        process.stderr.write(`whatsapp-digest: disconnected: ${reason}\n`);
      });

      await client.initialize();
    })().catch((error) => {
      state.initializing = false;
      state.ready = false;
      state.lastError = error instanceof Error ? error.message : String(error);
      initializePromise = null;
      throw error;
    });

    return initializePromise;
  }

  async function waitUntilReady(timeoutMs = readyTimeoutMs) {
    await initialize();
    if (state.ready) return;

    const started = Date.now();
    while (!state.ready && Date.now() - started < timeoutMs) {
      await probeReadiness();
      await new Promise((resolve) => setTimeout(resolve, 500));
    }

    if (!state.ready) {
      throw new Error(
        `WhatsApp session is not ready after ${timeoutMs}ms. ` +
          `If a QR was printed, scan it from WhatsApp > Linked devices. Auth dir: ${authDir}`,
      );
    }
  }

  function getClient() {
    if (!client) throw new Error("WhatsApp client has not initialized");
    return client;
  }

  function status() {
    return { ...state };
  }

  async function destroy() {
    if (client) {
      await client.destroy();
      client = null;
      initializePromise = null;
      state.ready = false;
      state.initializing = false;
      state.authenticated = false;
    }
  }

  return {
    initialize,
    waitUntilReady,
    getClient,
    status,
    destroy,
  };
}
