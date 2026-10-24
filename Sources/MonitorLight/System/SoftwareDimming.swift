import AppKit

protocol SoftwareDimmingProviding {
    func set(displayID: UInt32, percent: Double) -> Bool
    func remove(displayID: UInt32)
    func reconcile()
    func resetAll()
    func diagnostics() -> [[String: Any]]
}

/// A click-through shade is independent of ColorSync and Night Shift. Windows
/// disappear even after a crash, so it cannot leave a persistent black screen.
final class SoftwareDimming: SoftwareDimmingProviding {
    private var windows: [UInt32: NSWindow] = [:]
    private var levels: [UInt32: Double] = [:]
    func set(displayID: UInt32, percent: Double) -> Bool {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
        }) else { return false }
        let bounded = min(100, max(0, percent))
        levels[displayID] = bounded
        if bounded >= 100 { windows.removeValue(forKey: displayID)?.orderOut(nil); return true }
        let window: NSWindow
        if let existing = windows[displayID] { window = existing }
        else {
            window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .black
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.setAccessibilityElement(false)
            windows[displayID] = window
        }
        window.setFrame(screen.frame, display: true)
        window.alphaValue = (1 - bounded / 100) * 0.85
        window.orderFrontRegardless()
        return true
    }
    func remove(displayID: UInt32) {
        windows.removeValue(forKey: displayID)?.orderOut(nil)
        levels.removeValue(forKey: displayID)
    }
    func reconcile() {
        let online = Set(NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 })
        for id in Array(levels.keys) {
            if !online.contains(id) { remove(displayID: id) }
            else if let percent = levels[id] { _ = set(displayID: id, percent: percent) }
        }
    }
    func resetAll() { for id in Array(levels.keys) { remove(displayID: id) } }
    func diagnostics() -> [[String: Any]] {
        levels.map { ["displayID": $0.key, "percent": $0.value,
                      "opacity": windows[$0.key]?.alphaValue ?? 0,
                      "visible": windows[$0.key]?.isVisible ?? false] }
    }
}
