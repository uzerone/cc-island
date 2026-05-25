# CC Island

A Dynamic-Island-style monitor for [Claude Code](https://claude.com/claude-code), pinned to the MacBook Pro notch.

Hidden when idle. Drops down a status line while Claude is running. Hover to expand the stats card.

[**Download CC Island 1.2.0**](./CC%20Island-1.2.0.dmg) — macOS 13+

## What's new in 1.2.0

- **Free mode** — detach the pill from the notch and float it anywhere on screen via Settings → Placement.
- **Burn rate** — expanded card now shows tokens/min and cost/hr for the current session block.
- **Per-model split** — session bar breaks down usage by Opus / Sonnet / Haiku with cost per model.
- Performance improvements and bug fixes.

## Lights

- **Left** — model: 🟣 Opus · 🔵 Sonnet · ⚪️ Haiku. Halo = 1M context. Blink = thinking.
- **Right** — status: 🟠 working · 🟢 waiting on you (finish) · ⚫️ idle.

## First launch

The first time you open CC Island, macOS will show a **Keychain access prompt** asking permission for "CC Island" to read the `Claude Code-credentials` item. Click **Always Allow** (or Allow). This is required — CC Island uses your existing Claude Code login to call Anthropic's plan-usage endpoint and show the same percentage you see in claude.ai. Without it the pill still works, but the hero number falls back to a local token estimate.

CC Island never sends your token anywhere except `api.anthropic.com`. No other network calls.

## Build

```sh
swift run -c release          # run from source
./scripts/build-dmg.sh        # rebuild the .dmg
```)
