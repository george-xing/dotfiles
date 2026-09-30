# Shared Operational Patterns

Stable reference points for both `twitter-digest` and `twitter-bookmarks`. The digest skill keeps the full inline workflow; sibling skills cite these sections instead of fragile step numbers.

## CDP Attach And Verify

Use `/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh` to attach to the launchctl-managed bot Chrome at `http://127.0.0.1:9222`; never spawn a fresh browser or reuse the default Browser Use session. After navigation, probe title, `document.visibilityState`, viewport dimensions, the expected primary content container, and login-wall selectors.

Expected state:

- `vis === "visible"`, or the skill's strict authenticated background-content proof succeeds
- `innerWidth > 0` and `innerHeight > 0`
- page-specific primary container is present
- login wall is absent

Failure handling:

- `vis !== "visible"` or zero-sized viewport: first attempt `Page.bringToFront`, then re-probe. If still hidden, write `kind: "visibility"` and exit non-zero unless the page-specific skill defines and satisfies a stricter degraded-visibility proof using the expected route/input, primary container, non-zero viewport, authentication state, and a read-only content extraction probe. Do not use `Page.setWebLifecycleState("active")`.
- Login wall, missing authenticated profile navigation, or wrong route: write `kind: "auth"` and exit. The operator signs in manually via the bot Chrome window.
- Primary container missing with visible page and no login wall: write `kind: "dom"` and exit. The operator updates selectors.

## Stall Handling

When scrolling stalls after scroll and `scrollIntoView` attempts, capture a screenshot under the skill's `state/stalls/` directory and keep the last 10. If screenshots repeatedly time out, use `document.body.innerText.slice(0, 4000)` as a degraded text snapshot and note that in the log.

First apply a semantic fast path: if a visible `[role="dialog"]` exists and the
Escape cap remains, press native Escape, wait 3 seconds, scroll to the top, and
resume with a fresh stall counter. Do this without attaching a screenshot to a
model turn. If no visible dialog exists or Escape fails to clear it, continue
to screenshot classification. Keep the repetitive scroll/extract/recovery loop
inside one terminal execution rather than one model turn per scroll.

Visual classification:

| What you see | Action |
|---|---|
| Empty timeline, repeated items, "you're all caught up", "see new posts" pill, or no obstruction | Feed is genuinely exhausted. Ship with what accumulated. |
| Modal, dialog, banner, snooze prompt, promo, birthday card, year-in-review, or other interstitial obstructing content | Press native Escape if cap remains, wait 3s, `scrollTo(0, 0)`, wait 1s, resume. If Esc cap is exhausted and the same state recurs, ship rather than clicking. |
| Frozen-but-clean content with no obstruction and no movement/new items after multiple attempts | `scrollTo(0, 0)` if cap remains, wait 5s, retry. If still frozen after exhausting the cap, ship. |
| Login wall, sign-up wall, OAuth flow, or "Log in to X" copy | Hard-fail `kind: "auth"` with screenshot path. |
| Fundamentally different page chrome, missing primary column, error page, or site-unreachable page | Hard-fail `kind: "dom"` with screenshot path. |
| Black render, blank page, or mostly empty pixels | Hard-fail `kind: "visibility"` with screenshot path. |
| Genuinely uncertain | Try one cheap recovery: Escape if cap remains, otherwise `scrollTo(0, 0)` if cap remains. If still unclassified, hard-fail `kind: "stall"` with screenshot path. |

## Telegram Delivery

Compose HTML and plain-text fallback files, then send via `/Users/pattybot/dotfiles/twitter/bin/lib/telegram-send.sh`.

The helper's load-bearing invariants:

- File payload only: use `--data-urlencode "text@<file>"`, never interpolate the full message from a shell variable into curl.
- Retry only on parseable Telegram `ok: false`; never retry on curl non-zero exit, local Python parse errors, or empty response.
- One retry using the plain-text fallback with parse mode disabled.

Exit handling:

- `0`: sent successfully. Proceed to state finalization.
- `1`: Telegram returned `ok: false` even after fallback. Write `kind: "telegram"` and stop.
- `2`: curl/network/local-parse failure. Write `kind: "telegram"` with a network/local-parse message and stop.

## State Finalize

On success, append summarized URLs to the dedup file before advancing `last-success.json`. If URL persistence fails after Telegram succeeded, write `kind: "dedup"`, leave `pending.json` in place for forensics, and do not advance `last-success.json`.

Only after dedup succeeds should the skill atomically move `pending.json` into `last-success.json` and remove `pending.json`.
