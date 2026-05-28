# CC Island

> **Status — in active development.** CC Island is a personal-scale project that's still being shaped. Expect breaking layout changes, occasional bugs, and feature churn between releases. Use it, file issues, but don't depend on it as a stable measurement of your Anthropic billing.

A Dynamic-Island-style monitor for [Claude Code](https://claude.com/claude-code), pinned to the MacBook Pro notch.

Hidden when idle. Drops down a status line while Claude is running. Hover to expand the stats card.

Requires macOS 13+. **No pre-built binary** — build from source with the scripts in [Build](#build) below. The DMG output lands at the project root.

## What's new in 1.4.0

- The little dots that tell you Claude is working now look exactly the same whether you're peeking at the pill or have the full card open.
- A small note in Settings now tells you, in plain words, whether CC Island can see your Claude login — so you instantly know if the number you're looking at is the real one or just a guess.
- The "Launch at login" switch is now a friendly green when it's on, just like the switches in your Mac's regular Settings app.

## 1.3.0

- Everything moves more smoothly. Little dots pulse while Claude is thinking, a soft checkmark appears when Claude is waiting for you, and the pill politely tucks itself away once you've seen it.
- New colors for each Claude — purple for Opus, blue for Sonnet, mint green for Haiku.
- Easier-to-read numbers — your spending today is shown big and bold up top, tokens and dollars sit side by side, and the bar turns orange as you get close to your limit.
- The little gray dot that used to sit there doing nothing is gone.
- The frosted-glass look and the speed-of-spending panel were removed — they weren't doing much.

## 1.2.0

- **Free mode** — you can now drag the pill anywhere on your screen, instead of being stuck under the notch.
- You can see which Claude you're using — Opus, Sonnet, or Haiku — and how much each one is costing you.
- A new panel showing how fast you were burning through your budget (later removed in 1.3.0 because it wasn't actually that useful).
- Things feel a bit snappier, and a few small bugs were fixed.

## 1.1.0

- The number on the pill now matches exactly what you see when you type `/usage` inside Claude Code, or look at your "Plan usage" on claude.ai. Before this, it was just a guess.

## 1.0.0

- The very first version — a tiny pill under your Mac's notch that takes a rough guess at how much of Claude you've used today.

## First launch — please click "Always Allow"

The first time you open CC Island, a little window will pop up from your Mac asking if CC Island can look at your Claude login.

**Please click the "Always Allow" button.**

That's it. CC Island can now show you the exact same usage percentage you see inside Claude Code and on claude.ai.

A few things worth knowing:

- **Why two buttons?** "Allow" only works for one launch — so the window will pop up again next time you open CC Island, and the time after that, and so on. "Always Allow" means you only have to do this once.
- **Is it safe?** Yes. CC Island only uses your login to ask Anthropic "how much have I used this month?" — the same question Claude Code asks. Your login never goes anywhere else, and CC Island doesn't send any data to anyone but Anthropic.
- **What if I click "Deny"?** CC Island still works — it just shows a rough guess of your usage based on local files instead of the exact number from Anthropic.

### Want "Always Allow" to stick when you update CC Island?

If you don't do anything special, every new version of CC Island will look like a brand-new app to your Mac, so the "Always Allow" prompt will come back every time you update.

To fix this, open Terminal **once** and run:

```sh
./scripts/setup-signing-identity.sh
```

You only ever need to run this once. After that, click "Always Allow" the next time the prompt shows up, and you'll never see it again — even when you install a newer version of CC Island.

## Build

```sh
swift run -c release          # run from source
./scripts/build-dmg.sh        # rebuild the .dmg
```
