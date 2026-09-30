function serializedId(value) {
  if (typeof value === "string") return value;
  if (value && typeof value._serialized === "string") return value._serialized;
  return null;
}

function isoFromWhatsAppTimestamp(timestamp) {
  if (typeof timestamp !== "number" || !Number.isFinite(timestamp) || timestamp <= 0) {
    return null;
  }
  return new Date(timestamp * 1000).toISOString();
}

function messageChatId(message) {
  if (typeof message?.from === "string" && message.from.endsWith("@g.us")) return message.from;
  if (typeof message?.to === "string" && message.to.endsWith("@g.us")) return message.to;
  const remote = message?.id?.remote;
  if (typeof remote === "string") return remote;
  if (remote && typeof remote._serialized === "string") return remote._serialized;
  return null;
}

export function messageSourceUrl({ chatId, id }) {
  if (!chatId || !id) return "https://web.whatsapp.com/";
  const params = new URLSearchParams({ chat: chatId, message: id });
  return `https://web.whatsapp.com/#${params.toString()}`;
}

export function normalizeGroup(chat) {
  return {
    id: serializedId(chat?.id),
    name: typeof chat?.name === "string" ? chat.name : "",
    unreadCount: Number.isFinite(chat?.unreadCount) ? chat.unreadCount : 0,
    lastMessageAt: isoFromWhatsAppTimestamp(chat?.timestamp),
  };
}

export function normalizeMessage(message) {
  const id = serializedId(message?.id);
  const chatId = messageChatId(message);
  return {
    id,
    chatId,
    senderId: typeof message?.author === "string" ? message.author : typeof message?.from === "string" ? message.from : null,
    sentAt: isoFromWhatsAppTimestamp(message?.timestamp),
    text: typeof message?.body === "string" ? message.body : "",
    type: typeof message?.type === "string" ? message.type : "unknown",
    hasMedia: Boolean(message?.hasMedia),
    fromMe: Boolean(message?.fromMe),
    hasQuotedMessage: Boolean(message?.hasQuotedMsg),
    sourceUrl: messageSourceUrl({ chatId, id }),
  };
}

export function filterMessagesAfterCursor(messages, afterTimestamp) {
  const cursor = Number.isFinite(afterTimestamp) ? afterTimestamp : 0;
  return [...messages]
    .filter((message) => Number.isFinite(message?.timestamp) && message.timestamp > cursor)
    .sort((a, b) => a.timestamp - b.timestamp);
}
