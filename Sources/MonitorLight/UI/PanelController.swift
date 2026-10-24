import AppKit
import SwiftUI

enum PanelPage: Equatable { case main, picture, settings }

/// Navigation state shared by the SwiftUI pages and keyboard handling.
final class PanelState: ObservableObject {
    @Published var page: PanelPage = .main
    func go(_ page: PanelPage) {
        guard page != self.page else { return }
        withAnimation(Motion.page) { self.page = page }
    }
}

/// Borderless, non-activating panel so the frontmost app keeps focus while
/// the panel still receives keys, as Spotlight does.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Glass panel anchored under the status item. It replaces NSPopover: there's
/// no arrow, height changes animate, and it dismisses on outside clicks and Esc.
final class PanelController: NSObject, NSWindowDelegate {
    let state = PanelState()
    private let panel: FloatingPanel
    private let model: MonitorModel
    private var anchor: (() -> NSRect?)?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var contentHeight: CGFloat = 300
    private var menuTracking = false
    private let width: CGFloat = 296
    private let cornerRadius: CGFloat = 22
    var isShown: Bool { panel.isVisible && panel.alphaValue > 0 }
    var onShow: (() -> Void)?
    var quit: () -> Void = { NSApp.terminate(nil) }

    init(model: MonitorModel, actions: PanelActions) {
        self.model = model
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 296, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.delegate = self

        let root = PanelView(model: model, state: state, actions: actions) { [weak self] height in
            self?.contentHeightChanged(height)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = Self.glass(around: hosting, cornerRadius: cornerRadius)
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = true
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = false
            if self?.isShown == true { self?.panel.makeKey() }
        }
    }

    /// Liquid Glass on macOS 26+, falling back to the popover material.
    static func glass(around content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }

    // MARK: Show / hide

    func toggle(anchor: @escaping () -> NSRect?) {
        isShown ? close() : show(anchor: anchor)
    }
    func show(anchor: @escaping () -> NSRect?) {
        self.anchor = anchor
        guard !isShown else { panel.makeKey(); return }
        state.page = .main
        onShow?()
        let target = frame(height: contentHeight)
        let offset: CGFloat = Motion.reduced ? 0 : 6
        panel.setFrame(target.offsetBy(dx: 0, dy: offset), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        installMonitors()
    }
    func close() {
        guard panel.isVisible else { return }
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }) { [weak self] in
            guard let self, self.panel.alphaValue == 0 else { return }
            self.panel.orderOut(nil)
            self.state.page = .main
        }
    }
    func windowDidResignKey(_ notification: Notification) {
        // Menus opened from the panel (display picker) take key briefly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isShown, !self.panel.isKeyWindow, !self.menuTracking else { return }
            self.close()
        }
    }

    // MARK: Layout

    private func frame(height: CGFloat) -> NSRect {
        let anchorRect = anchor?() ?? NSRect(x: (NSScreen.main?.frame.midX ?? 600), y: (NSScreen.main?.visibleFrame.maxY ?? 800), width: 0, height: 0)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchorRect.midX, y: anchorRect.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clampedHeight = min(height, visible.height - 16).rounded()
        var x = anchorRect.midX - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let top = min(anchorRect.minY - 6, visible.maxY - 6).rounded()
        return NSRect(x: x.rounded(), y: top - clampedHeight, width: width, height: clampedHeight)
    }
    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        guard panel.isVisible else { return }
        let target = frame(height: height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reduced ? 0 : 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: Events

    private func installMonitors() {
        removeMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Clicks on the status item toggle the panel through its own action.
            guard let self, self.anchor?()?.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) != true else { return }
            self.close()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }
    private func removeMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideMonitor = nil; keyMonitor = nil
    }
    /// Keyboard-first control: arrows adjust, digits pick presets, Esc steps back.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let step: Double = flags.contains(.shift) ? 1 : 5
        // Key codes, not characters, so Chinese input methods (，) still work.
        if flags.contains(.command) {
            switch event.keyCode {
            case 12: quit(); return true                  // Q
            case 43: state.go(.settings); return true     // ,
            case 13: close(); return true                 // W
            case 15: model.discover(); return true        // R
            default: return false
            }
        }
        guard flags.subtracting(.shift).isEmpty else { return false }
        switch event.keyCode {
        case 53: // esc
            if state.page == .main { close() } else { state.go(.main) }
            return true
        case 126: model.adjust(.brightness, by: step); return true
        case 125: model.adjust(.brightness, by: -step); return true
        case 124: model.adjust(.volume, by: step); return true
        case 123: model.adjust(.volume, by: -step); return true
        case 18, 83: model.set(.brightness, percent: PanelView.presets[0].value); return true  // 1
        case 19, 84: model.set(.brightness, percent: PanelView.presets[1].value); return true  // 2
        case 20, 85: model.set(.brightness, percent: PanelView.presets[2].value); return true  // 3
        case 46: model.toggleMute(); return true                                               // M
        case 35:                                                                               // P
            guard model.displaySettings.supported else { return false }
            state.go(state.page == .picture ? .main : .picture); return true
        case 43: state.go(state.page == .settings ? .main : .settings); return true           // ,
        default: return false
        }
    }
}
