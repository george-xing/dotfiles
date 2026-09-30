import test from "node:test";
import assert from "node:assert/strict";

import { createWhatsAppTools } from "../src/tools.js";

function fakeClient(chats) {
  return {
    async getChats() {
      return chats;
    },
    async getChatById(id) {
      const chat = chats.find((candidate) => candidate.id._serialized === id);
      if (!chat) throw new Error("Chat not found");
      return chat;
    },
  };
}

test("listGroups returns only WhatsApp groups matching the optional query", async () => {
  const tools = createWhatsAppTools({
    getClient: () =>
      fakeClient([
        { id: { _serialized: "g1@g.us" }, name: "PEF NYC", isGroup: true, unreadCount: 3, timestamp: 1781575200 },
        { id: { _serialized: "p1@c.us" }, name: "Alice", isGroup: false, unreadCount: 0, timestamp: 1781575200 },
        { id: { _serialized: "g2@g.us" }, name: "PEF AI Experimentation", isGroup: true, unreadCount: 9, timestamp: 1781575300 },
      ]),
    waitUntilReady: async () => {},
  });

  const groups = await tools.listGroups({ query: "ai" });

  assert.deepEqual(groups, [
    {
      id: "g2@g.us",
      name: "PEF AI Experimentation",
      unreadCount: 9,
      lastMessageAt: "2026-06-16T02:01:40.000Z",
    },
  ]);
});

test("readGroupMessages fetches recent messages and applies the cursor", async () => {
  const chat = {
    id: { _serialized: "g1@g.us" },
    name: "PEF NYC",
    isGroup: true,
    async fetchMessages({ limit }) {
      assert.equal(limit, 50);
      return [
        { id: { _serialized: "m2" }, from: "g1@g.us", author: "b@c.us", timestamp: 20, body: "new", type: "chat" },
        { id: { _serialized: "m1" }, from: "g1@g.us", author: "a@c.us", timestamp: 10, body: "old", type: "chat" },
      ];
    },
  };
  const tools = createWhatsAppTools({
    getClient: () => fakeClient([chat]),
    waitUntilReady: async () => {},
  });

  const result = await tools.readGroupMessages({ groupId: "g1@g.us", limit: 50, afterTimestamp: 15 });

  assert.deepEqual(result, {
    group: {
      id: "g1@g.us",
      name: "PEF NYC",
      unreadCount: 0,
      lastMessageAt: null,
    },
    messages: [
      {
        id: "m2",
        chatId: "g1@g.us",
        senderId: "b@c.us",
        sentAt: "1970-01-01T00:00:20.000Z",
        text: "new",
        type: "chat",
        hasMedia: false,
        fromMe: false,
        hasQuotedMessage: false,
        sourceUrl: "https://web.whatsapp.com/#chat=g1%40g.us&message=m2",
        threadRootId: "m2",
        threadMessages: [
          {
            id: "m2",
            chatId: "g1@g.us",
            senderId: "b@c.us",
            sentAt: "1970-01-01T00:00:20.000Z",
            text: "new",
            type: "chat",
            hasMedia: false,
            fromMe: false,
            hasQuotedMessage: false,
            sourceUrl: "https://web.whatsapp.com/#chat=g1%40g.us&message=m2",
          },
        ],
        replyCount: 0,
      },
    ],
  });
});

test("readGroupMessages expands quoted replies into thread context", async () => {
  const root = {
    id: { _serialized: "root" },
    from: "g1@g.us",
    author: "a@c.us",
    timestamp: 20,
    body: "Anyone know a good immigration lawyer?",
    type: "chat",
    async getContact() {
      return { pushname: "Alex Chen" };
    },
  };
  const reply = {
    id: { _serialized: "reply" },
    from: "g1@g.us",
    author: "b@c.us",
    timestamp: 30,
    body: "Yes, I used Priya last year and she was excellent for O-1 prep.",
    type: "chat",
    hasQuotedMsg: true,
    async getContact() {
      return { name: "Priya Shah" };
    },
    async getQuotedMessage() {
      return root;
    },
  };
  const chat = {
    id: { _serialized: "g1@g.us" },
    name: "PEF NYC",
    isGroup: true,
    async fetchMessages() {
      return [reply, root];
    },
  };
  const tools = createWhatsAppTools({
    getClient: () => fakeClient([chat]),
    waitUntilReady: async () => {},
  });

  const result = await tools.readGroupMessages({ groupId: "g1@g.us", afterTimestamp: 15 });
  const expandedReply = result.messages.find((message) => message.id === "reply");

  assert.equal(expandedReply.quotedMessageId, "root");
  assert.equal(expandedReply.senderName, "Priya Shah");
  assert.equal(expandedReply.threadRootId, "root");
  assert.equal(expandedReply.replyCount, 1);
  assert.deepEqual(
    expandedReply.threadMessages.map((message) => [message.id, message.senderName]),
    [
      ["root", "Alex Chen"],
      ["reply", "Priya Shah"],
    ],
  );
  assert.match(expandedReply.sourceUrl, /chat=g1%40g\.us&message=reply/);
});

test("readGroupMessages rejects non-group chats", async () => {
  const tools = createWhatsAppTools({
    getClient: () => fakeClient([{ id: { _serialized: "p1@c.us" }, name: "Alice", isGroup: false }]),
    waitUntilReady: async () => {},
  });

  await assert.rejects(
    () => tools.readGroupMessages({ groupId: "p1@c.us" }),
    /not a group chat/,
  );
});
