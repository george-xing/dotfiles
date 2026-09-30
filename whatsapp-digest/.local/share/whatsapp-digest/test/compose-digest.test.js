import test from "node:test";
import assert from "node:assert/strict";

import { composeDigest, scoreAndSectionMessages } from "../src/compose-digest.js";

test("scoreAndSectionMessages selects useful asks and rejects low-signal chatter", () => {
  const result = scoreAndSectionMessages([
    {
      groupName: "PEF NYC",
      senderId: "a@c.us",
      sentAt: "2026-06-16T02:00:00.000Z",
      text: "Anyone have June 25 tickets?",
      type: "chat",
      hasMedia: false,
    },
    {
      groupName: "PEF NYC",
      senderId: "b@c.us",
      sentAt: "2026-06-16T02:01:00.000Z",
      text: "lol",
      type: "chat",
      hasMedia: false,
    },
  ]);

  assert.equal(result.selected.length, 1);
  assert.equal(result.rejected[0].rejectionReason, "low_signal");
  assert.equal(result.sections[0].name, "Needs attention");
});

test("composeDigest escapes Telegram HTML and omits empty sections", () => {
  const digest = composeDigest({
    dateLabel: "Jun 16",
    groupsScanned: 1,
    messagesReviewed: 1,
    sections: [
      {
        name: "AI & tools",
        emoji: "🤖",
        items: [{ groupName: "PEF AI", summary: "Use A < B & C > D" }],
      },
      { name: "Empty", emoji: "•", items: [] },
    ],
  });

  assert.match(digest.html, /Use A &lt; B &amp; C &gt; D/);
  assert.doesNotMatch(digest.html, /Empty/);
  assert.match(digest.text, /Use A < B & C > D/);
});

test("composeDigest renders source links and expanded thread summaries", () => {
  const scored = scoreAndSectionMessages([
    {
      groupName: "PEF NYC",
      senderId: "b@c.us",
      senderName: "Priya Shah",
      sentAt: "2026-06-16T14:05:00.000Z",
      text: "Yes, I used Priya last year and she was excellent for O-1 prep.",
      type: "chat",
      hasMedia: false,
      sourceUrl: "https://web.whatsapp.com/#chat=g1%40g.us&message=reply",
      replyCount: 1,
      threadMessages: [
        {
          id: "root",
          senderId: "a@c.us",
          senderName: "Alex Chen",
          sentAt: "2026-06-16T14:00:00.000Z",
          text: "Anyone know a good immigration lawyer recommendation?",
        },
        {
          id: "reply",
          senderId: "b@c.us",
          senderName: "Priya Shah",
          sentAt: "2026-06-16T14:05:00.000Z",
          text: "Yes, I used Priya last year and she was excellent for O-1 prep.",
        },
      ],
    },
  ]);

  const digest = composeDigest({
    dateLabel: "Jun 16",
    groupsScanned: 1,
    messagesReviewed: 2,
    sections: scored.sections,
  });

  assert.match(digest.html, /<a href="https:\/\/web\.whatsapp\.com\/#chat=g1%40g\.us&amp;message=reply">thread<\/a>/);
  assert.match(digest.html, /Alex Chen started the thread: Anyone know a good immigration lawyer recommendation\?/);
  assert.match(digest.html, /Priya Shah replied at 10:05 AM: Yes, I used Priya last year/);
  assert.match(digest.html, /10:05 AM · Priya Shah/);
  assert.match(digest.text, /\[thread: https:\/\/web\.whatsapp\.com\/#chat=g1%40g\.us&message=reply\]/);
});

test("scoreAndSectionMessages caps noisy digests to the strongest items", () => {
  const messages = Array.from({ length: 40 }, (_, index) => ({
    groupName: "PEF NYC",
    senderId: `${index}@c.us`,
    sentAt: `2026-06-16T02:${String(index).padStart(2, "0")}:00.000Z`,
    text: `Anyone have a recommendation or intro for item ${index}?`,
    type: "chat",
    hasMedia: false,
  }));

  const result = scoreAndSectionMessages(messages);
  const digestItemCount = result.sections.reduce((sum, section) => sum + section.items.length, 0);

  assert.equal(result.selected.length, 40);
  assert.equal(digestItemCount, 3);
  assert.equal(result.sections[0].items[0].senderId, "39@c.us");
});
