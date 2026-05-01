import SwiftUI
import AppKit
import Observation
import ServiceManagement

private let refreshIntervalSeconds: UInt64 = 60
private let idleRefreshIntervalSeconds: UInt64 = 300
private let statusItemWidth: CGFloat = NSStatusItem.variableLength
private let popoverWidth: CGFloat = 380
private let popoverHeight: CGFloat = 660
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
    private var dispatchTimer: DispatchSourceTimer?
    /// Held for the lifetime of the app to prevent Automatic Termination.
    private var backgroundActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerBundledFonts()

        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableSuddenTermination()
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "Watcher needs to stay running to update cost display."
        )

        restorePersistedCurrency()
        setupStatusItem()
        setupPopover()
        observeStore()
        startRefreshLoop()
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
            await store.refreshQuietly(period: .today)
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        dispatchTimer?.cancel()
    }

    private func startRefreshLoop() {
        // Initial fetch: today first (fast, updates menubar badge), then prefetch all other periods
        // in background so tab switching is instant.
        Task {
            await store.refreshQuietly(period: .today)
            refreshStatusButton()
            await store.prefetchAllPeriods()
        }

        // Popover starts closed — use the idle interval. popoverWillShow will tighten to 60s.
        rescheduleTimer(intervalSeconds: idleRefreshIntervalSeconds)
    }

    private func rescheduleTimer(intervalSeconds: UInt64) {
        dispatchTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(Int(intervalSeconds)), repeating: .seconds(Int(intervalSeconds)), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                await self.store.refreshQuietly(period: .today)
                self.refreshStatusButton()
                let selected = self.store.selectedPeriod
                if selected != .today {
                    await self.store.refreshQuietly(period: selected)
                }
            }
        }
        timer.resume()
        dispatchTimer = timer
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
        // Force immediate redraw. NSStatusItem sometimes defers the status bar paint for an
        // accessory app that is not foreground, so the label visually freezes until the user
        // opens the popover (which triggers NSApp.activate + a forced redraw cycle).
        button.needsDisplay = true
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
            await store.refreshQuietly(period: .today)
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
