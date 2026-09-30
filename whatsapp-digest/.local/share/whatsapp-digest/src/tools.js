import {
  filterMessagesAfterCursor,
  normalizeGroup,
  normalizeMessage,
} from "./normalize.js";

function clampLimit(limit, fallback = 200) {
  if (!Number.isFinite(limit)) return fallback;
  return Math.max(1, Math.min(500, Math.trunc(limit)));
}

function contactDisplayName(contact) {
  for (const key of ["pushname", "name", "shortName", "verifiedName"]) {
    const value = contact?.[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

async function normalizeWithContact(message) {
  const normalized = normalizeMessage(message);
  if (typeof message?.getContact !== "function") {
    return normalized;
  }

  try {
    const contact = await message.getContact();
    const displayName = contactDisplayName(contact);
    if (displayName) {
      normalized.senderName = displayName;
    }
  } catch (error) {
    normalized.senderNameError = error instanceof Error ? error.message : String(error);
  }

  return normalized;
}

async function normalizeWithQuotedMessage(message) {
  const normalized = await normalizeWithContact(message);
  if (!message?.hasQuotedMsg || typeof message.getQuotedMessage !== "function") {
    return normalized;
  }

  try {
    const quoted = await message.getQuotedMessage();
    if (quoted) {
      normalized.quotedMessage = await normalizeWithContact(quoted);
      normalized.quotedMessageId = normalized.quotedMessage.id;
    }
  } catch (error) {
    normalized.quotedMessageError = error instanceof Error ? error.message : String(error);
  }

  return normalized;
}

function compareBySentAt(left, right) {
  return String(left.sentAt ?? "").localeCompare(String(right.sentAt ?? ""));
}

function attachThreadContext(messages) {
  const byId = new Map(messages.filter((message) => message.id).map((message) => [message.id, message]));

  function rootIdFor(message) {
    let current = message;
    const seen = new Set();
    while (current?.quotedMessageId && !seen.has(current.quotedMessageId)) {
      seen.add(current.quotedMessageId);
      const parent = byId.get(current.quotedMessageId);
      if (!parent) return current.quotedMessageId;
      current = parent;
    }
    return current?.id ?? message.id;
  }

  const threads = new Map();
  for (const message of messages) {
    const rootId = rootIdFor(message);
    if (!threads.has(rootId)) threads.set(rootId, []);
    threads.get(rootId).push(message);
    if (message.quotedMessage && !byId.has(message.quotedMessage.id)) {
      threads.get(rootId).push(message.quotedMessage);
    }
  }

  return messages.map((message) => {
    const rootId = rootIdFor(message);
    const seen = new Set();
    const threadMessages = (threads.get(rootId) ?? [])
      .filter((threadMessage) => {
        const key = threadMessage.id ?? `${threadMessage.senderId}-${threadMessage.sentAt}-${threadMessage.text}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      })
      .sort(compareBySentAt);
    return {
      ...message,
      threadRootId: rootId,
      threadMessages,
      replyCount: Math.max(0, threadMessages.length - 1),
    };
  });
}

export function createWhatsAppTools({ getClient, waitUntilReady }) {
  async function readyClient() {
    await waitUntilReady();
    return getClient();
  }

  return {
    async listGroups({ query = "", limit = 100 } = {}) {
      const client = await readyClient();
      const needle = query.trim().toLowerCase();
      const chats = await client.getChats();
      return chats
        .filter((chat) => chat?.isGroup)
        .filter((chat) => !needle || String(chat?.name ?? "").toLowerCase().includes(needle))
        .slice(0, clampLimit(limit, 100))
        .map(normalizeGroup);
    },

    async readGroupMessages({ groupId, limit = 200, afterTimestamp = 0 } = {}) {
      if (!groupId || typeof groupId !== "string") {
        throw new Error("groupId is required");
      }
      const client = await readyClient();
      const chat = await client.getChatById(groupId);
      if (!chat?.isGroup) {
        throw new Error(`${groupId} is not a group chat`);
      }

      const messages = await chat.fetchMessages({ limit: clampLimit(limit) });
      const filteredMessages = filterMessagesAfterCursor(messages, afterTimestamp);
      const normalizedMessages = [];
      for (const message of filteredMessages) {
        normalizedMessages.push(await normalizeWithQuotedMessage(message));
      }
      return {
        group: normalizeGroup(chat),
        messages: attachThreadContext(normalizedMessages),
      };
    },
  };
}
