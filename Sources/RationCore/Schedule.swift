import Foundation

/// When to check a service next. Usage endpoints rate-limit eagerly, so checks are spaced out and
/// back off on failure.
public struct CheckSchedule: Equatable {
    /// Between successful checks.
    public static let interval: TimeInterval = 5 * 60
    /// Opening the menu checks again if the numbers are older than this.
    public static let freshness: TimeInterval = 60
    /// The longest wait after repeated failures.
    public static let maximumBackoff: TimeInterval = 60 * 60

    public private(set) var nextCheck: Date
    /// Before this, nothing checks, not even opening the menu.
    public private(set) var notBefore: Date
    public private(set) var failures = 0

    public init(now: Date = Date()) {
        nextCheck = now
        notBefore = .distantPast
    }

    public func isDue(_ now: Date) -> Bool { now >= nextCheck && now >= notBefore }

    /// Whether opening the menu should check now, given when the numbers were last updated.
    public func shouldCheckOnOpen(lastUpdate: Date?, now: Date) -> Bool {
        guard now >= notBefore else { return false }
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) > Self.freshness
    }

    public mutating func succeeded(_ now: Date) {
        failures = 0
        notBefore = now.addingTimeInterval(Self.freshness / 2)
        nextCheck = now.addingTimeInterval(Self.interval)
    }

    public mutating func failed(_ error: Error, now: Date) {
        failures += 1
        switch error as? ServiceError {
        case .rateLimited(let until):
            notBefore = max(until, now)
            nextCheck = notBefore
        case .signedOut, .codexLogin:
            // Nothing will change until the login does. Check again now and then in case it did.
            notBefore = now.addingTimeInterval(Self.freshness / 2)
            nextCheck = now.addingTimeInterval(Self.interval)
        default:
            // Opening the menu doesn't skip the backoff either.
            let wait = min(Self.interval * pow(2, Double(failures - 1)), Self.maximumBackoff)
            nextCheck = now.addingTimeInterval(wait)
            notBefore = nextCheck
        }
    }

    /// After waking from sleep or a new sign-in: check soon, unless the service asked to wait.
    public mutating func checkSoon(_ now: Date) {
        nextCheck = max(now, notBefore)
    }

    /// A new login replaces whatever the old one was told.
    public mutating func reset(_ now: Date) {
        failures = 0
        notBefore = .distantPast
        nextCheck = now
    }
}
