const SECTION_RULES = [
  {
    name: "Needs attention",
    emoji: "🔥",
    labels: ["ask", "tickets", "event"],
    pattern: /\b(anyone|can someone|looking for|need|does anyone|ticket|tix|available|recommendation|recommend)\b/i,
  },
  {
    name: "Jobs and opportunities",
    emoji: "💼",
    labels: ["job", "hiring", "opportunity"],
    pattern: /\b(job|hiring|hire|candidate|referral|role|opportunity|resume|interview)\b/i,
  },
  {
    name: "AI and tools",
    emoji: "🤖",
    labels: ["ai", "tools"],
    pattern: /\b(ai|agent|model|llm|prompt|tool|claude|openai|cursor|coding)\b/i,
  },
  {
    name: "Finance and markets",
    emoji: "📈",
    labels: ["finance", "markets"],
    pattern: /\b(market|fund|stock|fed|rates|finance|invest|valuation|portfolio|capital)\b/i,
  },
  {
    name: "Useful local intel",
    emoji: "📍",
    labels: ["local", "recommendation"],
    pattern: /\b(nyc|sf|bay area|restaurant|doctor|coach|apartment|venue|local)\b/i,
  },
];
const MAX_DIGEST_ITEMS = 8;
const MAX_SECTION_ITEMS = 3;

