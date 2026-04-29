# Changelog

## 0.2.0 (2026-04-28)

### Features
- **AI Employees** — collapsible menubar section showing per-agent memory counts with 24h/7d/30d growth
- **Employee Spend** — model-aware cost breakdown per agent (Opus, Sonnet, Haiku rates)
- **Project Spend** — per-project cost across 24h/7d/30d periods in the menubar
- **Launch at login** — auto-registers via SMAppService Login Items (toggleable in System Settings)
- **Quit button** — clean shutdown from the menubar footer bar
- **Dynamic provider tabs** — only shows providers with actual spend data (no empty states)
- **App icon** — gold "EXE" on dark purple rounded square (Exe Foundry Bold)

### Fixes
- Eliminate battery drain from double timer, idle throttling, and QoS issues
- Use official API pricing over LiteLLM third-party markups
- Remove loading overlay — silent background refresh with pre-fetched periods for instant tab switching
- Fix double-counting in menubar JSON pipeline (cache + fresh parse overlap)

### Performance
- 7-day and 30-day queries from 2-5s down to ~1s (parse today only, daily cache for history)

## 0.1.1 (2026-04-25)

### Fixes
- Fix timezone-fragile day aggregator test (near-midnight UTC → stable midday)
- Bump version for npm publish

## 0.1.0 (2026-04-24)

### Fork & Rebrand
- Forked from [codeburn](https://github.com/getagentseal/codeburn) (MIT)
- Full rebrand: package name, CLI binary, config dirs, env vars, macOS app
- See upstream CHANGELOG for pre-fork history
