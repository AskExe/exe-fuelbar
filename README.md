<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/AskExe/exe-fuelbar@main/assets/owl-icon.png" alt="Exe Fuelbar" width="120" />
</p>

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/AskExe/exe-fuelbar@main/assets/owl-header.png" alt="EXE FUELBAR" width="480" />
</p>

<p align="center"><strong>The fuel gauge for your AI coding day.</strong></p>

<p align="center">
  <a href="https://www.npmjs.com/package/exe-fuelbar"><img src="https://img.shields.io/npm/v/exe-fuelbar.svg" alt="npm version" /></a>
  <a href="https://www.npmjs.com/package/exe-fuelbar"><img src="https://img.shields.io/npm/dt/exe-fuelbar.svg" alt="total downloads" /></a>
  <a href="https://github.com/AskExe/exe-fuelbar/blob/main/LICENSE"><img src="https://img.shields.io/npm/l/exe-fuelbar.svg" alt="license" /></a>
  <a href="https://github.com/AskExe/exe-fuelbar"><img src="https://img.shields.io/badge/node-%3E%3D20-brightgreen.svg" alt="node version" /></a>
  <a href="https://discord.gg/pJ2DMWvtAx"><img src="https://img.shields.io/badge/discord-join-5865F2?logo=discord&logoColor=white" alt="Discord" /></a>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/AskExe/exe-fuelbar/main/assets/dashboard.jpg" alt="Exe Fuelbar TUI dashboard" width="620" />
</p>

You're spending real money on AI coding tools every day. Exe Fuelbar shows you exactly where it goes — cost, tokens, models, projects, and whether the AI is getting it right the first time or burning through retry loops. One command, zero cloud, everything local.

```bash
npm install -g exe-fuelbar
```

---

## What you get

**Dashboard** — Interactive TUI with gradient charts, responsive panels, keyboard navigation. Breaks down spend by day, project, model, activity type, tools, MCP servers, and shell commands. Auto-refreshes every 30 seconds.

**One-shot rate** — For every category that involves edits, Fuelbar detects edit/test/fix retry cycles and shows you the percentage of turns where the AI got it right on the first try. Coding at 90% means 9 out of 10 edits landed without retries.

**Optimize** — Scans your sessions and `~/.claude/` config for waste: re-read files, low read:edit ratios, uncapped bash output, unused MCP servers, ghost agents, bloated CLAUDE.md files. Hands back exact, copy-paste fixes. Grades your setup A through F.

**Compare** — Side-by-side model comparison on your own data. One-shot rate, retry rate, cost per edit, cache hit rate, delegation style, fast mode usage — broken down by task category.

**Menubar** — Native macOS app showing today's cost in your menu bar. Period switcher, trend/forecast/pulse insights, activity breakdowns, per-project spend, and AI employee tracking. Launches at login, one command to install.

**Export** — CSV and JSON export for any time period. Pipe `--format json` output to `jq` for scripting.

---

## Supported tools

| Tool | Data source | Notes |
|------|-------------|-------|
| **Claude Code** | `~/.claude/projects/` | Full support |
| **Claude Desktop** | `~/Library/Application Support/Claude/local-agent-mode-sessions/` | Full support |
| **Codex** (OpenAI) | `~/.codex/sessions/` | Full support |
| **Cursor** | SQLite (`state.vscdb`) | Auto mode estimated at Sonnet pricing |
| **cursor-agent** | CLI sessions | Full support |
| **OpenCode** | SQLite (`~/.local/share/opencode/`) | Subtask sessions excluded |
| **Pi** | `~/.pi/agent/sessions/` | Full support |
| **OMP** (Oh My Pi) | `~/.omp/agent/sessions/` | Full support |
| **GitHub Copilot** | `~/.copilot/session-state/` | Output tokens only |

Auto-detected. If multiple tools have data, press `p` in the dashboard to toggle. Provider plugin system makes adding new tools straightforward — see `src/providers/codex.ts` for the pattern.

---

## CLI reference