function htmlEscape(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("\"", "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function oneLine(value, max = 220) {
  const collapsed = String(value ?? "").replace(/\s+/g, " ").trim();
  if (collapsed.length <= max) return collapsed;
  return `${collapsed.slice(0, max - 1).trimEnd()}…`;
}

function senderLabel(senderId) {
  if (!senderId) return "Someone";
  return String(senderId).replace(/@c\.us$|@lid$|@g\.us$/g, "");
}

function personLabel(message) {
  if (typeof message?.senderName === "string" && message.senderName.trim()) {
    return message.senderName.trim();
  }
  return senderLabel(message?.senderId);
}

function localTime(iso) {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

function threadSummary(message) {
  const threadMessages = Array.isArray(message.threadMessages) ? message.threadMessages : [];
  const substantiveThread = threadMessages
    .filter((threadMessage) => oneLine(threadMessage.text, 400).length >= 8)
    .slice(0, 4);

  if (substantiveThread.length <= 1) {
    return oneLine(message.text, 260);
  }

  const [first, ...rest] = substantiveThread;
  const lines = [`${personLabel(first)} started the thread: ${oneLine(first.text, 155)}`];
  for (const reply of rest.slice(0, 2)) {
    const time = localTime(reply.sentAt);
    lines.push(`${personLabel(reply)} replied${time ? ` at ${time}` : ""}: ${oneLine(reply.text, 135)}`);
  }
  if (substantiveThread.length > 3) {
    lines.push(`${substantiveThread.length - 3} more replies in the thread.`);
  }
  return lines.join(" ");
}

function scoringText(message) {
  const threadMessages = Array.isArray(message.threadMessages) ? message.threadMessages : [];
  const texts = threadMessages.length > 0
    ? threadMessages.map((threadMessage) => threadMessage.text)
    : [message.text];
  return oneLine(texts.filter(Boolean).join(" "), 900);
}

function scoreMessage(message) {
  const text = scoringText(message);
  if (!text || text.length < 8) {
    return { selected: false, rejectionReason: "low_signal", score: 0, section: null };
  }
  if (message.hasMedia && !text) {
    return { selected: false, rejectionReason: "unsupported_media_only", score: 0, section: null };
  }

  const section = SECTION_RULES.find((rule) => rule.pattern.test(text));
  if (!section) {
    return { selected: false, rejectionReason: "weak_personal_fit", score: 1, section: null };
  }

  const questionBonus = /\?/.test(text) ? 1 : 0;
  const introBonus = /\b(intro|connect|recommendation|recommend|hiring|hire|looking for|tickets?|tix)\b/i.test(text) ? 2 : 0;
  const timelyBonus = /\b(today|tomorrow|tonight|this week|next week|june|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/i.test(text)
    ? 1
    : 0;
  const score = 3 + questionBonus + introBonus + timelyBonus;
  return { selected: true, rejectionReason: null, score, section };
}

function compareCandidates(left, right) {
  if (right.score !== left.score) return right.score - left.score;
  return String(right.sentAt ?? "").localeCompare(String(left.sentAt ?? ""));
}

export function scoreAndSectionMessages(messages) {
  const candidates = messages.map((message) => {
    const decision = scoreMessage(message);
    return {
      ...message,
      summary: threadSummary(message),
      selected: decision.selected,
      rejectionReason: decision.rejectionReason,
      score: decision.score,
      sectionName: decision.section?.name ?? null,
      sectionEmoji: decision.section?.emoji ?? null,
    };
  });

  const selected = candidates.filter((candidate) => candidate.selected).sort(compareCandidates);
  const rejected = candidates.filter((candidate) => !candidate.selected);
  let remainingSlots = MAX_DIGEST_ITEMS;
  const sections = [];
  for (const rule of SECTION_RULES) {
    if (remainingSlots <= 0) break;
    const items = selected
      .filter((candidate) => candidate.sectionName === rule.name)
      .slice(0, Math.min(MAX_SECTION_ITEMS, remainingSlots));
    if (items.length > 0) {
      sections.push({ name: rule.name, emoji: rule.emoji, items });
      remainingSlots -= items.length;
    }
  }

  return { candidates, selected, rejected, sections };
}

export function composeDigest({ dateLabel, sections, groupsScanned, messagesReviewed }) {
  const nonEmpty = sections.filter((section) => section.items.length > 0);
  if (nonEmpty.length === 0) {
    return {
      html: `<b>WhatsApp digest - ${htmlEscape(dateLabel)}</b>\n\nNothing notable in the configured WhatsApp groups.\n\n—\n${groupsScanned} groups scanned · ${messagesReviewed} messages reviewed`,
      text: `WhatsApp digest - ${dateLabel}\n\nNothing notable in the configured WhatsApp groups.\n\n-\n${groupsScanned} groups scanned · ${messagesReviewed} messages reviewed`,
    };
  }

  const htmlLines = [`<b>WhatsApp digest - ${htmlEscape(dateLabel)}</b>`, ""];
  const textLines = [`WhatsApp digest - ${dateLabel}`, ""];
  for (const section of nonEmpty) {
    htmlLines.push(`${section.emoji} <b>${htmlEscape(section.name)}</b>`);
    textLines.push(`${section.emoji} ${section.name}`);
    for (const item of section.items) {
      const sourceLabel = item.replyCount > 0 ? "thread" : "message";
      const sourceHtml = item.sourceUrl
        ? ` <a href="${htmlEscape(item.sourceUrl)}">${sourceLabel}</a>`
        : "";
      const time = localTime(item.sentAt);
      const meta = [time, personLabel(item)].filter(Boolean).join(" · ");
      htmlLines.push(`• <b>${htmlEscape(item.groupName)}</b>${sourceHtml}${meta ? ` (${htmlEscape(meta)})` : ""}: ${htmlEscape(item.summary)}`);
      textLines.push(`• ${item.groupName}${meta ? ` (${meta})` : ""}: ${item.summary}${item.sourceUrl ? ` [${sourceLabel}: ${item.sourceUrl}]` : ""}`);
    }
    htmlLines.push("");
    textLines.push("");
  }
  htmlLines.push("—", `${groupsScanned} groups scanned · ${messagesReviewed} messages reviewed`);
  textLines.push("-", `${groupsScanned} groups scanned · ${messagesReviewed} messages reviewed`);
  return { html: htmlLines.join("\n"), text: textLines.join("\n") };
}
