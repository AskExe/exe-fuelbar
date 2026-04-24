# Changelog

## 0.8.9 - 2026-04-22

### Fixed
- **Menubar showed stale prices.** The "all providers" query used `end: now` while per-provider queries used `end: endOfDay`, causing sessions timestamped after the capture moment to be excluded from totals. Now uses `periodInfo.range` consistently across all queries.

### Changed (macOS menubar)
- **Variable-width status item is now the default.** The menubar pill hugs the rendered text in both compact and default modes instead of reserving a fixed 130pt slot.

## 0.8.8 - 2026-04-22

### Fixed (CLI)
- **OOM crash on large session files.** `scanJsonlFile` and `parseSessionFile` loaded entire files into memory via `readViaStream` (which defeated its own streaming by joining all lines back into one string). Switched both to the existing `readSessionLines` async generator that yields one line at a time. Contributed by @maucher (#132).

### Added (macOS menubar)
- **Compact mode.** Opt-in tighter menubar display: no decimals, variable width that hugs the text. Enable with `defaults write CodeBurnMenubar CodeBurnMenubarCompact -bool true`. Default off.

### Fixed (macOS menubar, shipped alongside via mac-v0.8.8)
- **Plan tab never loaded on Claude Code 2.1.x.** Keychain credential lookup filtered on `kSecAttrAccount == "default"`, but Claude Code writes the macOS login username. Removed the hardcoded allowlist; the service name is sufficient to scope the query.
- **Four keychain prompts on debug builds.** Collapsed two-phase keychain enumeration into a single `SecItemCopyMatching` call.
- **App Nap override not sticking.** The `beginActivity` token was immediately overridden by AppKit. Now disables `automaticTerminationSupport` and `suddenTermination` at the process level.

## 0.8.7 - 2026-04-21

### Added
- **MiniMax-M2.7 and MiniMax-M2.7-highspeed pricing.** Added to `FALLBACK_PRICING` plus display names so MiniMax sessions show up with the right cost and readable labels when users route MiniMax through providers like OpenCode. Rates verified against MiniMax's live paygo pricing: base model $0.3/M input, $1.2/M output; highspeed $0.6/M input, $2.4/M output; cache read $0.06/M, cache write $0.375/M on both.
- **OMP provider (Oh My Pi).** Auto-discovers sessions at `~/.omp/agent/sessions/*.jsonl` and tracks them alongside Pi. Shares Pi's JSONL parser via a `providerName` parameter, so OMP rows keep their own `omp:` dedup prefix and never cross-dedupe with Pi on a shared `conversationId` namespace. `codeburn report --provider omp` filters to OMP only; the default combined view includes both. Contributed by @cgrossde (#59).
- **`codeburn model-alias` command.** Maps any provider-emitted model name to a canonical pricing name so cost rows no longer read `$0.00` when a proxy rewrites names. Aliases persist in `~/.config/codeburn/config.json` under `modelAliases`. Usage: `codeburn model-alias <from> <to>` to set, `--list` to view, `--remove <from>` to clear. User aliases resolve before the built-in list. Contributed by @cgrossde (#59).
- **Built-in aliases for Anthropic-compatible proxy format.** `anthropic--claude-4.6-opus`, `anthropic--claude-4.6-sonnet`, `anthropic--claude-4.5-opus`, `anthropic--claude-4.5-sonnet`, and `anthropic--claude-4.5-haiku` now resolve to canonical Claude names and price correctly with no user configuration. `getCanonicalName` also strips `provider/` prefixes before alias resolution so double-wrapped forms like `anthropic/anthropic--claude-4.6-opus` work the same way. Contributed by @cgrossde (#59).

### Fixed (CLI)
- **Prototype pollution in alias resolution.** A model literally named `__proto__` leaked `Object.prototype` through the `??` fallback chain in `resolveAlias`, which then crashed `canonical.startsWith` downstream. The resolver now uses `Object.hasOwn` checks for both user and built-in alias maps. Caught by the existing prototype-pollution test suite during the #59 merge.

### Fixed (macOS menubar, shipped alongside via mac-v0.8.7)
- **Menubar label froze in the background and only refreshed when you clicked the icon.** Three independent causes fixed:
  - `prefetchAll` on launch spawned four concurrent `codeburn` subprocesses that competed with the main refresh loop for disk and parser time. Removed; period tabs now fetch lazily on first click.
  - `NSStatusItem` sometimes deferred the status bar paint for an accessory app, so `attributedTitle` updates hit memory but not the screen until the popover opened. Explicit `needsDisplay` + `display()` after each update forces the paint.
  - **The real root cause:** macOS App Nap / Automatic Termination was suspending the app whenever the icon sat idle in the background, stretching the 15-second refresh Task's sleep indefinitely. Holding a `ProcessInfo.beginActivity` token for the life of the app opts out. Confirmed via `log show`: `_kLSApplicationWouldBeTerminatedByTALKey` now stays at 0.
- Subprocess `QualityOfService` lifted to `.userInitiated` so `codeburn` runs at terminal speed when spawned from the menubar.

### Skipped
- 0.8.6 was never published to npm. The version was briefly planned and then skipped to align CLI and macOS menubar versioning at 0.8.7.

### Notes
- If you are on 0.8.5 and do not use MiniMax, Oh My Pi, or a proxy that rewrites model names to the `anthropic--claude-X.Y-tier` format, CLI behavior is unchanged and you can safely stay on 0.8.5.
- macOS menubar users on `mac-v0.8.6` or earlier should update: the refresh loop only ticks reliably from `mac-v0.8.7` onward. The in-app update pill surfaces within 2 days, or quit and re-run `npx codeburn menubar` to pull immediately.

## 0.8.5 - 2026-04-21

### Fixed
- **Stale Today totals after 0.8.2.** The persistent source cache introduced in 0.8.2 caused Today's cost to under-report and sometimes drop between polls during active Claude Code sessions. The cache keyed entries on `(mtime, size)` fingerprints that diverged from Claude's append-mostly JSONL model, producing empty or partial entries that were served on subsequent polls. Reverted the cache rewrite to the v0.8.1 full-reparse path for Claude sessions. Both the menubar and `codeburn status` now return consistent, monotonically-increasing Today totals.
- **Menubar and terminal status disagreed on Today.** A turn that straddled midnight (user message in one day, response in the next) was bucketed by user timestamp in one code path and by assistant timestamp in another, producing different Today values in the two surfaces. Both paths now count a turn on the day its first assistant call ran.
- **Kept from 0.8.2-0.8.4:** subscription plan tracking, pricing accuracy and CSV injection hardening, cursor-agent provider, menubar prefetch and timezone alignment. Only the cache rewrite and its follow-up patches were reverted.

### Removed
- `--no-cache` flag on `report`, `today`, `month`, `status`, `export`, `optimize`, and `compare`. The flag existed to bypass the persistent source cache which no longer exists. If your scripts pass `--no-cache`, drop it; the parse runs fresh every time now.

### Notes
- 0.8.2, 0.8.3, and 0.8.4 on npm contain the buggy cache. Upgrade with `npm i -g codeburn@latest` or `npm i -g codeburn@0.8.5`.
- This release uses a full reparse on every invocation, matching v0.8.1 behavior. On large corpora (5,000+ session files) expect 3 to 10 seconds per invocation. An incremental refresh design that preserves correctness is planned for a follow-up release.

## 0.8.0 - 2026-04-19

### Added
- **`codeburn compare` command.** Side-by-side model comparison across any two models in your session data. Interactive model picker, period switching, and provider filtering.
- **Compare view in dashboard.** Press `c` in the TUI to enter compare mode. Arrow keys switch periods, `b` to return.
- **Performance metrics.** One-shot rate, retry rate, and self-correction detection per model. Self-corrections are detected by scanning JSONL transcripts for tool error followed by retry patterns.
- **Efficiency metrics.** Cost per call, cost per edit turn, output tokens per call, and cache hit rate.
- **Per-category one-shot rates.** Breaks down one-shot success by task category (Coding, Debugging, Feature Dev, etc.) for each model.
- **Working style comparison.** Delegation rate, planning rate (TaskCreate, TaskUpdate, TodoWrite), average tools per turn, and fast mode usage.
- **TUI auto-refresh enabled by default.** Dashboard now refreshes every 30 seconds out of the box. Pass `--refresh 0` to disable. Closes #107.
- **36 comparison tests.** Full coverage for metric computation, category breakdown, working style, self-correction scanning, and planning tool detection. Total suite: 274 tests.

### Fixed
- **Planning rate showed ~0% in model comparison.** Only counted `EnterPlanMode` (rarely used) instead of all planning tools (TaskCreate, TaskUpdate, TodoWrite, EnterPlanMode, ExitPlanMode). Now detects planning at the turn level across all five tool types.
- **Menubar "All" tab showed stale data.** Three-layer caching (300s in-memory TTL, daily disk cache, 60s parser cache) prevented tab switches from showing fresh numbers. Cache TTL reduced from 300s to 30s, tab switches always fetch fresh data, background refresh interval reduced from 60s to 15s.

## 0.7.4 - 2026-04-19

### Added
- **`codeburn report --from/--to`.** Filter sessions to an exact `YYYY-MM-DD` date range (local time). Either flag alone is valid: `--from` alone runs from the given date through end-of-today, `--to` alone runs from the earliest data through the given date. Inverted ranges or malformed dates exit with a clear error. In the TUI, pressing `1`-`5` still switches to the predefined periods. Credit: @lfl1337 (PR #80).
- **`avgCostPerSession` in reports.** JSON `projects[]` entries gain an `avgCostPerSession` field and `export -f csv` adds an `Avg/Session (USD)` column to `projects.csv`. Column order in `projects.csv` is now `Project, Cost, Avg/Session, Share, API Calls, Sessions` -- scripts parsing by column position should read by header instead. Credit: @lfl1337 (PR #80).
- **Menubar auto-update checker.** Background check every 2 days against GitHub Releases. When a newer menubar build is available, an "Update" pill appears in the popover header. One click downloads, replaces, and relaunches the app automatically.
- **Smart agent tab visibility.** The provider tab strip hides when fewer than two providers have spend, reducing clutter for single-tool users.

### Fixed
- **Stale daily cache caused wrong menubar costs.** The daily cache never recomputed yesterday once written, so a mid-day CLI run would freeze partial cost data permanently. The "All" provider view relied on this cache, showing wildly incorrect numbers while per-provider tabs (which parse fresh) were correct. Yesterday is now evicted and recomputed on every run.
- **UTC date bucketing instead of local timezone.** Timestamps in session files are UTC ISO strings. Several code paths extracted the date via `.slice(0, 10)` (UTC date) while date range filtering used local-time boundaries. Turns between UTC midnight and local midnight were attributed to the wrong day -- the menubar showed lower today cost than the TUI. All date bucketing now uses local time consistently.
- **OpenCode SQLite ESM loader.** `node:sqlite` is now loaded correctly in ESM runtime. Credit: @aaronflorey (PR #104).
- **Menubar trend tooltip per-provider views.** Tooltip now shows the correct cost when a specific provider tab is selected.
- **Menubar (today, all) cache freshness.** The cache entry powering the menubar title and tab labels is now kept fresh independently of the selected period/provider.
- **Agent tab strip restored.** All detected providers are shown again after a regression hid them.
- **Plan pane button cleanup.** Removed the broken "Connect Claude" button that opened a useless terminal session. The Plan pane now shows only a "Retry" button.

## 0.7.3 - 2026-04-18

### Changed
- **Dropped `better-sqlite3` in favor of Node's built-in `node:sqlite`.** Removes the deprecated `prebuild-install` transitive dependency that npm warned about on every install (issue #75, credit @primeminister). End-user install is now 40 packages down from 167 and shows zero deprecation notices. The experimental-SQLite warning Node 22/23 normally prints on module load is silenced for this specific warning; other warnings pass through unchanged.
- **Minimum Node version raised to 22.** Node 20 reached EOL on 2026-04-30; `node:sqlite` lives in 22+. Users on older Node get a clear upgrade message when a SQLite-backed provider (Cursor, OpenCode) is loaded.


## 0.7.2 - 2026-04-17

### Added
- **Native macOS menubar app.** Swift + SwiftUI app under `mac/` replaces the SwiftBar plugin. Agent tabs, Today/7/30/Month/All period switcher, Trend/Forecast/Pulse/Stats/Plan insights, activity and model breakdowns, optimize findings, CSV/JSON export, instant currency switching, live 60s refresh.
- **`codeburn menubar`.** One-command install: downloads the latest `.app` from GitHub Releases, strips Gatekeeper quarantine, drops it into `~/Applications`, and launches it. `--force` reinstalls in place.
- **`status --format menubar-json`.** Structured payload consumed by the native menubar app. Current-period totals, per-activity and per-model breakdowns, provider costs, optimize findings, and 365-day history.
- **Release workflow.** `.github/workflows/release-menubar.yml` builds a universal `.app` bundle and zip on `mac-v*` tag push.

### Changed
- **`codeburn export -f csv`** now writes a folder of one-table-per-file CSVs (`summary`, `daily`, `activity`, `models`, `projects`, `sessions`, `tools`, `shell-commands`) plus a `README.txt` index. Each file opens cleanly as a single table in any spreadsheet.
- **`codeburn export -f json`** upgraded to schema `codeburn.export.v2` with currency metadata.

### Fixed
- **`codeburn status` terminal Today/Month** now buckets by local date instead of UTC, so spend shows correctly during the window between local midnight and UTC midnight.
- **FX rate validation.** Frankfurter responses are checked to be finite and within `[0.0001, 1_000_000]` before they affect displayed costs.

### Removed
- **SwiftBar plugin.** `src/menubar.ts`, `codeburn install-menubar`, `codeburn uninstall-menubar`, and `status --format menubar` are gone. The native Swift app is the single menubar surface.

### Security
- **`codeburn export -o` guard.** Writes a `.codeburn-export` marker into every folder it creates and refuses to reuse non-marked directories or overwrite existing files, so a typo like `-o ~/.ssh/id_ed25519` cannot delete a sensitive file.

## 0.7.1 - 2026-04-17

### Security
- **External security audit closed.** 1 HIGH, 2 MEDIUM, and 1 LOW finding fixed. Threat model: a compromised third-party AI CLI with write access to `~/.claude/projects/` dropping malicious session JSONL.
- **Prototype pollution blocked.** Breakdown maps in `parser.ts` (model, tool, MCP, bash) now use `Object.create(null)` so attacker-controlled keys like `__proto__` create own properties instead of mutating `Object.prototype`. Credit: @lfl1337 (PR #67).
- **Bounded session-file reads.** New `src/fs-utils.ts` helper caps reads at 128 MB and switches to stream-based parsing above 8 MB. Applied to 13 reachable read sites across parser, Codex, Copilot, Pi, context-budget, and optimize. Credit: @lfl1337 (PR #67).
- **Menubar label sanitizer.** SwiftBar directive-separator (`|`) and ANSI escape injection via crafted model or category names is now prevented by an allowlist (`[A-Za-z0-9 ._/-]`) plus 14-character truncation. Credit: @lfl1337 (PR #67).

### Added
- **`--verbose` flag.** Global CLI option that prints warnings to stderr on skipped (oversize) or failed session-file reads. Silent by default. Credit: @lfl1337 (PR #67).
- **11 new security tests.** `tests/security/prototype-pollution.test.ts`, `tests/security/menubar-injection.test.ts`, `tests/fs-utils.test.ts`. Total suite: 209 tests.

## 0.7.0 - 2026-04-16

### Added
- **`codeburn optimize` command.** Scans your sessions and your `~/.claude/`
  setup for 11 common waste patterns and hands back exact copy-paste fixes.
  Detection-only, never writes to user files. Supports `--period` (today,
  week, 30days, month, all) and `--provider` (all, claude, codex, cursor).
- **Setup health grade (A-F).** Urgency-weighted rollup of all findings, with
  impact scored against observed waste so the most expensive issues rank
  first. High findings penalise more, medium less, low least.
- **Trend tracking.** Repeat runs classify each finding as new, improving,
  or resolved against a 48-hour recent window, so fixed issues disappear
  instead of lingering as noise.
- **11 detectors:** files Claude re-reads across sessions, low Read:Edit
  ratio, projects missing `.claudeignore`, uncapped `BASH_MAX_OUTPUT_LENGTH`,
  unused MCP servers, ghost agents, ghost skills, ghost slash commands,
  bloated `CLAUDE.md` files (with `@-import` expansion counted), cache
  creation overhead, and junk directory reads.
- **Copy-paste fixes.** Each finding comes with a ready-to-paste remedy: a
  `CLAUDE.md` line, a `.claudeignore` template, an environment variable, or
  a `mv` command to archive unused items.
- **In-TUI optimize view.** Press `o` in the dashboard when the status bar
  shows a finding count, `b` to return. Same engine as the standalone
  command, scoped to the current period and provider.
- **Per-project context budget column.** By Project panel now shows the
  estimated per-session context overhead for each project (system prompt +
  tools + `CLAUDE.md` + skills).
- **34 filesystem-mocking tests.** Tmpdir fixtures with `os.homedir` mocked
  via `vi.mock` cover the detector surface end to end. Total suite: 198
  tests across 13 files.

### Performance
- **mtime pre-filter + parallel reads + 60s result cache** cut a cold scan
  from 12-17s to 6-7s on a 10k-session history.

## 0.6.1 - 2026-04-16

### Added
- **JSON output on `report`, `today`, `month`.** `--format json` writes the
  full dashboard (overview, daily, projects, models, activities, tools, MCP
  servers, shell commands, top sessions) to stdout. Contributed by @mallek.
- **Project filters.** `--project <name>` and `--exclude <name>` on all
  commands (`report`, `today`, `month`, `status`, `export`). Case-insensitive
  substring match against project name and path. Both flags are repeatable.
  Contributed by @mallek.
- **claude-opus-4-7 model mapping and pricing.** Displays as `Opus 4.7` with
  the same Opus pricing as 4.6 and a 6x fast multiplier. Contributed by @mallek.
- **Unit tests for `filterProjectsByName`** covering include/exclude
  semantics, case-insensitivity, path matching, and input immutability.

### Fixed
- **Top Sessions panel truncating the calls column.** Row width filled the
  full panel width without leaving room for the border and padding, so Ink
  truncated the last 4 characters -- landing exactly on the calls column and
  producing rows like `$182.58 ...` with no value.
- **SwiftBar custom plugin directory** now honoured when installing the
  menubar widget. Reads the configured path from SwiftBar's defaults before
  falling back to the standard location. Contributed by @Galeas.
- **`status --format menubar` per-provider today totals** now respect
  `--project`/`--exclude`. The main period blocks already did, the provider
  breakdown loop was the one spot that bypassed the filter.

## 0.6.0 - 2026-04-16

### Added
- **GitHub Copilot provider.** Parses `~/.copilot/session-state/*/events.jsonl`
  and tracks model changes via `session.model_change` events. Picks up six new
  model prices (`gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano`, `gpt-5-mini`, `o3`,
  `o4-mini`). Contributed by @theodorosD. Note: Copilot logs only output
  tokens, so cost rows will sit below actual API cost.
- **All Time period (key `5`).** Shows every recorded session since CodeBurn
  started tracking. Daily Activity expands to every available day instead of
  the fixed 14- or 31-day window. `codeburn report -p all` also works from
  the CLI. Contributed by @lfl1337.
- **avg/s column in By Project.** Average cost per session next to the
  existing total cost and session count. Surfaces projects where individual
  sessions are expensive even if the total is modest. Contributed by @lfl1337.
- **Top Sessions panel.** Highlights the five most expensive sessions across
  all projects with date, project, cost, and API call count. Helps spot
  outliers that drag weekly or monthly totals. Contributed by @lfl1337.

### Fixed
- `modelDisplayName` now matches longest key first so `gpt-4.1-mini` resolves
  to `GPT-4.1 Mini` instead of `GPT-4.1`.
- `TopSessions` handles missing `firstTimestamp` gracefully with a
  `----------` placeholder instead of rendering a stray whitespace row.

## 0.5.0 - 2026-04-15

### Added
- **Cursor IDE support.** Reads token usage from Cursor's local SQLite
  database. Shows activity classification, model breakdown, and a Languages
  panel extracted from code blocks. Costs estimated using Sonnet pricing for
  Auto mode (labeled clearly). Supports macOS, Linux, and Windows paths.
- SQLite adapter with lazy-loaded `better-sqlite3` (optional dependency).
  Claude Code and Codex users are completely unaffected if it is not installed.
- File-based result cache for Cursor. First run parses the database (can take
  up to a minute on very large databases); subsequent runs load from cache
  in under 250ms. Cache auto-invalidates when Cursor modifies the database.
- Provider-specific dashboard layout. Cursor shows a Languages panel instead
  of Core Tools, Shell Commands, and MCP Servers (Cursor does not log these).
- Provider color coding in the dashboard tab bar (Claude: orange, Codex: green,
  Cursor: cyan).
- Broader activity classification patterns: file extensions, script references,
  URLs, and HTTP status codes now trigger more accurate categories.
- Debounced period switching. Arrow keys wait 600ms before loading data so
  quickly scrolling through periods skips intermediate loads. Number keys
  still load immediately.
- Dynamic version reading from package.json (no more hardcoded version string).

### Fixed
- CLI `--version` reported stale 0.4.1 since v0.4.2. Closes #38.

## 0.4.4 - 2026-04-15

### Added
- Auto-refresh flag. `codeburn report --refresh 60` reloads data at a set
  interval. Works on `report`, `today`, and `month` commands. Default off.
- Readable project names. Strips home directory prefix from encoded paths,
  shows 3 path segments for more context. Home dir sessions display as "home".
- Responsive dashboard reflows on terminal resize via Ink's useWindowSize
  hook. Width cap raised from 104 to 160 columns. Contributed by @AleBles.
- Total downloads and install size badges in README.

### Fixed
- Agent/subagent session files were excluded, dropping ~46% of API calls.
  Subagent sessions live in separate subagents/ directories with unique
  message IDs and are now included. Closes #17.
- Codex cache hit always showed 100%. OpenAI includes cached tokens inside
  input_tokens (unlike Anthropic). Normalized to prevent double-counting
  in cost calculation and cache hit display. Closes #21.
- CSV formula injection. Cells starting with =, +, -, @ are prefixed with
  an apostrophe before CSV escaping. Contributed by @serabi.
- Menubar "Open Full Report" and "Export CSV" actions broken for npm-installed
  users. Invokes resolved binary directly instead of assuming ~/codeburn
  checkout. Currency picker used nonexistent `config currency` subcommand.
  Contributed by @MukundaKatta. Closes #32, #27.
- Activity panel moved from full-width to half-width row for better space
  usage on wide terminals.

## 0.4.1 - 2026-04-14

### Added
- Multi-currency support. `codeburn currency GBP` sets display currency (162 ISO
  4217 codes). Exchange rates from Frankfurter API (ECB data, 24h cache). Applies
  to dashboard, status, menubar, and exports. Contributed by @BlairWelsh.
- 30-day rolling window period (`codeburn report -p 30days`, key `3` in TUI).
  Distinct from calendar month. Contributed by @oysteinkrog.
- Menubar currency picker with 17 common currencies.

### Fixed
- Export "30 Days" period now uses actual 30-day range instead of calendar month.

## 0.4.0 - 2026-04-14

### Added
- Codex (OpenAI) support. Parses sessions from ~/.codex/sessions/ with full
  token tracking, cost calculation, task classification, and tool breakdown.
- Provider plugin system. Adding a new provider (Pi, OpenCode, Amp) is a
  single file in src/providers/.
- TUI provider toggle. Press p to cycle All / Claude / Codex. Auto-detects
  which providers have session data on disk. Hidden when only one is present.
- --provider flag on all CLI commands: report, today, month, status, export.
  Values: all (default), claude, codex.
- Codex tool normalization: exec_command -> Bash, read_file -> Read,
  write_file/apply_diff/apply_patch -> Edit, spawn_agent -> Agent.
- Codex model pricing: gpt-5, gpt-5.3-codex, gpt-5.4, gpt-5.4-mini with
  hardcoded fallbacks to prevent LiteLLM fuzzy matching mispricing.
- CODEX_HOME environment variable support for custom Codex data directories.
- Menubar per-provider cost breakdown when multiple providers have data.
- 1-minute in-memory cache with LRU eviction for instant provider switching.
- 10 new tests (Codex parser, provider registry, tool/model mapping).

### Fixed
- Model name fuzzy matching: gpt-5.4-mini no longer mispriced as gpt-5
  (more specific prefixes checked first).

## 0.3.1 - 2026-04-14

### Added
- Shell Commands breakdown panel showing which CLI binaries are used most
  (git, npm, docker, etc.). Parses compound commands (&&, ;, |) and handles
  quoted strings. Contributed by @rafaelcalleja.

### Changed
- Activity panel is now full-width so the 1-shot column renders cleanly
  on all terminal sizes.

### Fixed
- Crash on unreadable session files (ENOENT). Skips gracefully instead.

## 0.3.0 - 2026-04-14

### Added
- One-shot success rate per activity category. Detects edit/test/fix retry
  cycles (Edit -> Bash -> Edit) within each turn. Shows 1-shot percentage
  in the By Activity panel for categories that involve code edits.

### Fixed
- Turn grouping: tool-result entries (type "user" with no text) no longer
  split turns. Previously inflated Conversation category by 3-5x at the
  expense of Coding, Debugging, and other edit-heavy categories.

## 0.2.0 - 2026-04-14

### Added
- Claude Desktop (code tab) session support. Scans local-agent-mode-sessions
  in addition to ~/.claude/projects/. Same JSONL format, deduplication across
  both sources. macOS, Windows, and Linux paths.
- CLAUDE_CONFIG_DIR environment variable support. Falls back to ~/.claude if
  not set.

### Fixed
- npm package trimmed from 1.1MB to 41KB by adding files field (ships dist/
  only).
- Image URLs switched to jsDelivr CDN for npm readme rendering.

## 0.1.1 - 2026-04-13

### Fixed
- Readme image URLs for npm rendering.

## 0.1.0 - 2026-04-13

### Added
- Interactive TUI dashboard built with Ink (React for terminals).
- 13-category task classifier (coding, debugging, exploration, brainstorming,
  etc.) using tool usage patterns and keyword matching. No LLM calls.
- Breakdowns by daily activity, project, model, task type, core tools, and
  MCP servers.
- Gradient bar charts (blue to amber to orange) inspired by btop.
- Responsive layout: side-by-side panels at 90+ cols, stacked below.
- Keyboard navigation: arrow keys switch Today/7 Days/Month, q to quit.
- Column headers on all panels.
- Bottom status bar with key hints (interactive mode only).
- Per-panel accent border colors with rounded corners.
- SwiftBar/xbar menu bar widget with flame icon, activity breakdown, model
  costs, and token stats. Refreshes every 5 minutes.
- CSV and JSON export with Today, 7 Days, and 30 Days periods.
- LiteLLM pricing integration with 24h cache and hardcoded fallback.
  Supports input, output, cache write, cache read, web search, and fast
  mode multiplier.
- Message deduplication by API message ID across all session files.
- Date-range filtering per entry (not per session) to prevent session bleed.
- Compact status command with terminal, menubar, and JSON output formats.
