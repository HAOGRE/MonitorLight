import AppKit
import CoreText

/// Menu-bar glyph, modelled on the iPhone status bar trio (signal, Wi-Fi,
/// battery): one stroke weight, rounded ends, the same 18pt footprint.
/// A number and a gauge never appear together.
/// - Gauge (default): a hollow sun disc ringed by 12 dots. Lit dots run
///   clockwise from 12 o'clock (full ring = 100%); unlit dots stay at low
///   opacity, as unreached signal bars do, so the ring keeps its shape.
/// - Percentage: only the number, inside a full-size hollow ring with no
///   rays, so the digits get the most room (iOS 16.1 enlarged the battery
///   digits after 16.0's small ones proved hard to read).
/// Drawn as a template image so the menu bar tints it for every appearance.
enum StatusIcon {
    static let dotCount = 12

    /// Number of lit dots for a brightness level (any non-zero level lights one).
    static func litDots(for percent: Double?) -> Int {
        guard let percent else { return 0 }
        let level = min(100, max(0, percent)) / 100
        return level > 0 ? max(1, Int((level * Double(dotCount)).rounded())) : 0
    }

    static func image(percent: Double?, showNumber: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if showNumber { drawNumber(in: rect, context: context, percent: percent) }
            else { drawGauge(in: rect, context: context, percent: percent) }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = percent.map { L("亮度 %d%%", Int($0.rounded())) } ?? L("显示器亮度")
        return image
    }

    private static func drawGauge(in rect: NSRect, context: CGContext, percent: Double?) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let lit = litDots(for: percent)
        for index in 0..<dotCount {
            let angle = .pi / 2 - CGFloat(index) * 2 * .pi / CGFloat(dotCount)
            let dot = CGPoint(x: center.x + cos(angle) * 7.95, y: center.y + sin(angle) * 7.95)
            context.setFillColor(NSColor.black.withAlphaComponent(index < lit ? 1 : 0.25).cgColor)
            context.fillEllipse(in: CGRect(x: dot.x - 0.95, y: dot.y - 0.95, width: 1.9, height: 1.9))
        }
        // Hollow disc: outer radius 5.4 with a 1.5pt stroke, the shared weight.
        context.setStrokeColor(NSColor.black.withAlphaComponent(percent == nil ? 0.45 : 1).cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: CGRect(x: center.x - 4.65, y: center.y - 4.65, width: 9.3, height: 9.3))
    }

    private static func drawNumber(in rect: NSRect, context: CGContext, percent: Double?) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let color = NSColor.black.withAlphaComponent(percent == nil ? 0.45 : 1)
        // Full-size hollow ring (outer radius 8.25, the shared 1.5pt weight).
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: CGRect(x: center.x - 7.5, y: center.y - 7.5, width: 15, height: 15))

        let text = percent.map { "\(Int(min(100, max(0, $0)).rounded()))" } ?? "–"
        let three = text.count >= 3
        let base = NSFont.systemFont(ofSize: three ? 6.0 : 8.0, weight: .bold)
        let rounded = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
        let font = rounded.withWidth(three ? -0.3 : 0)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        // Centre the glyphs' actual ink so digits sit optically centred in the ring.
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: center.x - ink.midX, y: center.y - ink.midY)
        CTLineDraw(line, context)
    }
}

private extension NSFont {
    /// Slightly condensed variant so "100" fits inside the disc.
    func withWidth(_ width: CGFloat) -> NSFont {
        guard width != 0 else { return self }
        let descriptor = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: width,
                                                                   NSFontDescriptor.TraitKey.weight: NSFont.Weight.bold]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
