import SwiftUI
import AppKit
import Observation
import ServiceManagement
import CoreServices
import os.log

private let wlog = Logger(subsystem: "com.askexe.exe-watcher-menubar", category: "refresh")

/// Keep the always-visible menu bar badge live. This matches the README/product promise and
/// avoids the badge appearing stuck while the popover is closed during active coding sessions.
private let refreshIntervalSeconds: UInt64 = 30
private let idleRefreshIntervalSeconds: UInt64 = 30
private let statusItemWidth: CGFloat = NSStatusItem.variableLength
private let popoverWidth: CGFloat = 400
private let popoverHeight: CGFloat = 660

private let refreshTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()
private let menubarTitleFontSize: CGFloat = 13

@main
struct ExeWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // SwiftUI App needs at least one scene. Settings is invisible by default.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = AppStore()
    let updateChecker = UpdateChecker()
    private var refreshLoopTask: Task<Void, Never>?
    private var refreshTimer: DispatchSourceTimer?

    /// Append a timestamped line to ~/.cache/exe-watcher/refresh.log for debugging.
    /// Keeps only the last 200 lines to avoid unbounded growth.
    static func appendLog(_ message: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/exe-watcher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logFile = dir.appendingPathComponent("refresh.log")
        let ts = refreshTimeFormatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: logFile)
        }
        // Trim to last 200 lines periodically (every ~50 writes)
        if Int.random(in: 0..<50) == 0 {
            if let content = try? String(contentsOf: logFile, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n")
                if lines.count > 200 {
                    let trimmed = lines.suffix(200).joined(separator: "\n")
                    try? trimmed.write(to: logFile, atomically: true, encoding: .utf8)
                }
            }
        }
    }
    private var usageLogWatcher: UsageLogWatcher?
    private var usageLogDebounceTask: Task<Void, Never>?
    private var automaticRefreshInFlight = false
    private var automaticRefreshQueued = false
    /// Held for the lifetime of the app to prevent Automatic Termination.
    private var backgroundActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerBundledFonts()

        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableSuddenTermination()
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "Watcher needs to stay running to update cost display."
        )

        restorePersistedCurrency()
        setupStatusItem()
        setupPopover()
        observeStore()
        startRefreshLoop()
        startUsageLogWatcher()
        setupWakeObservers()
        cleanupLegacyLaunchAgent()
        registerLoginItemIfNeeded()
        Task { await updateChecker.checkIfNeeded() }
    }

    private func setupWakeObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.forceRefresh() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.forceRefresh() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.forceRefresh() }
        }
    }

    /// Removes the legacy LaunchAgent plist that older versions installed. The redundant
    /// system-level timer doubled refresh work and prevented App Nap from throttling the app.
    private func cleanupLegacyLaunchAgent() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let destPath = "\(home)/Library/LaunchAgents/com.exe-watcher.refresh.plist"
        guard fm.fileExists(atPath: destPath) else { return }
        let unload = Process()
        unload.launchPath = "/bin/launchctl"
        unload.arguments = ["unload", destPath]
        try? unload.run()
        unload.waitUntilExit()
        try? fm.removeItem(atPath: destPath)
    }

    /// Registers the app as a Login Item so it launches automatically at startup.
    /// Uses SMAppService (macOS 13+). Only registers once — if the user later disables
    /// it via System Settings → General → Login Items, we respect that choice.
    private func registerLoginItemIfNeeded() {
        let service = SMAppService.mainApp
        if service.status == .notRegistered {
            do {
                try service.register()
                NSLog("Exe Watcher: registered as Login Item")
            } catch {
                NSLog("Exe Watcher: Login Item registration failed: \(error)")
            }
        }
    }

    private func forceRefresh() {
        Task {
            store.recoverFromSystemResume()
            await store.refreshTodayBadge()
            await store.refreshVisibleSelection()
            refreshStatusButton()
        }
    }

    /// Loads the currency code persisted by `exe-watcher currency` so a relaunch picks up where
    /// the user left off. Rate is resolved from the on-disk FX cache if present, otherwise
    /// fetched live in the background.
    private func restorePersistedCurrency() {
        guard let code = CLICurrencyConfig.loadCode(), code != "USD" else { return }
        let symbol = CurrencyState.symbolForCode(code)
        store.currency = code
        let generation = CurrencyState.shared.beginSelection(code: code, symbol: symbol)

        Task {
            let cached = await FXRateCache.shared.cachedRate(for: code)
            await MainActor.run {
                CurrencyState.shared.apply(code: code, rate: cached, symbol: symbol, generation: generation)
            }
            let fresh = await FXRateCache.shared.rate(for: code)
            if let fresh, fresh != cached {
                await MainActor.run {
                    CurrencyState.shared.apply(code: code, rate: fresh, symbol: symbol, generation: generation)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshLoopTask?.cancel()
        refreshTimer?.cancel()
        usageLogDebounceTask?.cancel()
        usageLogWatcher?.stop()
    }

    private func startRefreshLoop() {
        // Initial fetch: update only the always-visible badge. Do not prefetch every period at
        // launch: long historical scans can compete with the 30s badge refresh and make the
        // menubar total look stuck. Historical periods load lazily when selected.
        Task {
            await store.refreshTodayBadge()
            refreshStatusButton()
        }

        // Popover starts closed — use the idle interval. popoverWillShow will tighten to 60s.
        rescheduleTimer(intervalSeconds: idleRefreshIntervalSeconds)
    }

    /// The 30s timer is a safety net, not the freshness mechanism. Usage files are append-only
    /// while the user is actively coding, so watch those directories and refresh shortly after
    /// real writes. Without this, an accessory app can look stale until opening the popover,
    /// because popoverWillShow/manual Refresh are the only event-driven refresh paths.
    private func startUsageLogWatcher() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { "\($0)/projects" } ?? "\(home)/.claude/projects",
            "\(home)/Library/Application Support/Claude/local-agent-mode-sessions",
            ProcessInfo.processInfo.environment["CODEX_HOME"].map { "\($0)/sessions" } ?? "\(home)/.codex/sessions",
            "\(home)/.cursor/projects",
            "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
        ]
        let opencodeDir = "\(home)/.local/share/opencode"
        if let opencodeEntries = try? fm.contentsOfDirectory(atPath: opencodeDir) {
            candidates.append(contentsOf: opencodeEntries
                .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
                .map { "\(opencodeDir)/\($0)" })
        }
        let paths = candidates.filter { fm.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        usageLogWatcher = UsageLogWatcher(paths: paths) { [weak self] in
            Task { @MainActor in
                self?.scheduleUsageLogRefresh()
            }
        }
        usageLogWatcher?.start()
    }

    /// Throttle (not debounce) FSEvents-driven refreshes. Under heavy agent write load,
    /// debounce never fires because each new event cancels the previous sleep. Throttle
    /// guarantees a refresh fires within 5s of the first event, then ignores events for
    /// a cooldown period. This is the fix for the "$140→$190 jump on manual refresh" bug.
    private var lastFSEventRefreshAt: Date = .distantPast
    private static let fsEventThrottleSeconds: TimeInterval = 5

    private func scheduleUsageLogRefresh() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFSEventRefreshAt)
        guard elapsed >= Self.fsEventThrottleSeconds else { return }

        // First event after cooldown — schedule a refresh after a short delay to batch
        // rapid-fire events, but DON'T cancel on subsequent events (throttle, not debounce).
        guard usageLogDebounceTask == nil else { return }
        Self.appendLog("FSEVENTS throttle: scheduling refresh")
        usageLogDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.lastFSEventRefreshAt = Date()
            self.usageLogDebounceTask = nil
            Self.appendLog("FSEVENTS throttle: firing refresh")
            Task { @MainActor [weak self] in
                await self?.performAutomaticRefresh(refreshSelectedPeriod: false)
            }
        }
    }

    private func performAutomaticRefresh(refreshSelectedPeriod: Bool) async {
        if automaticRefreshInFlight {
            wlog.notice("refresh skipped (already in flight)")
            Self.appendLog("SKIPPED (in flight)")
            automaticRefreshQueued = true
            return
        }

        automaticRefreshInFlight = true
        defer { automaticRefreshInFlight = false }

        repeat {
            automaticRefreshQueued = false
            let start = Date()
            await store.refreshTodayBadge()
            let elapsed = Date().timeIntervalSince(start)
            let cost = store.todayPayload?.current.cost ?? -1
            wlog.notice("badge refreshed in \(String(format: "%.1f", elapsed))s — cost=$\(String(format: "%.2f", cost))")
            Self.appendLog("REFRESH done in \(String(format: "%.1f", elapsed))s — cost=$\(String(format: "%.2f", cost))")
            refreshStatusButton()
            let selected = store.selectedPeriod
            if refreshSelectedPeriod && selected != .today {
                await store.refreshQuietly(period: selected)
            }
        } while automaticRefreshQueued
    }

    private func rescheduleTimer(intervalSeconds: UInt64) {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        refreshTimer?.cancel()
        // Use a DispatchSourceTimer instead of Task.sleep. Swift cooperative task
        // scheduling can defer .sleep wakeups indefinitely for background/accessory
        // apps even with beginActivity — the runtime treats them as low-priority.
        // GCD timers fire reliably regardless of app activation state.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Double(intervalSeconds), repeating: Double(intervalSeconds), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            let tick = Date()
            wlog.notice("timer fired at \(refreshTimeFormatter.string(from: tick)) (interval=\(intervalSeconds)s)")
            Self.appendLog("TIMER fired (interval=\(intervalSeconds)s)")
            Task { @MainActor [weak self] in
                await self?.performAutomaticRefresh(refreshSelectedPeriod: true)
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func observeStore() {
        Task { @MainActor [weak self] in
            while let self {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.store.payload
                        _ = self.store.todayPayload
                    } onChange: {
                        continuation.resume()
                    }
                }
                self.refreshStatusButton()
            }
        }
    }

    // MARK: - Status Item

    private var isCompact: Bool {
        UserDefaults.standard.bool(forKey: "ExeWatcherMenubarCompact")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: statusItemWidth)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshStatusButton()
    }

    /// Sets the menubar icon (owl) + cost text. Uses button.image for the icon
    /// and button.attributedTitle for the text — simpler and more reliable than
    /// NSTextAttachment which silently drops custom images.
    private func refreshStatusButton() {
        guard let button = statusItem.button else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: menubarTitleFontSize, weight: .medium)
        let iconH: CGFloat = menubarTitleFontSize + 3

        // Draw the owl programmatically — PDF/SVG template images are unreliable at menubar size.
        let owlImage: NSImage = Self.drawOwl(height: iconH)

        button.image = owlImage
        button.imagePosition = .imageLeading

        let hasPayload = store.todayPayload != nil
        let compact = isCompact
        let fallback = compact ? "$-" : "$—"
        let formatted = store.todayPayload?.current.cost
        let valueText = compact
            ? (formatted?.asCompactCurrencyWhole() ?? fallback)
            : (formatted?.asCompactCurrency() ?? fallback)
        let color: NSColor = hasPayload ? .labelColor : .secondaryLabelColor

        button.attributedTitle = NSAttributedString(
            string: valueText,
            attributes: [.font: font, .foregroundColor: color]
        )
        // Force the menu bar to repaint immediately. For accessory apps (LSUIElement), setting
        // needsDisplay + display() only draws into the button's backing store — the system-owned
        // menu bar window won't composite the update until something nudges WindowServer.
        // Toggling the status item length forces a layout pass that makes the fresh content
        // visible without requiring user interaction.
        button.needsDisplay = true
        let currentLength = statusItem.length
        statusItem.length = currentLength == NSStatusItem.variableLength
            ? currentLength : NSStatusItem.variableLength
        statusItem.length = currentLength
        button.display()
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
        popover.behavior = .transient  // auto-close only on explicit outside click
        popover.animates = true
        popover.delegate = self

        let content = MenuBarContent()
            .environment(store)
            .environment(updateChecker)
            .frame(width: popoverWidth)
            .preferredColorScheme(.dark)

        popover.contentViewController = NSHostingController(rootView: content)
        popover.contentViewController?.view.appearance = NSAppearance(named: .darkAqua)
    }

    @objc private func handleButtonClick(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        false
    }

    func popoverWillShow(_ notification: Notification) {
        Task {
            await store.refreshTodayBadge()
            await store.refreshVisibleSelection()
            refreshStatusButton()
        }
        rescheduleTimer(intervalSeconds: refreshIntervalSeconds)
    }

    func popoverDidClose(_ notification: Notification) {
        rescheduleTimer(intervalSeconds: idleRefreshIntervalSeconds)
    }

    // MARK: - Font Registration

    /// Register bundled custom fonts (Epilogue) so they're available via Font.custom().
    private func registerBundledFonts() {
        let fontNames = ["Epilogue-Bold"]
        for name in fontNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else {
                NSLog("Exe Watcher: font \(name).ttf not found in bundle")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    // MARK: - Owl Icon

    /// Draws a crisp owl icon at the requested point size. Returns an NSImage marked as
    /// template so macOS auto-colors it for the menubar (white on dark, black on light).
    /// All coordinates are relative to a 100×100 design grid, scaled to `height`.
    private static func drawOwl(height: CGFloat) -> NSImage {
        let s = height / 100.0  // scale factor
        let size = NSSize(width: height, height: height)
        let img = NSImage(size: size, flipped: false) { _ in
            let fill = NSColor.black

            // --- Ear tufts ---
            let leftEar = NSBezierPath()
            leftEar.move(to: NSPoint(x: 26*s, y: (100-32)*s))
            leftEar.line(to: NSPoint(x: 18*s, y: (100-6)*s))
            leftEar.line(to: NSPoint(x: 36*s, y: (100-26)*s))
            leftEar.close()
            fill.setFill()
            leftEar.fill()

            let rightEar = NSBezierPath()
            rightEar.move(to: NSPoint(x: 74*s, y: (100-32)*s))
            rightEar.line(to: NSPoint(x: 82*s, y: (100-6)*s))
            rightEar.line(to: NSPoint(x: 64*s, y: (100-26)*s))
            rightEar.close()
            rightEar.fill()

            // --- Head ---
            let head = NSBezierPath(ovalIn: NSRect(
                x: (50-24)*s, y: (100-38-24)*s, width: 48*s, height: 48*s))
            head.fill()

            // --- Body ---
            let body = NSBezierPath(ovalIn: NSRect(
                x: (50-21)*s, y: (100-70-23)*s, width: 42*s, height: 46*s))
            body.fill()

            // --- Feet ---
            let leftFoot = NSBezierPath(ovalIn: NSRect(
                x: (40-7)*s, y: (100-92-3.5)*s, width: 14*s, height: 7*s))
            leftFoot.fill()
            let rightFoot = NSBezierPath(ovalIn: NSRect(
                x: (60-7)*s, y: (100-92-3.5)*s, width: 14*s, height: 7*s))
            rightFoot.fill()

            // --- Eye sockets (punch out with clear using CGContext) ---
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.setBlendMode(.clear)

                let leftSocket = NSBezierPath(ovalIn: NSRect(
                    x: (38-10)*s, y: (100-35-10)*s, width: 20*s, height: 20*s))
                leftSocket.fill()

                let rightSocket = NSBezierPath(ovalIn: NSRect(
                    x: (62-10)*s, y: (100-35-10)*s, width: 20*s, height: 20*s))
                rightSocket.fill()

                // --- Beak (punch out) ---
                let beak = NSBezierPath()
                beak.move(to: NSPoint(x: 46*s, y: (100-46)*s))
                beak.line(to: NSPoint(x: 50*s, y: (100-53)*s))
                beak.line(to: NSPoint(x: 54*s, y: (100-46)*s))
                beak.close()
                beak.fill()

                ctx.setBlendMode(.normal)
            }

            // --- Pupils (filled dots inside the clear sockets) ---
            fill.setFill()
            let leftPupil = NSBezierPath(ovalIn: NSRect(
                x: (38-4.5)*s, y: (100-35-4.5)*s, width: 9*s, height: 9*s))
            leftPupil.fill()
            let rightPupil = NSBezierPath(ovalIn: NSRect(
                x: (62-4.5)*s, y: (100-35-4.5)*s, width: 9*s, height: 9*s))
            rightPupil.fill()

            return true
        }
        img.isTemplate = true
        return img
    }
}

private final class UsageLogWatcher: @unchecked Sendable {
    private let paths: [String]
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, _, _, _ in
            guard let info else { return }
            guard count > 0 else { return }

            let watcher = Unmanaged<UsageLogWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                watcher.onChange()
            }
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        guard let stream else {
            NSLog("Exe Watcher: failed to create usage log watcher")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if !FSEventStreamStart(stream) {
            NSLog("Exe Watcher: failed to start usage log watcher")
            stop()
        } else {
            NSLog("Exe Watcher: watching usage logs: \(paths.joined(separator: ", "))")
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
