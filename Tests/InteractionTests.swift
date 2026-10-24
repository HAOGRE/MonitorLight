import AppKit
import SwiftUI

/// Drives the real GlassSlider with real NSEvents inside a real window, and
/// builds/performs the real status-item quick menu. Synthetic HID events from
/// other processes are blocked by macOS, so this is how pointer behaviour is
/// verified automatically.
private final class Box: ObservableObject {
    @Published var value: Double = 40
    var changes: [Double] = []
}

private struct Harness: View {
    @ObservedObject var box: Box
    var body: some View {
        GlassSlider(value: box.value, symbol: "sun.max.fill", label: "亮度", detents: [35, 60, 85]) {
            box.changes.append($0)
            box.value = $0
        }
        .frame(width: 292, height: 30)
    }
}

private final class RecordingDDC: DDCProviding {
    var calls: [[String]] = []
    func perform(_ arguments: [String], completion: @escaping (Result<Data, Error>) -> Void) { calls.append(arguments) }
}

/// Runs the AppKit event loop for a moment, dispatching queued events as NSApplication.run does.
private func pump(_ seconds: TimeInterval = 0.05) {
    let deadline = Date().addingTimeInterval(seconds)
    while let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
    }
}

private func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAILED: \(message)"); exit(1) }
}

@main struct InteractionTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let box = Box()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 292, height: 30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Harness(box: box))
        window.orderFrontRegardless()
        window.makeKey()
        pump(0.3)

        var time = ProcessInfo.processInfo.systemUptime
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) {
            time += 0.016
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 15), modifierFlags: [],
                                           timestamp: time, windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            window.sendEvent(event)
            pump(0.02)
        }
        func scroll(lines: Int32) {
            // Synthetic wheel events can't be positioned in-process (AppKit places
            // them at the real cursor), so deliver the real NSEvent straight to the
            // slider's scroll catcher, the view hitTest selects for scroll events.
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
            func catcher(in view: NSView) -> NSView? {
                if view is ScrollCatcher.CatcherView { return view }
                return view.subviews.lazy.compactMap(catcher).first
            }
            catcher(in: window.contentView!)!.scrollWheel(with: NSEvent(cgEvent: cg)!)
            pump(0.05)
        }

        // 1. Click without movement jumps: x = cap/2 + 131 → 50%.
        mouse(.leftMouseDown, 146); mouse(.leftMouseUp, 146)
        check(abs(box.value - 50) < 0.5, "click should jump to 50, got \(box.value)")

        // 2. Grabbing far from the fill edge must not jump while pressed.
        box.changes.removeAll()
        mouse(.leftMouseDown, 40)
        check(box.changes.isEmpty, "mouse down alone should not change the value, got \(box.changes)")
        // 3. Relative drag: +65.5pt of 262pt travel = +25%.
        for step in 1...10 { mouse(.leftMouseDragged, 40 + 6.55 * CGFloat(step)) }
        mouse(.leftMouseUp, 105.5)
        check(abs(box.value - 75) < 0.6, "relative drag should reach 75, got \(box.value)")
        check(box.changes.count >= 5, "drag should update continuously, got \(box.changes.count) updates")
        check(zip(box.changes, box.changes.dropFirst()).allSatisfy { $0 <= $1 }, "drag updates should be monotonic")

        // 4. Dragging past the end clamps.
        mouse(.leftMouseDown, 200)
        for step in 1...8 { mouse(.leftMouseDragged, 200 + 40 * CGFloat(step)) }
        mouse(.leftMouseUp, 520)
        check(box.value == 100, "drag past end should clamp to 100, got \(box.value)")

        // 5. Mouse wheel: real line-based wheel events into the slider.
        // One notch down → −2%, routed through the scroll catcher.
        scroll(lines: -1)
        check(box.value == 98, "wheel notch down should give 98, got \(box.value)")
        scroll(lines: 1)
        check(box.value == 100, "wheel notch up should restore 100, got \(box.value)")
        print("Interaction tests passed: click-to-jump, no jump on grab, relative drag, clamping, mouse wheel")

        // 6. Quick menu: real NSMenu items, state and actions.
        let ddc = RecordingDDC()
        let model = MonitorModel(client: ddc, writesDiagnostics: false)
        model.displays = [DisplayInfo(id: 1, uuid: "menu", name: "Test", ddc: true)]
        model.selectedUUID = "menu"
        model.controls = [.brightness: ControlState(value: DDCValue(current: 60, maximum: 100)),
                          .volume: ControlState(value: DDCValue(current: 40, maximum: 100))]
        var settingsOpened = false
        let quick = QuickMenu(model: model) { settingsOpened = true }
        let menu = quick.make()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        check(titles == ["柔和  35%", "日常  60%", "明亮  85%", "静音", "显示百分比", "设置…", "退出光控"], "menu titles \(titles)")
        check(menu.items[1].state == .on && menu.items[0].state == .off, "current preset should be checked")
        check(menu.items.allSatisfy { $0.isSeparatorItem || $0.isEnabled }, "items should be enabled when ready")
        menu.performActionForItem(at: 0)
        pump(0.2)
        check(ddc.calls.last == ["set", "menu", "brightness", "35"], "preset item should write 35, got \(ddc.calls)")
        menu.performActionForItem(at: menu.items.firstIndex { $0.title == "设置…" }!)
        check(settingsOpened, "settings item should open settings")
        let disconnected = MonitorModel(client: RecordingDDC(), writesDiagnostics: false)
        let offline = QuickMenu(model: disconnected) {}.make()
        check(!offline.items[0].isEnabled && offline.items.first { $0.title == "静音" }?.isEnabled == false,
              "presets and mute should be disabled without a display")
        check(StatusIcon.litDots(for: nil) == 0 && StatusIcon.litDots(for: 0) == 0, "no dots without brightness")
        check(StatusIcon.litDots(for: 1) == 1, "any non-zero level lights a dot")
        check(StatusIcon.litDots(for: 50) == 6 && StatusIcon.litDots(for: 100) == 12, "half ring at 50, full ring at 100")
        check(StatusIcon.litDots(for: 25) == 3 && StatusIcon.litDots(for: 150) == 12, "quarter ring at 25; clamped above 100")
        let icon = StatusIcon.image(percent: 42, showNumber: true)
        check(icon.isTemplate && icon.size == NSSize(width: 18, height: 18), "menu bar icon is an 18pt template image")
        let toggle = menu.items.first { $0.title == "显示百分比" }!
        check(toggle.state == .off, "percentage item reflects the setting")
        let before = model.showPercentage
        menu.performActionForItem(at: menu.index(of: toggle))
        check(model.showPercentage != before, "percentage item toggles the setting")
        model.togglePercentage() // restore the user's preference
        print("Status icon tests passed: dot ring maps 0/1/25/50/100%, template sizing, percentage toggle in quick menu")
        print("Quick menu tests passed: titles, checked preset, enable state, preset write, settings action")
    }
}
