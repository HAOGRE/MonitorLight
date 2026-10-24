import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.85, alpha: 1),
                   ending: NSColor(calibratedRed: 0.27, green: 0.68, blue: 0.96, alpha: 1))!.draw(in: background, angle: 60)
        NSColor.white.withAlphaComponent(0.94).setStroke()
        let monitor = NSBezierPath(roundedRect: NSRect(x: 205, y: 290, width: 614, height: 430), xRadius: 50, yRadius: 50)
        monitor.lineWidth = 34; monitor.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 512, y: 290)); stand.line(to: NSPoint(x: 512, y: 204))
        stand.move(to: NSPoint(x: 395, y: 204)); stand.line(to: NSPoint(x: 629, y: 204))
        stand.lineWidth = 34; stand.lineCapStyle = .round; stand.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 447, y: 440, width: 130, height: 130)).fill()
        let rays = NSBezierPath()
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            rays.move(to: NSPoint(x: 512 + cos(angle) * 104, y: 505 + sin(angle) * 104))
            rays.line(to: NSPoint(x: 512 + cos(angle) * 137, y: 505 + sin(angle) * 137))
        }
        rays.lineWidth = 20; rays.lineCapStyle = .round; rays.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
