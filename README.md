# CC Island

A Dynamic-Island-style monitor for [Claude Code](https://claude.com/claude-code), pinned to the MacBook Pro notch.

Hidden when idle. Drops down a status line while Claude is running. Hover to expand the stats card.

[**Download CC Island 1.0.0**](./CC%20Island-1.0.0.dmg) — macOS 13+

## Dropdown

`WORKING · 1h 23m` · `THINKING · 1h 23m` · `FINISH` · `14.3k · resets 8:23 AM` (between turns).

## Lights

- **Left** — model: 🟣 Opus · 🔵 Sonnet · ⚪️ Haiku. Halo = 1M context. Blink = thinking.
- **Right** — status: 🟢 working · 🟠 waiting on you · ⚫️ idle.

## Build

```sh
swift run -c release          # run from source
./scripts/build-dmg.sh        # rebuild the .dmg
```

Data: `~/.claude/projects/**/*.jsonl`. 5h window matches Claude Code's billing. Plan-percentage isn't available locally.

— [github.com/uzerone](https://github.com/uzerone)
