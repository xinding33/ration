import AppKit
import RationCore

/// A menu row with one window's name, percentage, bar and reset time. A window with a pace also
/// shows stripes past the fill out to where that pace leaves it at the reset: orange if it would
/// leave a lot unused, green if it would use most of it, and gray with a mark past the end if it
/// would run out first. The pace in words is the row's tooltip.
final class UsageRowView: NSView {
    static let width: CGFloat = 280
    private let window_: UsageWindow
    private let resets: String
    private let pace: Pace?

    /// `paceText` describes `pace` for the tooltip and VoiceOver.
    init(_ window: UsageWindow, resets: String, pace: Pace? = nil, paceText: String? = nil) {
        window_ = window
        self.resets = resets
        self.pace = pace
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 46))
        toolTip = paceText
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        let label = "\(window.label): \(UsageText().percent(window.usedPercent)) used. \(resets)"
        setAccessibilityLabel(paceText.map { "\(label). \($0)" } ?? label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 14
        let text = UsageText()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let detail: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let top = bounds.height - 4

        let name = NSAttributedString(string: window_.label, attributes: title)
        name.draw(at: NSPoint(x: inset, y: top - 17))
        let percent = NSAttributedString(string: text.percent(window_.usedPercent), attributes: title)
        percent.draw(at: NSPoint(x: bounds.width - inset - percent.size().width, y: top - 17))

        let bar = NSRect(x: inset, y: top - 25, width: bounds.width - inset * 2, height: 5)
        let track = NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        track.fill()
        if let pace { drawPace(pace, in: bar, track: track) }
        if window_.usedPercent > 0 {
            var fill = bar
            fill.size.width = max(bar.width * window_.usedPercent / 100, 5)
            // Orange at 80% is for windows without a pace. On one with a pace, orange means use left unused.
            let nearLimit = window_.isNearLimit && !window_.showsPace
            (nearLimit ? NSColor.systemOrange : NSColor.labelColor.withAlphaComponent(0.75)).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
        }

        NSAttributedString(string: resets, attributes: detail).draw(at: NSPoint(x: inset, y: top - 42))
    }

    private func drawPace(_ pace: Pace, in bar: NSRect, track: NSBezierPath) {
        let color: NSColor
        switch pace {
        case .under: color = .systemOrange
        case .on: color = .systemGreen
        case .over: color = NSColor.labelColor.withAlphaComponent(0.45)
        }
        let from = bar.minX + bar.width * window_.usedPercent / 100
        let to = bar.minX + bar.width * pace.projectedPercent / 100
        if to > from {
            NSGraphicsContext.saveGraphicsState()
            track.addClip()
            NSBezierPath(rect: NSRect(x: from, y: bar.minY, width: to - from, height: bar.height)).addClip()
            color.setFill()
            // Slanted stripes, spaced from the start of the bar so they line up from row to row.
            let stripe: CGFloat = 1.6, spacing: CGFloat = 4, slant = bar.height * 0.85
            var x = bar.minX + ((from - slant - bar.minX) / spacing).rounded(.down) * spacing
            while x < to {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x, y: bar.minY))
                path.line(to: NSPoint(x: x + stripe, y: bar.minY))
                path.line(to: NSPoint(x: x + stripe + slant, y: bar.maxY))
                path.line(to: NSPoint(x: x + slant, y: bar.maxY))
                path.close()
                path.fill()
                x += spacing
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if case .over = pace {
            // A mark just past the end: this pace runs out before the reset.
            let cap = NSRect(x: bar.maxX + 2, y: bar.minY - 3, width: 3, height: bar.height + 6)
            color.setFill()
            NSBezierPath(roundedRect: cap, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// A section heading: the service's name, with its plan on the right.
final class ServiceHeaderView: NSView {
    private let name: String
    private let plan: String?

    init(name: String, plan: String?) {
        self.name = name
        self.plan = plan
        super.init(frame: NSRect(x: 0, y: 0, width: UsageRowView.width, height: 22))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(plan.map { "\(name), \($0) plan" } ?? name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 14
        let heading = NSAttributedString(string: name, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        heading.draw(at: NSPoint(x: inset, y: 3))
        if let plan {
            let label = NSAttributedString(string: plan, attributes: [
                .font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            label.draw(at: NSPoint(x: bounds.width - inset - label.size().width, y: 4))
        }
    }
}
