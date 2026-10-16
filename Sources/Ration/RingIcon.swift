import AppKit
import RationCore

/// The menu bar icon: Claude's tightest window as the outer ring and ChatGPT's as the inner one.
/// A ring turns orange at 80%. A service that isn't tracked leaves the other as a single ring;
/// one with no numbers yet shows an empty track.
enum RingIcon {
    struct Ring {
        let percent: Double?
    }

    static let size = NSSize(width: 18, height: 18)

    static func image(outer: Ring?, inner: Ring?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            switch (outer, inner) {
            case let (outer?, inner?):
                draw(outer, center: center, radius: 7.2, width: 2.2)
                draw(inner, center: center, radius: 3.5, width: 2.2)
            case let (ring?, nil), let (nil, ring?):
                draw(ring, center: center, radius: 6.4, width: 2.6)
            case (nil, nil):
                draw(Ring(percent: nil), center: center, radius: 6.4, width: 2.6)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ ring: Ring, center: NSPoint, radius: CGFloat, width: CGFloat) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        track.stroke()

        guard let percent = ring.percent else { return }
        // Even a little use shows as a dot, so an empty ring always means no numbers.
        let shown = max(percent, 4) / 100
        let arc = NSBezierPath()
        // Clockwise from 12 o'clock.
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * shown, clockwise: true)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        (percent >= UsageWindow.warningPercent ? NSColor.systemOrange : NSColor.labelColor).setStroke()
        arc.stroke()
    }
}
