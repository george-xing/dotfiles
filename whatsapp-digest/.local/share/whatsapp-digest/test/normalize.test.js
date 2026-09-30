import test from "node:test";
import assert from "node:assert/strict";

import {
  filterMessagesAfterCursor,
  messageSourceUrl,
  normalizeGroup,
  normalizeMessage,
} from "../src/normalize.js";

test("normalizeGroup returns stable group identity and counters", () => {
  const group = normalizeGroup({
    id: { _serialized: "120363123456789@g.us" },
    name: "PEF AI Experimentation",
    isGroup: true,
    unreadCount: 999,
    timestamp: 1781575200,
  });

  assert.deepEqual(group, {
    id: "120363123456789@g.us",
    name: "PEF AI Experimentation",
    unreadCount: 999,
    lastMessageAt: "2026-06-16T02:00:00.000Z",
  });
});

test("normalizeMessage preserves group sender, timestamp, body, and media hints", () => {
  const message = normalizeMessage({
    id: { _serialized: "false_120363123456789@g.us_ABCDEF" },
    from: "120363123456789@g.us",
    author: "15555550123@c.us",
    timestamp: 1781575260,
    body: "Anyone have June 25th tickets?",
    type: "chat",
    hasMedia: false,
    fromMe: false,
  });

  assert.deepEqual(message, {
    id: "false_120363123456789@g.us_ABCDEF",
    chatId: "120363123456789@g.us",
    senderId: "15555550123@c.us",
    sentAt: "2026-06-16T02:01:00.000Z",
    text: "Anyone have June 25th tickets?",
    type: "chat",
    hasMedia: false,
    fromMe: false,
    hasQuotedMessage: false,
    sourceUrl: "https://web.whatsapp.com/#chat=120363123456789%40g.us&message=false_120363123456789%40g.us_ABCDEF",
  });
});

test("messageSourceUrl points at WhatsApp Web with encoded chat and message ids", () => {
  assert.equal(
    messageSourceUrl({ chatId: "120363123456789@g.us", id: "false_120363123456789@g.us_ABCDEF" }),
    "https://web.whatsapp.com/#chat=120363123456789%40g.us&message=false_120363123456789%40g.us_ABCDEF",
  );
});

test("filterMessagesAfterCursor keeps only newer messages in chronological order", () => {
  const messages = [
    { id: { _serialized: "m3" }, timestamp: 30, body: "third" },
    { id: { _serialized: "m1" }, timestamp: 10, body: "first" },
    { id: { _serialized: "m2" }, timestamp: 20, body: "second" },
  ];

  const result = filterMessagesAfterCursor(messages, 15).map((message) => message.id._serialized);

  assert.deepEqual(result, ["m2", "m3"]);
});
