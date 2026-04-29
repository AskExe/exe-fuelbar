# Fuelbar Menubar (macOS)

Native Swift + SwiftUI menubar app. The Fuelbar menubar surface.

## Requirements

- macOS 14+ (Sonoma)
- Swift 6.0+ toolchain (bundled with Xcode 16 or standalone)
- `exe-fuelbar` CLI installed globally (`npm install -g exe-fuelbar`) or available at a path you pass via `EXE_FUELBAR_BIN`

## Install (end users)

One command:

```bash
npx exe-fuelbar menubar
```

That's it. The command downloads the latest `.app` from GitHub Releases, drops it into `~/Applications`, clears Gatekeeper quarantine, and launches it. Re-running it upgrades in place with `--force`, or just launches the existing copy otherwise.

If you already have the CLI installed globally (`npm install -g exe-fuelbar`), `exe-fuelbar menubar` works the same way.

### Build from source

For contributors running a local build instead of the packaged release:

```bash
npm install -g exe-fuelbar                       # CLI the app shells out to for data
git clone https://github.com/AskExe/exe-fuelbar.git
cd exe-fuelbar/mac
swift build -c release
.build/release/ExeFuelbarMenubar                # launch
```

## Build & run (dev against a local CLI checkout)

```bash
cd mac
swift build
# Point the app at your dev CLI build instead of the globally installed `exe-fuelbar`:
npm --prefix .. run build
EXE_FUELBAR_BIN="node $(pwd)/../dist/cli.js" swift run
```

The app registers itself as a menubar accessory (`LSUIElement = true` at runtime). No Dock icon.

## Data source

On launch and every 60 seconds thereafter, the app spawns `exe-fuelbar status --format menubar-json --no-optimize` directly (argv, no shell) via `ExeFuelbarCLI.makeProcess` and decodes the JSON into `MenubarPayload`. The manual refresh button in the footer invokes the same command without `--no-optimize`, which includes optimize findings but takes longer.

Override the binary via the `EXE_FUELBAR_BIN` environment variable (default: `exe-fuelbar` on PATH). The value is validated against a strict allowlist (alphanumerics plus `._/-` space) before use, so a malicious env var can't inject shell commands.

## Project layout

```
mac/
├── Package.swift                     SwiftPM manifest
├── Sources/ExeFuelbarMenubar/
│   ├── FuelbarApp.swift                 @main + MenuBarExtra scene
│   ├── AppStore.swift                @Observable store + enums
│   ├── Data/MenubarPayload.swift     Codable payload types + placeholder
│   ├── Theme/Theme.swift             Design tokens (Exe Foundry Bold palette)
│   └── Views/MenuBarContent.swift    Popover layout + footer action bar
└── README.md                         This file
```

## Status

Live data wired. Next iterations:

1. FSEvents watch for `~/.claude/projects/` changes (debounced refresh on real edits)
2. Persistent disk cache for optimize findings so the default refresh can include them without the 30-second penalty
3. Currency metadata in the JSON payload + Swift-side formatting
4. Sparkle auto-update
5. DMG packaging + Homebrew Cask tap

## Design tokens

Exe Foundry Bold palette (gold accent on dark purple):

- Brand accent (gold): `#F5D76E`
- Brand accent hover: `#FADF85`
- Aura purple (depth/glow): `#6B4C9A`
- Dark purple (text on gold): `#3A285C`
- Pressed gold: `#E6C54F`
- Surface (light): `#FAF8F3`
- Surface (dark): `#1A1528`

SF Mono for currency values; SF Pro for UI text. Web equivalents: Epilogue (headings), Manrope (body).
