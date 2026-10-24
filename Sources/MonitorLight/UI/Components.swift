import AppKit
import SwiftUI

// MARK: - Motion

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var snappy: Animation? { reduced ? nil : .snappy(duration: 0.24) }
    static var page: Animation? { reduced ? nil : .spring(response: 0.34, dampingFraction: 0.88) }
    static func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

// MARK: - Slider

/// Control Center–style slider.
/// Drags are relative (no jump on grab), a click without movement jumps,
/// scrolling adjusts, and preset values give a haptic detent.
struct GlassSlider: View {
    let value: Double
    let symbol: String
    var variableValue: Double?
    let label: String
    var enabled = true
    var detents: [Double] = []
    let onChange: (Double) -> Void

    @State private var dragStart: Double?
    @State private var moved = false
    @State private var hovering = false
    private let height: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clamped = SliderMath.clamp(value)
            let fill = SliderMath.fillWidth(value: clamped, width: width, cap: height)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(hovering && enabled ? 0.13 : 0.1))
                Capsule()
                    .fill(Color.white.opacity(enabled ? 1 : 0.55))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                    .frame(width: fill)
                symbolView
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(enabled ? 0.62 : 0.3))
                    .frame(width: height, height: height)
            }
            .animation(dragStart == nil ? Motion.snappy : nil, value: clamped)
            .contentShape(Capsule())
            .gesture(drag(width: width))
            .overlay(ScrollCatcher { delta in
                guard enabled else { return }
                onChange(SliderMath.clamp(value + delta))
            })
        }
        .frame(height: height)
        .onHover { hovering = $0 }
        // Expose a native AXSlider (role, value, increment/decrement) to VoiceOver.
        .accessibilityRepresentation {
            Slider(value: Binding(get: { SliderMath.clamp(value) }, set: { onChange($0) }), in: 0...100, step: 5) {
                Text(label)
            }
            .disabled(!enabled)
            .accessibilityValue(enabled ? "\(Int(value.rounded()))%" : L("不可用"))
        }
    }

    @ViewBuilder private var symbolView: some View {
        if let variableValue {
            Image(systemName: symbol, variableValue: variableValue)
        } else {
            Image(systemName: symbol).contentTransition(.symbolEffect(.replace))
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard enabled, width > height else { return }
                if dragStart == nil { dragStart = value; moved = false }
                if abs(gesture.translation.width) > 2 { moved = true }
                guard moved, let start = dragStart else { return }
                let next = SliderMath.dragValue(start: start, translation: gesture.translation.width, width: width, cap: height)
                if SliderMath.crossesDetent(from: value, to: next, detents: detents) { Motion.haptic() }
                onChange(next)
            }
            .onEnded { gesture in
                defer { dragStart = nil; moved = false }
                guard enabled, !moved, width > height else { return }
                onChange(SliderMath.clickValue(x: gesture.location.x, width: width, cap: height))
            }
    }
}

/// Transparent overlay that only claims scroll events, so clicks and drags
/// still reach the SwiftUI gesture underneath.
struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (Double) -> Void
    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((Double) -> Void)?
        private var accumulator = SliderMath.ScrollAccumulator()
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }
        override func scrollWheel(with event: NSEvent) {
            if event.phase == .began { accumulator.reset() }
            let steps = accumulator.add(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                        inverted: event.isDirectionInvertedFromDevice, precise: event.hasPreciseScrollingDeltas)
            if steps != 0 { onScroll?(steps) }
        }
    }
}

// MARK: - Containers

/// A grouped module, like the tiles in Control Center.
struct Module<Content: View>: View {
    var padding: CGFloat = 14
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
    }
}

struct ModuleHeader<Trailing: View>: View {
    let title: String
    var badge: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            trailing
        }
    }
}

/// Rolling percentage readout.
struct PercentText: View {
    let value: Double?
    var size: CGFloat = 13
    var body: some View {
        Group {
            if let value {
                let rounded = Int(value.rounded())
                (Text("\(rounded)") + Text("%").font(.system(size: size * 0.78, weight: .medium, design: .rounded)))
                    .contentTransition(.numericText(value: Double(rounded)))
                    .animation(Motion.snappy, value: rounded)
            } else {
                Text("—")
            }
        }
        .font(.system(size: size, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

// MARK: - Buttons

/// Circular icon button with a hover plate, like toolbar buttons in Tahoe.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    var active = false
    var plated = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(active ? Color.white : (hovering ? Color.primary : Color.secondary))
                .frame(width: size, height: size)
                .background(Circle().fill(active ? AnyShapeStyle(Color.accentColor.gradient)
                                         : AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : (plated ? 0.08 : 0)))))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Subtle scale on press shared by custom buttons.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Selectable tile with an SF Symbol and a caption.
struct Tile: View {
    let title: String
    let symbol: String
    var selected = false
    var compact = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 3 : 5) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 13 : 15, weight: .medium))
                    .frame(height: compact ? 16 : 19)
                Text(title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 7 : 10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor.gradient)
                               : AnyShapeStyle(Color.primary.opacity(hovering ? 0.1 : 0.06))))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: selected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Small capsule chip used for brightness presets.
struct Chip: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentColor.gradient)
                                                : AnyShapeStyle(Color.primary.opacity(hovering ? 0.1 : 0.06))))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Segmented control with a sliding selection pill.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let selection: Value?
    let onSelect: (Value) -> Void
    @Namespace private var namespace
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { if !selected { onSelect(option.value) } } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
                                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .animation(Motion.snappy, value: selection)
    }
}

/// Keyboard key rendering for shortcut lists and hints.
struct Keycap: View {
    let key: String
    var subtle = false
    var body: some View {
        Text(key)
            .font(.system(size: subtle ? 9 : 10, weight: .semibold, design: .rounded))
            .foregroundStyle(subtle ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .lineLimit(1).fixedSize()
            .frame(minWidth: subtle ? 12 : 16)
            .padding(.horizontal, subtle ? 3 : 4).padding(.vertical, subtle ? 1 : 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(subtle ? 0.05 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(subtle ? 0 : 0.08)))
    }
}

struct KeyHint: View {
    let keys: [String]
    let title: String
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { Keycap(key: $0, subtle: true) }
            Text(title).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 1)
                .lineLimit(1).fixedSize()
        }
    }
}

/// Header used by drill-in pages.
struct PageHeader: View {
    let title: String
    let back: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", help: L("返回（Esc）"), action: back)
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.leading, -4)
    }
}
