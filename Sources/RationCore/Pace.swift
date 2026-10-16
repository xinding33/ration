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
    /// Until this share of a window has passed there's too little to go on.
    public static let minimumElapsed = 0.10
    /// Under pace is the louder warning, so it waits until more of the window has passed.
    public static let minimumElapsedForUnder = 0.25

    /// How much of the limit this pace uses by the reset, at most 100.
    public var projectedPercent: Double {
        switch self {
        case .under(let percent), .on(let percent): return min(percent, 100)
        case .over: return 100
        }
    }
}

extension UsageWindow {
    /// Only windows longer than a day, in practice the weekly ones, show a pace. A session resets
    /// too soon for leftover use to matter.
    public var showsPace: Bool { (duration ?? 0) > 86400 }

    /// The pace, assuming even use across the whole window. Nil for windows that don't show one,
    /// that are used up, or that are too new to judge.
    public func pace(now: Date) -> Pace? {
        guard showsPace, let duration, let resetsAt, usedPercent < 100 else { return nil }
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(start) / duration
        guard elapsed >= Pace.minimumElapsed, elapsed < 1 else { return nil }
        let projected = usedPercent / elapsed
        if projected > 100 {
            return .over(runsOutAt: start.addingTimeInterval(now.timeIntervalSince(start) * 100 / usedPercent))
        }
        if projected >= Pace.onPacePercent { return .on(projectedPercent: projected) }
        return elapsed >= Pace.minimumElapsedForUnder ? .under(projectedPercent: projected) : nil
    }
}
