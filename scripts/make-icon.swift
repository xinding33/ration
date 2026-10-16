import AppKit

// Draws Ration's app icon: the menu bar icon's two rings on a rounded square.
let output = CommandLine.arguments[1]
let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }

func ring(center: NSPoint, radius: CGFloat, width: CGFloat, fraction: CGFloat, color: NSColor) {
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width
    NSColor.white.withAlphaComponent(0.18).setStroke()
    track.stroke()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
    arc.lineWidth = width
    arc.lineCapStyle = .round
    color.setStroke()
    arc.stroke()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: side * 0.05, y: side * 0.05, width: side * 0.9, height: side * 0.9),
                     xRadius: side * 0.2, yRadius: side * 0.2).fill()
        let center = NSPoint(x: side / 2, y: side / 2)
        ring(center: center, radius: side * 0.29, width: side * 0.085, fraction: 0.62,
             color: NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.24, alpha: 1))
        ring(center: center, radius: side * 0.15, width: side * 0.085, fraction: 0.35, color: .white)
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", folder.path, "-o", output]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
