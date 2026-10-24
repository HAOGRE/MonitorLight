import AppKit
import SwiftUI

/// Renders README / blog screenshots from the real SwiftUI views: panels on a
/// soft wallpaper with the panel's rounded corners and shadow, plus the menu
/// bar icon in both styles. Run through scripts/screenshots.sh once per
/// language so Localizable.strings apply.
private final class ShotDDC: DDCProviding {
    func perform(_ arguments: [String], completion: @escaping (Result<Data, Error>) -> Void) {
        let values = ["picture-mode": ["current": 531, "maximum": 1043],
                      "sharpness": ["current": 5, "maximum": 10],
                      "response-time": ["current": 1, "maximum": 2],
                      "aspect-ratio": ["current": 2, "maximum": 5]]
        completion(.success(try! JSONSerialization.data(withJSONObject: values)))
    }
}

private func panelImage(_ model: MonitorModel, page: PanelPage, dark: Bool) -> NSImage {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    NSApp.appearance = appearance
    let state = PanelState()
    state.page = page
    let view = NSHostingView(rootView: PanelView(model: model, state: state)
        .background(dark ? Color(white: 0.15) : Color(white: 0.965)))
    view.appearance = appearance
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(rep)
    return image
}

/// Draws panels side by side on a gradient wallpaper.
private func compose(_ panels: [NSImage], dark: Bool, padding: CGFloat = 56, gap: CGFloat = 40) -> NSImage {
    let width = panels.reduce(0) { $0 + $1.size.width } + gap * CGFloat(panels.count - 1) + padding * 2
    let height = (panels.map(\.size.height).max() ?? 0) + padding * 2
    let canvas = NSImage(size: NSSize(width: width, height: height))
    canvas.lockFocus()
    let colors: [NSColor] = dark
        ? [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.24, alpha: 1), NSColor(calibratedRed: 0.28, green: 0.16, blue: 0.36, alpha: 1)]
        : [NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.86, green: 0.74, blue: 0.96, alpha: 1)]
    NSGradient(colors: colors)!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -35)
    var x = padding
    for panel in panels {
        let rect = NSRect(x: x, y: height - padding - panel.size.height, width: panel.size.width, height: panel.size.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.25)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.965, alpha: 1)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        panel.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(dark ? 0.12 : 0.6).setStroke()
        path.lineWidth = 1
        path.stroke()
        x += panel.size.width + gap
    }
    canvas.unlockFocus()
    return canvas
}

/// Menu bar strips showing the gauge and the percentage style at several levels.
private func menuBarIcons() -> NSImage {
    let levels: [Double] = [25, 50, 75, 100]
    let cell: CGFloat = 92, rowHeight: CGFloat = 56, label: CGFloat = 0
    let width = label + cell * CGFloat(levels.count * 2) + 40
    let canvas = NSImage(size: NSSize(width: width, height: rowHeight * 2 + 24))
    canvas.lockFocus()
    for (row, dark) in [false, true].enumerated() {
        let y = CGFloat(1 - row) * (rowHeight + 8) + 8
        let strip = NSRect(x: 8, y: y, width: width - 16, height: rowHeight)
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSBezierPath(roundedRect: strip, xRadius: 12, yRadius: 12).fill()
        let tint: NSColor = dark ? .white : .black
        for (index, (number, level)) in (levels.map { (false, $0) } + levels.map { (true, $0) }).enumerated() {
            let icon = StatusIcon.image(percent: level, showNumber: number)
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                tint.withAlphaComponent(0.88).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let x = 20 + label + CGFloat(index) * cell + (index >= levels.count ? 24 : 0)
            tinted.draw(in: NSRect(x: x + 22, y: y + 10, width: 36, height: 36))
        }
    }
    canvas.unlockFocus()
    return canvas
}

private func save(_ image: NSImage, _ name: String) throws {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let url = URL(fileURLWithPath: "docs/images/\(name).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    print(url.path, Int(image.size.width), "×", Int(image.size.height))
}

@main struct Screenshots {
    static func main() throws {
        _ = NSApplication.shared
        let language = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh" : "en"
        let model = MonitorModel(client: ShotDDC(), writesDiagnostics: false)
        model.displays = [DisplayInfo(id: 2, uuid: "shot", name: "BenQ EW3270U", ddc: true)]
        model.selectedUUID = "shot"
        model.controls = [.brightness: ControlState(value: DDCValue(current: 60, maximum: 100)),
                          .volume: ControlState(value: DDCValue(current: 40, maximum: 100))]
        model.displaySettings.configure(display: model.selectedDisplay)
        model.mediaKeysRequested = true
        model.mediaKeysEnabled = true
        model.showPercentage = true

        try save(compose([panelImage(model, page: .main, dark: false), panelImage(model, page: .main, dark: true)], dark: false), "panel-\(language)")
        try save(compose([panelImage(model, page: .picture, dark: true), panelImage(model, page: .settings, dark: true)], dark: true), "pages-\(language)")
        if language == "en" { try save(menuBarIcons(), "menu-bar-icons") }
    }
}
