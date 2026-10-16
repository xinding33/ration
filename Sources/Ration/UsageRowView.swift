import AppKit
import RationCore

/// A menu row with one window's name, percentage, bar and reset time.
final class UsageRowView: NSView {
    static let width: CGFloat = 280
    private let window_: UsageWindow
    private let resets: String

    init(_ window: UsageWindow, resets: String) {
        window_ = window
        self.resets = resets
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 46))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(window.label): \(UsageText().percent(window.usedPercent)) used. \(resets)")
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
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()
        if window_.usedPercent > 0 {
            var fill = bar
            fill.size.width = max(bar.width * window_.usedPercent / 100, 5)
            (window_.isNearLimit ? NSColor.systemOrange : NSColor.labelColor.withAlphaComponent(0.75)).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
        }

        NSAttributedString(string: resets, attributes: detail).draw(at: NSPoint(x: inset, y: top - 42))
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
