import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MonitorModel()
    let keyboard = KeyboardController()
    let hud = HUDController()
    var statusItem: NSStatusItem!
    var panel: PanelController!
    lazy var quickMenu = QuickMenu(model: model) { [weak self] in self?.openSettings() }
    var screenChange: DispatchWorkItem?
    var permissionTimer: Timer?
    var refreshTimer: Timer?
    /// Rediscovery backs off while no display answers (asleep or unplugged);
    /// screen changes and wake reset it.
    var discoveryInterval: TimeInterval = 5
    var nextDiscovery = Date.distantPast
    var scrollMonitor: Any?
    var scrollAccumulator: CGFloat = 0
    var pendingCommand: ControlCommand?
    private var statusImageKey: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.target = self; button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(L("光控"))
        }
        updateStatus()
        let actions = PanelActions(toggleMediaKeys: { [weak self] in self?.toggleMediaKeys() },
                                   reconnectMediaKeys: { [weak self] in self?.reconnectMediaKeys() },
                                   quit: { NSApp.terminate(nil) })
        panel = PanelController(model: model, actions: actions)
        panel.onShow = { [weak self] in
            guard let self else { return }
            self.discoveryInterval = 5; self.nextDiscovery = .distantPast
            self.model.refresh(reconsiderBrightness: self.model.isAutoSoftwareFallback)
            self.model.displaySettings.refresh()
            self.model.loginEnabled = SMAppService.mainApp.status == .enabled
        }

        keyboard.onBrightness = { [weak self] in self?.model.adjust(.brightness, by: $0) }
        keyboard.onVolume = { [weak self] in self?.model.adjust(.volume, by: $0) }
        keyboard.onMute = { [weak self] in self?.model.toggleMute() }
        keyboard.onToggle = { [weak self] in self?.togglePopover() }
        keyboard.canHandleMediaKey = { [weak self] feature in self?.model.controls[feature]?.value != nil }
        keyboard.onKeyboardAction = { [weak self] in self?.model.recordKeyboardAction($0) }
        model.hotkeyMessage = keyboard.register()
        model.onChange = { [weak self] in
            self?.updateStatus()
            self?.applyPendingCommand()
        }
        model.onHUD = { [weak self] title, percent, symbol in
            guard let self, !self.panel.isShown else { return }
            self.hud.show(title: title, percent: percent, symbol: symbol, displayID: self.model.selectedDisplay?.id)
        }
        installScrollMonitor()
        retryMediaKeys()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.retryMediaKeys() }
        permissionTimer?.tolerance = 1
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged), name: NSWorkspace.screensDidWakeNotification, object: nil)
        model.discover()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.model.ready { self.discoveryInterval = 5 }
            if !self.model.ready && !self.model.isLoading {
                guard Date() >= self.nextDiscovery else { return }
                self.model.discover()
                self.nextDiscovery = Date().addingTimeInterval(self.discoveryInterval)
                self.discoveryInterval = min(60, self.discoveryInterval * 2)
            } else if self.panel.isShown && !self.model.hasPendingWrites {
                // Recovers hardware dimming once B.I.+ or HDR is turned off on the display.
                self.model.refresh(reconsiderBrightness: self.model.isAutoSoftwareFallback)
                self.model.displaySettings.refresh()
            }
        }
        refreshTimer?.tolerance = 1
        if CommandLine.arguments.contains("--show") || !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showPopover() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover(); return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = ControlCommand(url: url) else { continue }
            if command == .show { showPopover() }
            else { pendingCommand = command; applyPendingCommand() }
        }
    }
    private func applyPendingCommand() {
        guard !model.isLoading, model.selectedDisplay != nil, let command = pendingCommand else { return }
        pendingCommand = nil
        command.apply(to: model)
    }
    func applicationDidBecomeActive(_ notification: Notification) { retryMediaKeys() }
    func applicationWillTerminate(_ notification: Notification) { model.dimming.resetAll() }

    // MARK: Status item

    @objc func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showQuickMenu() }
        else { togglePopover() }
    }
    @objc func togglePopover() {
        panel.toggle(anchor: { [weak self] in self?.statusItem.button?.window?.frame })
    }
    func showPopover() {
        panel.show(anchor: { [weak self] in self?.statusItem.button?.window?.frame })
    }
    /// Right-click: one-step actions without opening the panel.
    private func showQuickMenu() {
        panel.close()
        statusItem.menu = quickMenu.make()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    private func openSettings() {
        showPopover()
        panel.state.go(.settings)
    }
    func updateStatus() {
        let percentage = model.ready ? model.controls[.brightness]?.value.map { Int($0.percent.rounded()) } : nil
        // The sun's disc is the gauge; with percentage on, the number sits inside it.
        // Redraw only when the glyph changes: this runs on every model update.
        let imageKey = model.showPercentage ? "n\(percentage.map(String.init) ?? "-")"
                                            : "g\(percentage == nil ? -1 : StatusIcon.litDots(for: percentage.map(Double.init)))"
        if imageKey != statusImageKey {
            statusImageKey = imageKey
            statusItem.button?.image = StatusIcon.image(percent: percentage.map(Double.init), showNumber: model.showPercentage)
        } else {
            statusItem.button?.image?.accessibilityDescription = percentage.map { L("亮度 %d%%", $0) } ?? L("显示器亮度")
        }
        statusItem.button?.title = ""
        statusItem.button?.appearsDisabled = !model.ready && !model.isLoading
        let name = model.selectedDisplay?.displayName ?? L("未连接显示器")
        statusItem.button?.toolTip = L("光控") + " · \(name)\(percentage.map { " · \($0)%" } ?? "")\n" + L("滚动调节亮度 · ⌃⌥B 打开面板")
    }
    /// Scrolling over the menu-bar icon adjusts brightness, like a volume knob.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window === button.window else { return event }
            let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            self.scrollAccumulator += event.hasPreciseScrollingDeltas ? delta / 12 : delta
            while abs(self.scrollAccumulator) >= 1 {
                let step: CGFloat = self.scrollAccumulator > 0 ? 1 : -1
                self.scrollAccumulator -= step
                self.model.adjust(.brightness, by: Double(step) * (event.modifierFlags.contains(.shift) ? 1 : 2))
            }
            if event.phase == .ended || event.momentumPhase == .ended { self.scrollAccumulator = 0 }
            return nil
        }
    }
    @objc func displaysChanged() {
        screenChange?.cancel()
        discoveryInterval = 5; nextDiscovery = .distantPast
        let work = DispatchWorkItem { [weak self] in self?.model.discover() }
        screenChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: Media keys

    func toggleMediaKeys() {
        let requested = !model.mediaKeysRequested
        UserDefaults.standard.set(requested, forKey: "useMediaKeys")
        if requested { reconnectMediaKeys() }
        else { keyboard.disableMediaKeys(); retryMediaKeys() }
    }
    func reconnectMediaKeys() {
        UserDefaults.standard.set(true, forKey: "useMediaKeys")
        keyboard.disableMediaKeys()
        _ = keyboard.enableMediaKeys(prompt: true)
        retryMediaKeys()
        if !keyboard.accessibilityTrusted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func retryMediaKeys() {
        let requested = UserDefaults.standard.object(forKey: "useMediaKeys") as? Bool != false
        let enabled = requested && keyboard.enableMediaKeys(prompt: false)
        model.updateKeyboardStatus(requested: requested, enabled: enabled,
                                   message: keyboard.mediaKeyMessage, diagnostics: keyboard.diagnostics)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Keep one installed identity for TCC and login items, even if a stale build
// is opened from Spotlight. Development launches can explicitly opt out.
let installedApp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MonitorLight.app")
if Bundle.main.bundleURL.standardizedFileURL != installedApp.standardizedFileURL,
   FileManager.default.fileExists(atPath: installedApp.path),
   !CommandLine.arguments.contains("--development") {
    NSWorkspace.shared.openApplication(at: installedApp, configuration: NSWorkspace.OpenConfiguration()) { _, _ in exit(0) }
    app.run()
    exit(0)
}
if let identifier = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
