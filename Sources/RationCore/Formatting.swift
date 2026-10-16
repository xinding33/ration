import Foundation

/// The words under a usage bar and in the menu, kept here so they can be tested.
public struct UsageText {
    public var calendar: Calendar
    public var locale: Locale

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        self.locale = locale
    }

    /// "13%", rounded the way the services' own pages round.
    public func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "Resets today at 9:40 PM", "Resets tomorrow at 1:00 PM", "Resets Sat at 1:00 PM" or
    /// "Resets Oct 30 at 1:00 PM".
    public func resets(_ date: Date?, now: Date) -> String {
        guard let date else { return "Reset time not reported" }
        if date <= now { return "Resetting now" }
        let time = format(date, "jmm")
        if calendar.isDate(date, inSameDayAs: now) { return "Resets today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Resets tomorrow at \(time)"
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let days = calendar.dateComponents([.day], from: startOfToday, to: calendar.startOfDay(for: date)).day, days < 7 {
            return "Resets \(format(date, "EEE")) at \(time)"
        }
        return "Resets \(format(date, "MMMd")) at \(time)"
    }

    /// "6:12 PM", for messages like "retrying at 6:12 PM".
    public func time(_ date: Date) -> String { format(date, "jmm") }

    private func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
