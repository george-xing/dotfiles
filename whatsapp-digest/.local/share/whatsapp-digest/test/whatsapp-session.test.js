import test from "node:test";
import assert from "node:assert/strict";

import {
  buildPairWithPhoneNumberOptions,
  buildPuppeteerOptions,
  defaultChromePath,
  defaultReadyProbeIntervalMs,
  defaultReadyProbeTimeoutMs,
  defaultReadyTimeoutMs,
  exitAfterReadyMs,
  shouldAutoOpenQr,
} from "../src/whatsapp-session.js";

test("buildPuppeteerOptions defaults to headless chromium with sandbox disabled", () => {
  assert.deepEqual(buildPuppeteerOptions({}, { existsSync: () => false }), {
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
  });
});

test("buildPuppeteerOptions uses installed Google Chrome by default when present", () => {
  assert.deepEqual(buildPuppeteerOptions({}, { existsSync: () => true }), {
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
    executablePath: defaultChromePath,
  });
});

test("buildPuppeteerOptions supports visible auth mode and executable override", () => {
  assert.deepEqual(
    buildPuppeteerOptions({
      WHATSAPP_DIGEST_HEADLESS: "false",
      WHATSAPP_DIGEST_CHROME_PATH: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    }),
    {
      headless: false,
      args: ["--no-sandbox", "--disable-setuid-sandbox"],
      executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    },
  );
});

test("shouldAutoOpenQr follows the WHATSAPP_DIGEST_OPEN_QR flag", () => {
  assert.equal(shouldAutoOpenQr({}), false);
  assert.equal(shouldAutoOpenQr({ WHATSAPP_DIGEST_OPEN_QR: "true" }), true);
  assert.equal(shouldAutoOpenQr({ WHATSAPP_DIGEST_OPEN_QR: "0" }), false);
});

test("buildPairWithPhoneNumberOptions normalizes env phone number digits", () => {
  assert.equal(buildPairWithPhoneNumberOptions({}), undefined);
  assert.deepEqual(
    buildPairWithPhoneNumberOptions({
      WHATSAPP_DIGEST_PHONE_NUMBER: "+1 (212) 555-0100",
      WHATSAPP_DIGEST_PAIR_INTERVAL_MS: "240000",
    }),
    {
      phoneNumber: "12125550100",
      showNotification: true,
      intervalMs: 240000,
    },
  );
});

test("exitAfterReadyMs follows a positive env override", () => {
  assert.equal(exitAfterReadyMs({}), null);
  assert.equal(exitAfterReadyMs({ WHATSAPP_DIGEST_EXIT_AFTER_READY_MS: "15000" }), 15000);
  assert.equal(exitAfterReadyMs({ WHATSAPP_DIGEST_EXIT_AFTER_READY_MS: "0" }), null);
});

test("defaultReadyTimeoutMs allows slow WhatsApp Web restores", () => {
  assert.equal(defaultReadyTimeoutMs, 420000);
});

test("default readiness probe cadence is conservative", () => {
  assert.equal(defaultReadyProbeIntervalMs, 10000);
  assert.equal(defaultReadyProbeTimeoutMs, 15000);
});
