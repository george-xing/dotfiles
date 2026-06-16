# Digest selection guide

The digest should choose useful posts first, then decide how to group them. The labels below are interest anchors, not a fixed taxonomy. Tune freely; edits flow into the next digest with no SKILL.md changes.

## Interest anchors

### 🤖 AI
LLM releases, model benchmarks, lab announcements (Anthropic / OpenAI / Google / Meta / xAI / DeepSeek / Mistral), agent frameworks, AI-product launches, AI-policy news. Skip generic "AI hype" tweets unless they contain a concrete fact.

### 💼 Startups & VC
Funding rounds, founder threads with substantive content, YC batch news, acquisition rumors, notable hiring/firing, post-mortems, market maps, pricing, GTM, distribution, fundraising mechanics. Skip pure motivational content.

### 🗽 NYC
Anything substantively about New York: openings, closings, transit, politics, food scene, real estate, neighborhood happenings, weather events. Lower East Side and Manhattan generally are higher signal.

### ✨ Random Interesting
High-signal content outside the anchors: science, health, policy, weird internet artifacts, well-written threads, contrarian takes, beautiful media, useful tools, culture, history, markets, infrastructure, personal writing.

## Scoring before grouping

Score every substantive candidate before assigning a section. Use 0-5 integers:

- `importance`: consequential news, useful decision context, or something likely to matter later.
- `novelty`: not obvious from headlines or ambient Twitter chatter.
- `personal_relevance`: matches the operator's interests, especially AI, startups, NYC, and unusually good internet finds.
- `substance`: contains enough concrete detail to summarize without clickbait.
- `delight`: surprising, elegant, funny, beautiful, or otherwise worth seeing even if not important.

Prefer posts with high total score, but let a single strong dimension through when it is clearly valuable: very important, very personally relevant, or genuinely delightful. Do not let the candidate pool collapse into one default score such as 8 or 10; use the whole range so the audit explains relative quality.

Every non-hard-filtered candidate needs at least one rough label unless it is truly `low_substance` or `off_topic`. Labels are not final sections; they are evidence that the post was understood before selection. Avoid generic-only labels like `random`, `misc`, or `other`; use concrete labels such as `good_internet`, `culture`, `markets`, `engineering_practice`, `health`, `founder_ops`, or `policy` instead.

Do not use generic score reasons such as `auto-labeled; not selected`. For rejected candidates, one terse clause is enough, but it must say why: `thin event promo`, `sports/off-topic`, `duplicate of selected Codex item`, `market signal but weaker than selected OpenAI IPO odds`, `useful but cut for Telegram budget`, etc.

## Rescue pass

After the first selection pass, re-check rejected candidates for these rescue signals:

- **Personal utility**: practical workflows, tools, agent/coding tips, model-use patterns, pricing/credit details, or references the operator may want later.
- **AI tooling / coding agents**: Codex, Claude Code, browser-use, evals, code review, skill-writing, prompt/runtime patterns.
- **High-signal accounts**: posts from people the operator repeatedly cares about should get a second look even when the first summary seems terse.
- **Science and health follow-ups**: credible updates on therapies, longevity, medicine, or notable research can make the digest even when they do not fit AI/startups/NYC.
- **Better than weakest selected**: any rejected candidate that is more useful than the weakest selected item should replace it or appear in a small utility lane.

If a rescued item is useful but not central enough for a main cluster, use `Worth a skim` / `Useful odds & ends` rather than forcing it into `Random Interesting`.

## Dynamic sections

Create sections from the selected posts. Use 2-5 sections per digest, named after the actual clusters in the run. The old anchors can appear when they fit, but do not force them.

Good dynamic section names:

- `🤖 AI Models & Labs`
- `🧰 AI Tools & Workflows`
- `💼 Startup Markets`
- `💸 Fundraising & VC`
- `🗽 NYC`
- `🧬 Science & Health`
- `⚖️ Policy & Immigration`
- `🧠 Sharp Takes`
- `🔖 Worth a skim`
- `✨ Good Internet`

Rules:

- A selected post can have multiple candidate labels in the audit, but appears in one final section.
- No section must exist. Omit empty anchors entirely.
- Keep most sections to 3-5 items. It is okay for a dominant cluster to have 6 if the items are genuinely strong and Telegram space allows.
- Preserve a small `✨ Good Internet` / wildcard lane when there are high-scoring oddballs that do not belong in the main clusters.

## Triage rules

- **Drop it if it's not interesting to a smart, curious reader.** Engagement-bait, sub-tweet drama, and "just shipped" with no detail are all out.
- **Always drop promoted posts.** If the tweet's container text contains "Promoted", "Ad", or X's sponsored-content badge, skip it; never include ads in the digest. This check happens before scoring.
- **Always drop marketing / influencer-shill content.** Signs to watch for:
  - Affiliate/discount codes ("use code X for 20% off", "link in bio").
  - Sponsorship disclosures ("#ad", "#sponsored", "partnered with", "in collaboration with", "gifted by").
  - Product testimonial threads that read like a commercial ("this [product] changed my life, thread 🧵" followed by screenshots/feature rundown).
  - Pseudo-milestone posts that pivot to a product pitch ("I hit $10k MRR - here's the stack [product names]").
  - Hype-adjacent "you NEED this" framing with a single brand or token as the answer.
  - Celebrity/creator-style ambassador content with no informational substance.
  Apply judgement: a founder genuinely discussing their product's engineering choices is legitimate; a thread that's really just an ad dressed up as a story is not.
- **Quote the tweet's substance briefly** (one line), don't just link. The reader is checking this on their phone over coffee.
- **When dropping a plausible candidate, record why in the candidate audit.** Prefer specific reason codes over generic ones. Use `lower_score_than_cluster` only when the candidate shares a meaningful label with a selected post and lost to stronger coverage in that same cluster. Useful reason codes: `low_substance`, `off_topic`, `marketing`, `promoted`, `already_digested`, `stale_time_sensitive`, `duplicate_topic`, `lower_score_than_cluster`, `telegram_budget`, `no_status_url`, `weak_personal_fit`, `weak_utility`, `covered_by_article`, `article_budget`.
- **Long-form X Articles are NOT forced into a tweet section.** They normally go in their own `📰 Long-form articles` section with title + author + 2-3 sentence summary. Article triage also applies the promoted/marketing filter above; skip sponsored articles.

## Calibration examples

Recent misses that should have survived scoring or been defensibly rejected:

- Coding-agent workflow detail from Dan Shipper / Codex / Claude Code discourse: label `AI`, `coding_agents`, high `personal_relevance`, likely `Worth a skim` if not a main AI item.
- Token-efficient skill-writing advice: label `AI`, `workflow`, high utility even if it is not breaking news.
- Sundar Pichai interview summaries with concrete Google/AI strategy detail: label `AI`, `big_tech`, `strategy`; reject only if duplicative of a stronger Google item.
- AI mindshare / GPT-5.5 / Codex vibe-shift commentary from credible builders: label `AI`, `market_signal`; include when it captures a broader shift.
- Google code-review standards for AI agents: label `AI`, `coding_agents`, `engineering_practice`; high operator utility.
- Concrete ChatGPT business credit / pricing details: label `AI`, `pricing`, `personal_utility`; include or reject as `weak_utility`, not `lower_score_than_cluster`.
- Credible LDL gene-therapy follow-up: label `science`, `health`; include in Science/Health or reject as `telegram_budget` only if weaker than selected science items.
