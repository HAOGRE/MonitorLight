import AppKit
import SwiftUI

private final class PreviewDDC: DDCProviding {
    func perform(_ arguments: [String], completion: @escaping (Result<Data, Error>) -> Void) {
        let values = ["picture-mode": ["current": 531, "maximum": 1043],
                      "sharpness": ["current": 5, "maximum": 10],
                      "response-time": ["current": 1, "maximum": 2],
                      "aspect-ratio": ["current": 2, "maximum": 5]]
        completion(.success(try! JSONSerialization.data(withJSONObject: values)))
    }
}

/// Renders every panel page on the real glass/material background so the
/// layout can be reviewed without opening the menu bar app.
/// Contact sheet of the menu-bar icon: gauge and numbered modes at several
/// levels, tinted like a template image on light and dark menu bars, shown at
/// real size (left of each cell) and enlarged 4× (right).
private func renderStatusIcons() throws {
    let levels: [Double?] = [nil, 0, 8, 25, 50, 75, 100]
    let cell = NSSize(width: 110, height: 84)
    let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(levels.count), height: cell.height * 4))
    sheet.lockFocus()
    for (row, (number, dark)) in [(false, false), (false, true), (true, false), (true, true)].enumerated() {
        let y = CGFloat(3 - row) * cell.height
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(x: 0, y: y, width: sheet.size.width, height: cell.height).fill()
        for (column, level) in levels.enumerated() {
            let icon = StatusIcon.image(percent: level, showNumber: number)
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.85).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let x = CGFloat(column) * cell.width
            tinted.draw(in: NSRect(x: x + 8, y: y + 33, width: 18, height: 18))
            tinted.draw(in: NSRect(x: x + 34, y: y + 6, width: 72, height: 72))
            let label = level.map { "\(Int($0))%" } ?? "—"
            NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: dark ? NSColor.lightGray : NSColor.darkGray]).draw(at: NSPoint(x: x + 8, y: y + 8))
        }
    }
    sheet.unlockFocus()
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/preview-status-icons.png"))
    print("build/preview-status-icons.png")
}

@main struct RenderPreview {
    static func main() throws {
        _ = NSApplication.shared
        try renderStatusIcons()
        let model = MonitorModel(client: PreviewDDC(), writesDiagnostics: false)
        model.displays = [DisplayInfo(id: 2, uuid: "preview", name: "BenQ EW3270U", ddc: true)]
        model.selectedUUID = "preview"
        model.controls = [.brightness: ControlState(value: DDCValue(current: 60, maximum: 100)),
                          .volume: ControlState(value: DDCValue(current: 40, maximum: 100))]
        model.displaySettings.configure(display: model.selectedDisplay)
        model.mediaKeysRequested = true
        model.mediaKeysEnabled = true
        let empty = MonitorModel(client: PreviewDDC(), writesDiagnostics: false)

        let cases: [(String, MonitorModel, PanelPage, Bool)] = [
            ("main", model, .main, false), ("main-dark", model, .main, true),
            ("picture", model, .picture, false), ("picture-dark", model, .picture, true),
            ("settings", model, .settings, false), ("empty-dark", empty, .main, true)
        ]
        for (name, subject, page, dark) in cases {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            let state = PanelState()
            state.page = page
            let content = NSHostingView(rootView: PanelView(model: subject, state: state)
                .background(dark ? Color(white: 0.17) : Color(white: 0.93)))
            content.appearance = appearance
            let size = content.fittingSize
            content.frame = NSRect(origin: .zero, size: size)
            content.layoutSubtreeIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fatalError("Unable to render") }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let language = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "" : "-en"
            let path = "build/preview-\(name)\(language).png"
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            print("\(path): \(Int(size.width)) × \(Int(size.height)) pt")
        }
    }
}
