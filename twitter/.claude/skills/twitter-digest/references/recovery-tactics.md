# Recovery Tactics Notes

This reference preserves the reasoning behind the hot-path recovery toolkit in `SKILL.md`. The skill keeps the actionable table inline; this file explains why the boundaries exist.

## Native Escape

`Escape` must be a native key event via CDP `Input.dispatchKeyEvent`, not a synthetic `document.dispatchEvent(new KeyboardEvent(...))`. Use `browser-use keys`, which routes through Playwright's input pipeline and produces `event.isTrusted === true`:

```bash
/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh keys "Escape"
sleep 3
/Users/pattybot/dotfiles/twitter/bin/twitter-browser.sh eval "window.scrollTo(0, 0); 'ok'"
sleep 1
```

Modern X dialogs (Radix/Headless-class components, including the snooze-topics modal) bind `keydown:Escape` on the focused dialog container, not on `document` or `window`. A synthetic `dispatchEvent` on `document` flips `event.isTrusted = false` and never reaches the dialog's listener path. The May 8 morning run failed exactly this way: synthetic Esc fired twice, the snooze-topics modal stayed up, and the feed plateaued at 4 articles. A live test confirmed that `browser-use keys "Escape"` dismisses the same modal.

The 3s post-Esc settle is longer than the close animation alone because modals frequently interrupt X's timeline prefetch query, and the feed needs time to re-issue it. The follow-up `scrollTo(0,0)` puts top-of-feed back in viewport, since X's prefetch is gated on top-of-feed visibility. Without these two extra steps, post-Esc runs commonly observe a sparse 5-cell timeline that never rehydrates within the wall budget.

## Why This Toolkit

- **Esc**: universal human modal-close keystroke; it does not depend on brittle close-button selectors that drift with each X redesign, and it no-ops harmlessly on non-modal pages. It is capped at 3 per run because deterministic repeated Esc-ing is a signature.
- **`scrollTo(0,0)`**: what a human does when a feed feels frozen: scroll back to top to refresh. It is capped at 3 because a deterministic top-of-feed reset every fire is also a signature.
- **`scrollBy` / `scrollIntoView`**: uncapped because they are the digest's primary content-pull mechanism, and a human spends most of a session scrolling.

Stepping outside these moves, such as clicking arbitrary buttons, typing, submitting, reloading, or navigating away, re-engages the bot-detection risks the skill is engineered to avoid. It also changes the digest source from "what the algorithm surfaced" to "whatever could be backfilled," which defeats the digest's purpose.

## Failure Kinds

- `kind: "visibility"`: bot Chrome window not foreground (`vis !== "visible"` after the CDP `Page.bringToFront` self-recovery attempt also failed). Operator brings the window to front manually and re-fires. `Page.setWebLifecycleState("active")` is still off-limits because it changes page lifecycle without changing OS foreground state. `Page.bringToFront` is a legitimate OS activation call and is the first self-recovery attempt.
- `kind: "auth"`: login wall present in the bot Chrome. Operator opens the bot Chrome window and signs into X manually. Do not try to log in programmatically.
- `kind: "dom"`: visibility OK, no login wall, but `primaryColumn` missing. Likely an X UI change. Operator updates selectors.
- `kind: "telegram"`: Telegram delivery failed even after the plain-text retry. Captures the response description.
- `kind: "empty"`: feed truly returned zero tweets after URL dedup. Treated as success: write `last-success.json` with `tweetCount: 0` and send the `Nothing notable` message.
- **Under-target shipping is not a failure.** A run that produces 1-149 unique eligible tweets can still be successful. The 150-tweet scan target shapes how patiently to recover from stalls; report actual scanned count, target, shortfall and stop reason without exceeding recovery or wall-budget caps.
- `kind: "stall"`: scroll loop stalled and the screenshot did not match any recoverable or pre-categorized state. Operator inspects the screenshot at `last-failure.json#screenshot` and may update the classification table before re-firing.
