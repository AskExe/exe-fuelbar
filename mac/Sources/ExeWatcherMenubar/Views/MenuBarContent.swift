import AppKit
import SwiftUI

/// Reusable owl icon drawn programmatically. Same drawing as the menubar icon.
/// Renders as a template image (white on dark backgrounds).
struct OwlIcon: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: Self.draw(size: size))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    /// Draws the owl at the requested size using the same NSBezierPath approach as the menubar.
    static func draw(size: CGFloat) -> NSImage {
        let s = size / 100.0
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let fill = NSColor.black

            // Ear tufts
            let leftEar = NSBezierPath()
            leftEar.move(to: NSPoint(x: 26*s, y: (100-32)*s))
            leftEar.line(to: NSPoint(x: 18*s, y: (100-6)*s))
            leftEar.line(to: NSPoint(x: 36*s, y: (100-26)*s))
            leftEar.close()
            fill.setFill(); leftEar.fill()

            let rightEar = NSBezierPath()
            rightEar.move(to: NSPoint(x: 74*s, y: (100-32)*s))
            rightEar.line(to: NSPoint(x: 82*s, y: (100-6)*s))
            rightEar.line(to: NSPoint(x: 64*s, y: (100-26)*s))
            rightEar.close()
            rightEar.fill()

            // Head
            NSBezierPath(ovalIn: NSRect(
                x: (50-24)*s, y: (100-38-24)*s, width: 48*s, height: 48*s)).fill()

            // Body
            NSBezierPath(ovalIn: NSRect(
                x: (50-21)*s, y: (100-70-23)*s, width: 42*s, height: 46*s)).fill()

            // Feet
            NSBezierPath(ovalIn: NSRect(
                x: (40-7)*s, y: (100-92-3.5)*s, width: 14*s, height: 7*s)).fill()
            NSBezierPath(ovalIn: NSRect(
                x: (60-7)*s, y: (100-92-3.5)*s, width: 14*s, height: 7*s)).fill()

            // Punch out eyes + beak
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.setBlendMode(.clear)
                NSBezierPath(ovalIn: NSRect(
                    x: (38-10)*s, y: (100-35-10)*s, width: 20*s, height: 20*s)).fill()
                NSBezierPath(ovalIn: NSRect(
                    x: (62-10)*s, y: (100-35-10)*s, width: 20*s, height: 20*s)).fill()
                let beak = NSBezierPath()
                beak.move(to: NSPoint(x: 46*s, y: (100-46)*s))
                beak.line(to: NSPoint(x: 50*s, y: (100-53)*s))
                beak.line(to: NSPoint(x: 54*s, y: (100-46)*s))
                beak.close()
                beak.fill()
                ctx.setBlendMode(.normal)
            }

            // Pupils
            fill.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: (38-4.5)*s, y: (100-35-4.5)*s, width: 9*s, height: 9*s)).fill()
            NSBezierPath(ovalIn: NSRect(
                x: (62-4.5)*s, y: (100-35-4.5)*s, width: 9*s, height: 9*s)).fill()

            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Popover root. Assembles all sections matching the HTML design spec.
struct MenuBarContent: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Header()

            Divider()

            if showAgentTabs {
                AgentTabStrip()
                Divider()
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    HeroSection()
                    Divider().opacity(0.5)
                    PeriodSegmentedControl()
                    Divider().opacity(0.5)
                    if isFilteredEmpty {
                        EmptyProviderState(provider: store.selectedProvider, period: store.selectedPeriod)
                    } else {
                        HeatmapSection()
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 10)
                            .zIndex(10)
                        Divider().opacity(0.5)
                        ActivitySection()
                        Divider().opacity(0.5)
                        ModelsSection()
                        Divider().opacity(0.5)
                        AgentsSection()
                        Divider().opacity(0.5)
                        ProjectSpendSection()
                        Divider().opacity(0.5)
                        FindingsSection()
                    }
                }
            }
            .frame(height: 520)

            Divider()

            FooterBar()

            StarBanner()
        }
        .background(Theme.warmSurfaceDark)
    }

    /// True when a specific provider tab is selected and that provider has no spend in the
    /// currently selected period. The .all tab is exempt -- it always shows aggregated data.
    private var isFilteredEmpty: Bool {
        guard store.selectedProvider != .all else { return false }
        return store.payload.current.cost <= 0 && store.payload.current.calls == 0
    }

    /// Show the tab row whenever the CLI detected at least one AI coding tool installed
    /// on this machine. Hidden only when nothing is detected, which means there's
    /// nothing to filter by anyway.
    private var showAgentTabs: Bool {
        let payload = store.todayPayload ?? store.payload
        return !payload.current.providers.isEmpty
    }

}

private struct EmptyProviderState: View {
    let provider: ProviderFilter
    let period: Period

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No \(provider.rawValue) data for \(periodPhrase)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var periodPhrase: String {
        switch period {
        case .today: "today"
        case .sevenDays: "the last 7 days"
        case .thirtyDays: "the last 30 days"
        case .month: "this month"
        case .all: "all time"
        }
    }
}

/// Translucent overlay that blurs whatever's behind it (the previous tab/period content)
/// and centers an animated owl icon pulsing with the brand palette.
private struct BurnLoadingOverlay: View {
    let periodLabel: String
    @State private var glowing: Bool = false

