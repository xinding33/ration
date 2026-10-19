import Foundation

/// Where a window is headed if use carries on at the rate since it started.
public enum Pace: Equatable {
    /// On track to use only this much by the reset, leaving the rest unused.
    case under(projectedPercent: Double)
    /// On track to use most or all of it by the reset.
    case on(projectedPercent: Double)
    /// On track to hit the limit at this time, before the reset.
    case over(runsOutAt: Date)

    /// Using less than this much by the reset is under pace.
    public static let onPacePercent: Double = 85
    /// A window longer than a day waits a day before judging. Shorter ones, like the session, start right away.
    public static func minimumElapsed(duration: TimeInterval) -> TimeInterval { duration > 86400 ? 86400 : 0 }

    /// How much of the limit this pace uses by the reset, at most 100.
    public var projectedPercent: Double {
        switch self {
        case .under(let percent), .on(let percent): return min(percent, 100)
        case .over: return 100
        }
    }
}

extension UsageWindow {
    /// Windows of known length, such as the 5-hour session and the weekly ones, show a pace.
    public var showsPace: Bool { (duration ?? 0) > 0 }

    /// The pace, assuming even use across the whole window. Nil for windows that don't show one,
    /// that are used up, or that are too new to judge.
    public func pace(now: Date) -> Pace? {
        guard showsPace, let duration, let resetsAt, usedPercent < 100 else { return nil }
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0, elapsed >= Pace.minimumElapsed(duration: duration), elapsed < duration else { return nil }
        let projected = usedPercent * duration / elapsed
        if projected > 100 {
            return .over(runsOutAt: start.addingTimeInterval(elapsed * 100 / usedPercent))
        }
        return projected >= Pace.onPacePercent ? .on(projectedPercent: projected) : .under(projectedPercent: projected)
    }
}
