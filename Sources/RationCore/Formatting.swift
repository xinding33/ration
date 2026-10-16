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
        return "Resets \(day(date, now: now))"
    }

    /// The tooltip for a window's pace: "On track to leave about 35% unused", "On track to use
    /// about 95% by the reset", "On track to use all of it by the reset" or "On track to run out
    /// tomorrow at 8:00 AM".
    public func pace(_ pace: Pace, now: Date) -> String {
        func nearestFive(_ value: Double) -> Int { Int((value / 5).rounded()) * 5 }
        switch pace {
        case .under(let projected):
            return "On track to leave about \(nearestFive(100 - projected))% unused"
        case .on(let projected):
            let used = min(nearestFive(projected), 100)
            return used == 100 ? "On track to use all of it by the reset" : "On track to use about \(used)% by the reset"
        case .over(let runsOutAt):
            // To the next quarter hour, since the estimate is rough.
            let quarter: TimeInterval = 15 * 60
            let rounded = Date(timeIntervalSinceReferenceDate: (runsOutAt.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter)
            return "On track to run out \(day(rounded, now: now))"
        }
    }

    /// "today at 9:40 PM", "tomorrow at 1:00 PM", "Sat at 1:00 PM" or "Oct 30 at 1:00 PM".
    private func day(_ date: Date, now: Date) -> String {
        let time = format(date, "jmm")
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let days = calendar.dateComponents([.day], from: startOfToday, to: calendar.startOfDay(for: date)).day, days < 7 {
            return "\(format(date, "EEE")) at \(time)"
        }
        return "\(format(date, "MMMd")) at \(time)"
    }

    /// "Updated just now", "Updated 1 minute ago", "Updated 12 minutes ago" or "Updated at 4:52 PM".
    public func updated(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "Updated just now"
        case 1: return "Updated 1 minute ago"
        case 2..<60: return "Updated \(minutes) minutes ago"
        default:
            return calendar.isDate(date, inSameDayAs: now)
                ? "Updated at \(format(date, "jmm"))"
                : "Updated \(format(date, "MMMd")) at \(format(date, "jmm"))"
        }
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
