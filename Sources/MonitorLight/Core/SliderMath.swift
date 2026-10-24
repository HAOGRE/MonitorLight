import CoreGraphics

/// Pure geometry behind the panel sliders, kept separate so drag, click,
/// detent and scroll behaviour are unit-tested without a window.
enum SliderMath {
    static func clamp(_ value: Double) -> Double { min(100, max(0, value)) }

    /// Relative drag: the value moves with the pointer from where it was grabbed.
    /// The travel excludes the always-visible symbol cap at the leading end.
    static func dragValue(start: Double, translation: CGFloat, width: CGFloat, cap: CGFloat) -> Double {
        guard width > cap else { return clamp(start) }
        return clamp(start + Double(translation / (width - cap)) * 100)
    }

    /// A click without movement jumps so the fill's edge lands under the pointer.
    static func clickValue(x: CGFloat, width: CGFloat, cap: CGFloat) -> Double {
        guard width > cap else { return 0 }
        return clamp(Double((x - cap / 2) / (width - cap)) * 100)
    }

    static func fillWidth(value: Double, width: CGFloat, cap: CGFloat) -> CGFloat {
        cap + max(0, width - cap) * CGFloat(clamp(value)) / 100
    }

    /// True when a move from `old` to `new` reaches or passes a detent (0, 100 and presets).
    static func crossesDetent(from old: Double, to new: Double, detents: [Double]) -> Bool {
        ([0, 100] + detents).contains { (old < $0 && new >= $0) || (old > $0 && new <= $0) }
    }

    /// Converts wheel/trackpad deltas into whole-percent steps. Up or right
    /// (as the fingers move) always increases, regardless of natural scrolling.
    struct ScrollAccumulator {
        private(set) var remainder: CGFloat = 0
        mutating func add(deltaX: CGFloat, deltaY: CGFloat, inverted: Bool, precise: Bool) -> Double {
            let raw = abs(deltaY) >= abs(deltaX) ? deltaY : -deltaX
            let delta = inverted ? -raw : raw
            remainder += precise ? delta / 4 : delta * 2
            let whole = remainder.rounded(.towardZero)
            remainder -= whole
            return Double(whole)
        }
        mutating func reset() { remainder = 0 }
    }
}
