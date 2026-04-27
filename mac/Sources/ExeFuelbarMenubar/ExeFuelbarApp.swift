import SwiftUI
import AppKit
import Observation

private let refreshIntervalSeconds: UInt64 = 60
private let nanosPerSecond: UInt64 = 1_000_000_000
private let refreshIntervalNanos: UInt64 = refreshIntervalSeconds * nanosPerSecond
private let statusItemWidth: CGFloat = NSStatusItem.variableLength
private let popoverWidth: CGFloat = 360
private let popoverHeight: CGFloat = 660
private let menubarTitleFontSize: CGFloat = 13

@main
struct ExeFuelbarApp: App {
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
    /// Held for the lifetime of the app to opt out of App Nap and Automatic Termination.
    private var backgroundActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableSuddenTermination()
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "Exe Fuelbar menubar polls AI coding cost every 60 seconds while idle in the background."
        )

        restorePersistedCurrency()
        setupStatusItem()
        setupPopover()
        observeStore()
        startRefreshLoop()
        setupWakeObservers()
        setupDistributedNotificationListener()
        installLaunchAgentIfNeeded()
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

    private func setupDistributedNotificationListener() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.exe-fuelbar.refresh"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.forceRefresh() }
        }
    }

    private func installLaunchAgentIfNeeded() {
        let fm = FileManager.default
        let agentName = "com.exe-fuelbar.refresh.plist"
        let home = fm.homeDirectoryForCurrentUser.path
        let destPath = "\(home)/Library/LaunchAgents/\(agentName)"

        let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.exe-fuelbar.refresh</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/osascript</string>
        <string>-l</string>
        <string>JavaScript</string>
        <string>-e</string>
        <string>ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.exe-fuelbar.refresh", $(), $(), true)</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
"""

        do {
            let existing = try? String(contentsOfFile: destPath, encoding: .utf8)
            if existing == plist { return }

            try fm.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
            try plist.write(toFile: destPath, atomically: true, encoding: .utf8)

            let unload = Process()
            unload.launchPath = "/bin/launchctl"
            unload.arguments = ["unload", destPath]
            try? unload.run()
            unload.waitUntilExit()

            let load = Process()
            load.launchPath = "/bin/launchctl"
            load.arguments = ["load", destPath]
            try load.run()
            load.waitUntilExit()
        } catch {
            NSLog("Exe Fuelbar: LaunchAgent setup failed: \(error)")
        }
    }

    private func forceRefresh() {
        Task {
            await store.refreshQuietly(period: .today)
            refreshStatusButton()
            await store.refresh(includeOptimize: true)
            refreshStatusButton()
        }
    }

    /// Loads the currency code persisted by `exe-fuelbar currency` so a relaunch picks up where
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

        // Use DispatchSourceTimer for more reliable background execution
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(Int(refreshIntervalSeconds)), repeating: .seconds(Int(refreshIntervalSeconds)), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                // Background timer: use refreshQuietly for ALL periods so the loading
                // overlay never flashes while the popover is open. The menubar badge
                // and popover body still update silently via @Observable diffing.
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
        withObservationTracking {
            _ = store.payload
            _ = store.todayPayload
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshStatusButton()
                self?.observeStore()
            }
        }
    }

    // MARK: - Status Item

    private var isCompact: Bool {
        UserDefaults.standard.bool(forKey: "ExeFuelbarMenubarCompact")
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
