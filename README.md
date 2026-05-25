# CC Island

> **Status — in active development.** CC Island is a personal-scale project that's still being shaped. Expect breaking layout changes, occasional bugs, and feature churn between releases. Use it, file issues, but don't depend on it as a stable measurement of your Anthropic billing.

A Dynamic-Island-style monitor for [Claude Code](https://claude.com/claude-code), pinned to the MacBook Pro notch.

Hidden when idle. Drops down a status line while Claude is running. Hover to expand the stats card.

Requires macOS 13+. **No pre-built binary** — build from source with the scripts in [Build](#build) below. The DMG output lands at the project root.

## What's new in 1.3.0

- **Refined motion** — pulsing dots while WORKING, breathing checkmark on FINISH, auto-dismiss back to the reset clock in notch mode.
- **Per-model palette** — Opus (electric purple), Sonnet (modern blue), Haiku (energetic mint).
- **Modern editorial layout** — dual hero numbers in the session row, hero TODAY summary, gauge-style progress that warms toward amber as you approach your limit.
- **Cleaner idle** — static gray dots and "Idle" labels are gone; the pill only surfaces what's actively meaningful.
- Removed the glass/tint appearance modes and the burn-rate panel — they didn't earn their space.

## 1.2.0

- **Free mode** — detach the pill from the notch and float it anywhere on screen via Settings → Placement.
- **Per-model session split** — Opus / Sonnet / Haiku breakdown of the current 5h block.
- **Burn rate panel** *(removed in 1.3.0)*.
- Performance improvements and bug fixes.

## 1.1.0

- Keychain-backed authentication so the pill can call Anthropic's plan-usage endpoint and surface the same percentage Claude Code's `/usage` reports.

## 1.0.0

- Initial demo — notch-pinned pill, local-only token estimate from `~/.claude/projects/**/*.jsonl`.

## First launch — please choose "Always Allow"

The first time you open CC Island, macOS will show a **Keychain access prompt** asking permission for "CC Island" to read the `Claude Code-credentials` item.

> **Click "Always Allow".**
> If you click "Allow" once, macOS will re-prompt every launch — annoying. "Always Allow" is the same trust level you already gave Claude Code itself.
> If you click "Deny", CC Island still runs but the hero percentage falls back to a local token estimate instead of the exact figure Anthropic reports.

CC Island uses your existing Claude Code login to call Anthropic's plan-usage endpoint — the same data Claude Code's `/usage` command and claude.ai's "Plan usage" panel display. **Your token never leaves your machine except to `api.anthropic.com`.** No telemetry, no other network calls.

## Build

```sh
swift run -c release          # run from source
./scripts/build-dmg.sh        # rebuild the .dmg
```