```bash
# Dashboard
exe-fuelbar                                    # interactive (default: 7 days)
exe-fuelbar today                              # today only
exe-fuelbar month                              # this month

# Reports
exe-fuelbar report -p 30days                   # rolling 30-day window
exe-fuelbar report -p all                      # everything on disk
exe-fuelbar report --from 2026-04-01 --to 2026-04-10
exe-fuelbar report --format json               # structured JSON to stdout
exe-fuelbar status                             # compact one-liner (today + month)

# Filter
exe-fuelbar report --provider claude           # single provider
exe-fuelbar report --project myapp             # project substring match
exe-fuelbar report --exclude tests             # exclude projects

# Tools
exe-fuelbar optimize                           # find waste, get fixes
exe-fuelbar optimize -p week                   # scope to last 7 days
exe-fuelbar compare                            # interactive model picker
exe-fuelbar export                             # CSV (today, 7d, 30d)
exe-fuelbar export -f json                     # JSON export
```

**Dashboard keys:** `1`-`5` switch periods (Today / 7d / 30d / Month / All). `p` toggle providers. `c` compare mode. `o` optimize view. `q` quit.

**Flags work everywhere:** `--provider`, `--project`, `--exclude`, `--from`, `--to`, and `--format json` combine freely across all commands.

---

## Menubar app

<!-- Screenshot: native macOS menubar popover with gold/purple Exe Foundry Bold theme -->
<!-- To update: screencapture -w assets/menubar-v0.2.0.png (click the Fuelbar menubar icon) -->

```bash
exe-fuelbar menubar
```

Downloads, installs to `~/Applications`, and launches. Re-run with `--force` to reinstall. Native Swift + SwiftUI — silent background refresh every 60 seconds, no loading overlay. Pre-fetches all periods on launch so tab switching is instant. Launches at login automatically via macOS Login Items (toggleable in System Settings).

**v0.2.0 additions:**
- **Project Spend** — per-project cost breakdown across 24h / 7d / 30d
- **AI Employees** — collapsible section with Memory counts (+ growth) and Employee Spend (model-aware pricing per agent)
- **Dynamic provider tabs** — only shows providers that have actual spend data
- **Quit button** — clean shutdown from the footer bar
- **App icon** — gold EXE on dark purple (Exe Foundry Bold palette)

**Compact mode** drops decimals in the menubar (e.g. `$110` instead of `$110.20`):

```bash
defaults write ExeFuelbarMenubar ExeFuelbarMenubarCompact -bool true
```

---

## Configuration

### Currency

```bash
exe-fuelbar currency GBP              # any ISO 4217 code (162 currencies)
exe-fuelbar currency --reset           # back to USD
```