    private let iconSize: CGFloat = 48

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            VStack(spacing: 14) {
                ZStack {
                    OwlIcon(size: iconSize)
                        .foregroundStyle(.white.opacity(glowing ? 0.5 : 0.2))
                        .blur(radius: glowing ? 12 : 5)

                    OwlIcon(size: iconSize)
                        .foregroundStyle(.white)
                        .opacity(glowing ? 1.0 : 0.6)
                }
                .frame(width: iconSize, height: iconSize)

                Text("Loading \(periodLabel)…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                glowing = true
            }
        }
    }
}

private struct Header: View {
    @Environment(UpdateChecker.self) private var updateChecker

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("WATCHER")
                .foregroundStyle(Color(red: 0xD4/255.0, green: 0x61/255.0, blue: 0x9C/255.0))
                .font(.custom("Epilogue", size: 14).weight(.bold))
                .tracking(2)
                Text("AGENT MEMORY & USAGE DASHBOARD")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if updateChecker.updateAvailable {
                UpdateBadge()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct UpdateBadge: View {
    @Environment(UpdateChecker.self) private var updateChecker

    var body: some View {
        Button {
            updateChecker.performUpdate()
        } label: {
            HStack(spacing: 4) {
                if updateChecker.isUpdating {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                }
                Text(updateChecker.isUpdating ? "Updating..." : "Update")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .goldButton()
        .controlSize(.mini)
        .disabled(updateChecker.isUpdating)
    }
}

struct FlameMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    LinearGradient(
                        colors: [Theme.brandAccentDark, Theme.brandEmberDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            OwlIcon(size: 12)
                .foregroundStyle(.white)
        }
    }
}

private let starBannerGitHubURL = URL(string: "https://github.com/AskExe/exe-watcher")!

/// Shown at the very bottom on first launch. A small terracotta strip nudges users to star the
/// repo; clicking opens GitHub, clicking the close icon hides it forever (persisted to
/// UserDefaults so it never returns across launches).
struct StarBanner: View {
    @AppStorage("exe-watcher.starBannerDismissed") private var dismissed: Bool = false

    var body: some View {
        if !dismissed {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.brandAccent)

                Button {
                    NSWorkspace.shared.open(starBannerGitHubURL)
                } label: {
                    HStack(spacing: 4) {
                        Text("Enjoying Watcher?")
                            .foregroundStyle(.primary)
                        Text("Star us on GitHub")
                            .foregroundStyle(Theme.brandAccent)
                            .underline(true, pattern: .solid)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide this banner")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.brandAccent.opacity(0.08))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 0.5)
            }
        }
    }
}

struct FooterBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(SupportedCurrency.allCases) { currency in
                    Button {
                        applyCurrency(code: currency.rawValue)
                    } label: {
                        if currency.rawValue == store.currency {
                            Label("\(currency.displayName) (\(currency.rawValue))", systemImage: "checkmark")
                        } else {
                            Text("\(currency.displayName) (\(currency.rawValue))")
                        }
                    }
                }
            } label: {
                Label(store.currency, systemImage: "dollarsign.circle")
                    .font(.system(size: 11, weight: .medium))
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Button {
                Task { await store.refresh(includeOptimize: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu {
                Button("CSV (folder)") { runExport(format: .csv) }
                Button("JSON") { runExport(format: .json) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Spacer()

            Button { openReport() } label: {
                Label("Open Full Report", systemImage: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .labelStyle(.titleAndIcon)
            }
            .goldButton()
            .controlSize(.small)

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Quit Watcher")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openReport() {
        TerminalLauncher.open(subcommand: ["report"])
    }

    private enum ExportFormat {
        case csv, json
        var cliName: String { self == .csv ? "csv" : "json" }
        var suffix: String { self == .csv ? "" : ".json" }
    }

    /// Runs `exe-watcher export` directly into ~/Downloads and reveals the result in Finder. CSV
    /// produces a folder of clean one-table-per-file CSVs; JSON produces a single structured
    /// file. The CLI is spawned with argv (no shell interpretation), so the output path cannot
    /// be abused to inject shell commands even if a pathological value slips through.
    private func runExport(format: ExportFormat) {
        Task {
            let downloads = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let base = "exe-watcher-\(formatter.string(from: Date()))"
            let outputPath = (downloads as NSString).appendingPathComponent(base + format.suffix)

            let process = ExeWatcherCLI.makeProcess(subcommand: [
                "export", "-f", format.cliName, "-o", outputPath
            ])

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outputPath)])
                } else {
                    NSLog("Exe Watcher: \(format.cliName.uppercased()) export exited with status \(process.terminationStatus)")
                }
            } catch {
                NSLog("Exe Watcher: \(format.cliName.uppercased()) export failed: \(error)")
            }
        }
    }

    /// Instant-feeling currency switch. Updates the symbol and any cached FX rate on the main
     /// thread right away so the UI redraws the next frame, then fetches a fresh rate in the
     /// background. CLI config is persisted so other exe-watcher commands stay in sync.
    private func applyCurrency(code: String) {
        store.currency = code
        let symbol = CurrencyState.symbolForCode(code)

        Task {
            let cached = await FXRateCache.shared.cachedRate(for: code)
            await MainActor.run {
                CurrencyState.shared.apply(code: code, rate: cached, symbol: symbol)
            }

            let fresh = await FXRateCache.shared.rate(for: code)
            if let fresh, fresh != cached {
                await MainActor.run {
                    CurrencyState.shared.apply(code: code, rate: fresh, symbol: symbol)
                }
            }
        }

        CLICurrencyConfig.persist(code: code)
    }
}
