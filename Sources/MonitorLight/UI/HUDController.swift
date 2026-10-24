import AppKit
import SwiftUI

private final class HUDState: ObservableObject {
    @Published var title = ""
    @Published var percent: Double = 0
    @Published var symbol = "sun.max.fill"
}

private struct HUDView: View {
    @ObservedObject var state: HUDState
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: state.symbol)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(state.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.14))
                        Capsule().fill(Color.primary.opacity(0.9))
                            .frame(width: max(5, geometry.size.width * min(100, max(0, state.percent)) / 100))
                    }
                }
                .frame(height: 5)
                .animation(Motion.snappy, value: state.percent)
            }
            Text("\(Int(state.percent.rounded()))")
                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText(value: state.percent))
                .animation(Motion.snappy, value: Int(state.percent.rounded()))
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(width: 260, height: 50)
    }
}

/// Glass indicator under the menu bar on the display being adjusted, in the
/// spot macOS uses for its own brightness and volume indicators.
final class HUDController {
    private let panel: NSPanel
    private let state = HUDState()
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 260, height: 50)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: HUDView(state: state))
        hosting.sizingOptions = []
        panel.contentView = PanelController.glass(around: hosting, cornerRadius: size.height / 2)
    }

    func show(title: String, percent: Double, symbol: String, displayID: UInt32?) {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID } ?? NSScreen.main
        guard let screen else { return }
        state.title = title; state.symbol = symbol; state.percent = percent
        let visible = screen.visibleFrame
        let target = NSRect(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 10,
                            width: size.width, height: size.height)
        let appearing = !panel.isVisible || panel.alphaValue < 1
        if !panel.isVisible || panel.screen != screen {
            panel.setFrame(target.offsetBy(dx: 0, dy: Motion.reduced ? 0 : 12), display: false)
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        if appearing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self.panel.animator().alphaValue = 0
                self.panel.animator().setFrame(target.offsetBy(dx: 0, dy: Motion.reduced ? 0 : 8), display: true)
            }) { [weak self] in
                if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