Exchange rates from the European Central Bank via [Frankfurter](https://www.frankfurter.app/). Cached 24 hours. Applies everywhere: dashboard, menubar, exports.

### Plans

Track spend against your subscription:

```bash
exe-fuelbar plan set claude-max        # $200/month
exe-fuelbar plan set claude-pro        # $20/month
exe-fuelbar plan set cursor-pro        # $20/month
exe-fuelbar plan set custom --monthly-usd 150 --provider claude
exe-fuelbar plan set none              # disable
```

### Model aliases

If a model shows `$0.00`, your provider's model name doesn't match LiteLLM pricing data. Map it:

```bash
exe-fuelbar model-alias "my-proxy-model" "claude-opus-4-6"
exe-fuelbar model-alias --list
exe-fuelbar model-alias --remove "my-proxy-model"
```

Stored in `~/.config/exe-fuelbar/config.json`. User aliases override built-ins.

---

## Activity tracking

6 categories classified from tool usage patterns and keywords. No LLM calls, fully deterministic.

| Category | What triggers it |
|----------|-----------------|
| Building | Edit, Write tools; "add", "create", "implement"; refactoring keywords |
| Debugging | Error/fix/bug keywords + tools |
| Testing | pytest, vitest, jest in Bash |
| Research | Read, Grep, WebSearch without edits; brainstorming; conversation |
| DevOps | git push/commit/merge; npm build, docker, deploy |
| Planning | EnterPlanMode, TaskCreate, Agent tool spawns |

---

## Reading the signals

| What you see | What it might mean |
|---|---|
| Cache hit < 80% | Unstable system prompt or caching not enabled |
| Lots of `Read` calls per session | Agent re-reading files, missing context |
| Low 1-shot rate (Coding 30%) | Agent struggling, retry loops |
| Opus on small turns | Overpowered model for simple tasks |
| Bash dominated by `git status`, `ls` | Agent exploring instead of executing |
| Conversation category dominant | Agent talking instead of doing |

Starting points, not verdicts. A single experimental session with 60% cache hit is fine. That same number across weeks of work is a config issue.

---

## How it works

Reads session data directly from disk. No wrapper, no proxy, no API keys needed. Pricing from [LiteLLM](https://github.com/BerriAI/litellm) (auto-cached 24h). Handles input, output, cache write, cache read, and web search costs. Deduplicates messages by API message ID (Claude), cumulative token cross-check (Codex), conversation/timestamp (Cursor), session+message ID (OpenCode), or responseId (Pi/OMP).

**Environment variables:**

| Variable | Description |
|----------|-------------|
| `CLAUDE_CONFIG_DIR` | Override Claude data directory (default: `~/.claude`) |
| `CODEX_HOME` | Override Codex data directory (default: `~/.codex`) |

---

## Contributing

Contributions welcome. The provider plugin system is the easiest entry point — each provider is a single file in `src/providers/`. See `src/providers/codex.ts` for the pattern.

```
src/
  cli.ts           Entry point (Commander.js)
  dashboard.tsx    TUI (Ink — React for terminals)
  parser.ts        Session reader, dedup, date filter
  models.ts        LiteLLM pricing engine
  classifier.ts   Activity classifier (6 categories)
  compare-stats.ts Model comparison engine
  menubar-json.ts  Menubar payload builder (agent spend, project spend)
  export.ts        CSV/JSON export
  config.ts        Config management
  currency.ts      Currency conversion
  providers/       One file per supported tool
mac/               Native macOS menubar app (Swift + SwiftUI)
```

---

## Exe OS integration

If [Exe OS](https://github.com/AskExe/exe-os) is installed, Fuelbar auto-detects it and shows a live **AI Employees** section in the menubar with two sub-panels:

- **Memory** — per-agent memory count with 24h / 7d / 30d growth columns
- **Employee Spend** — per-agent cost across 24h / 7d / 30d, using model-aware pricing (Opus, Sonnet, Haiku rates applied per-model from the daemon's token data)

No configuration needed. The section appears when exe-os is present and hides when it's not. The data pipeline: exe-os SessionStart hook maps Claude Code sessions to agents, the daemon computes `getAgentSpend()` with per-model pricing, writes `~/.exe-os/agent-stats.json` every 60 seconds, and Fuelbar reads this file — zero coupling, no auth, no direct database access.

---

## Origin & attribution

Exe Fuelbar is forked from [codeburn](https://github.com/getagentseal/codeburn) by [AgentSeal](https://github.com/getagentseal) (MIT license). We forked rather than contributed upstream because our roadmap diverges significantly:

**What we changed:**
- Rebranded to Exe Fuelbar with the Exe Foundry Bold design system (gold + purple palette, owl icon)
- Consolidated activity categories from 13 → 6 (less overlap, clearer signal)
- Fixed double-counting bugs in the menubar JSON pipeline (cache + fresh parse overlap)
- Performance: 7-day and 30-day queries from 2-5 seconds down to ~1 second (parse today only, use daily cache for history)
- Menubar: removed loading overlay entirely — silent background refresh, pre-fetched periods for instant tab switching
- Added exe-os agent memory and spend integration (auto-detected, model-aware pricing)
- Per-project spend breakdown in the menubar (24h / 7d / 30d)
- Launch at login via SMAppService, quit button, macOS app icon
- Dark mode forced on popover, dynamic provider tabs (no empty states)

**Why we forked:**
- We need full control over the data pipeline to integrate with exe-os (our AI employee operating system)
- Our classification model, provider support, and UI direction serve a different user base (AI-first teams running multi-agent workflows)
- MIT license allows this — we give full credit to AgentSeal for the foundation

Thank you to AgentSeal for building the original. If you just want a clean cost tracker without exe-os integration, [codeburn](https://github.com/getagentseal/codeburn) is excellent.

---

## Star History

<a href="https://www.star-history.com/?repos=AskExe%2Fexe-fuelbar&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=AskExe/exe-fuelbar&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=AskExe/exe-fuelbar&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=AskExe/exe-fuelbar&type=date&legend=top-left" />
 </picture>
</a>

---

## License

MIT

---

Built by [Exe AI](https://askexe.com). Forked from [codeburn](https://github.com/getagentseal/codeburn) by AgentSeal (MIT). Pricing data from [LiteLLM](https://github.com/BerriAI/litellm). Exchange rates from [Frankfurter](https://www.frankfurter.app/).
