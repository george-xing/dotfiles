# Twitter Digest Audit/Selection Fix Goal

## Success Criteria

- Every non-hard-filtered candidate has at least one meaningful `candidateLabels` entry; empty labels are allowed only with `rejectionReason:"low_substance"` or `rejectionReason:"off_topic"`.
- Scores are calibrated across all candidates before final selection; rejected candidates should not collapse into one default score bucket like `10`.
- Rejection reasons are specific. Avoid blanket `lower_score_than_cluster` except when the candidate clearly belongs to a selected cluster and lost to stronger items.
- Audit distinguishes draft selection from final delivery with separate fields such as `selectedForDraft`, `shipped`, and `cutReason`.
- Only `shipped:true` tweet URLs are appended to `digested-urls.json`.
- Add a rescue pass before composing that reviews rejected candidates for personal utility, AI tooling/coding-agent relevance, high-signal accounts, substantive science follow-ups, and better-than-weakest-selected quality.
- Add a small dynamic `Worth a skim` / utility section when strong posts do not fit dominant clusters.
- Posts like the prior missed examples would be labeled and either shipped or rejected with a defensible reason: Lenny/Dan Shipper future-of-work, Peter Steinberger skill-token-efficiency, Gokul/Sundar AI strategy, Ian Tracey OpenAI/Codex mindshare, Nico Google code-review standards, Amex ChatGPT credit, and Lilly LDL follow-up.
- Audit-level QA warns in the run log if many rejected candidates have empty labels, scores look binary, high-personal-relevance items are cut, or selected/delivered state diverges.
- Next successful run produces an audit where `shipped:true` count matches the actual Telegram digest items, and any useful rejected candidates are easy to understand from labels, scores, and reasons.
