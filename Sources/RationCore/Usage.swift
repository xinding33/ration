import Foundation

/// One usage limit, such as Claude's 5-hour session or ChatGPT's weekly window.
public struct UsageWindow: Equatable {
    public let label: String
    /// 0 to 100, as the service reports it.
    public let usedPercent: Double
    public let resetsAt: Date?
    /// How long the window lasts, when known.
    public let duration: TimeInterval?

    public init(label: String, usedPercent: Double, resetsAt: Date?, duration: TimeInterval? = nil) {
        self.label = label
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.duration = duration
    }

    /// At this much use a window is drawn in orange.
    public static let warningPercent: Double = 80
    public var isNearLimit: Bool { usedPercent >= Self.warningPercent }
}

/// What one service reported in one check.
public struct ServiceUsage: Equatable {
    /// "Max", "Pro" and so on, when the service says.
    public let plan: String?
    public let windows: [UsageWindow]

    public init(plan: String?, windows: [UsageWindow]) {
        self.plan = plan
        self.windows = windows
    }

    /// The fullest window, which is the one that stops you first.
    public var tightest: UsageWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
}

/// Names a window by its length, for services that report only a duration.
public func windowLabel(seconds: Int) -> String {
    switch seconds {
    case 5 * 3600: return "Session (5 hours)"
    case 86400: return "Daily"
    case 7 * 86400: return "Weekly"
    case let s where s % 86400 == 0: return "\(s / 86400)-day"
    case let s where s % 3600 == 0: return "\(s / 3600)-hour"
    default: return "\(max(1, seconds / 60))-minute"
    }
}

/// "max" becomes "Max", "claude_pro" becomes "Pro".
public func planName(_ raw: String?) -> String? {
    guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    for prefix in ["claude_", "chatgpt_"] where text.lowercased().hasPrefix(prefix) {
        text = String(text.dropFirst(prefix.count))
    }
    return text.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
}

enum ISODate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
    }
}

public enum UsageParseError: LocalizedError, Equatable {
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedResponse(let service): return "\(service) sent a usage response Ration doesn't understand."
        }
    }
}

/// Claude's `GET /api/oauth/usage`.
public enum ClaudeUsageResponse {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let displayName: String? }
            let model: Model?
        }
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
    }
    struct Body: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?
        let sevenDaySonnet: Window?
        let limits: [Limit]?
    }

    public static func parse(_ data: Data, plan: String?) throws -> ServiceUsage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let body = try? decoder.decode(Body.self, from: data) else {
            throw UsageParseError.unexpectedResponse("Claude")
        }
        var windows: [UsageWindow] = []
        let session: TimeInterval = 5 * 3600, week: TimeInterval = 7 * 86400
        func add(_ label: String, _ window: Window?, _ duration: TimeInterval) {
            guard let window, let used = window.utilization else { return }
            windows.append(UsageWindow(label: label, usedPercent: used, resetsAt: ISODate.parse(window.resetsAt), duration: duration))
        }
        add("Session (5 hours)", body.fiveHour, session)
        add("Weekly", body.sevenDay, week)
        add("Weekly (Opus)", body.sevenDayOpus, week)
        add("Weekly (Sonnet)", body.sevenDaySonnet, week)
        // Newer model-specific weekly limits are reported only in `limits`.
        for limit in body.limits ?? [] where limit.kind == "weekly_scoped" {
            guard let name = limit.scope?.model?.displayName, let used = limit.percent else { continue }
            let label = "Weekly (\(name))"
            guard !windows.contains(where: { $0.label == label }) else { continue }
            windows.append(UsageWindow(label: label, usedPercent: used, resetsAt: ISODate.parse(limit.resetsAt), duration: week))
        }
        return ServiceUsage(plan: planName(plan), windows: windows)
    }
}

/// ChatGPT's `GET /backend-api/wham/usage`, the endpoint Codex reads its limits from.
public enum ChatGPTUsageResponse {
    struct Window: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAt: Double?
        let resetAfterSeconds: Double?
    }
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }
    struct Body: Decodable {
        let planType: String?
        let email: String?
        let rateLimit: RateLimit?
    }

    public struct Result: Equatable {
        public let usage: ServiceUsage
        public let email: String?
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> Result {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let body = try? decoder.decode(Body.self, from: data) else {
            throw UsageParseError.unexpectedResponse("ChatGPT")
        }
        let reported = [body.rateLimit?.primaryWindow, body.rateLimit?.secondaryWindow]
            .compactMap { $0 }
            .filter { $0.usedPercent != nil }
            // The shorter window first, as Claude's are.
            .sorted { ($0.limitWindowSeconds ?? .max) < ($1.limitWindowSeconds ?? .max) }
        let windows = reported.map { window in
            let resets = window.resetAt.map { Date(timeIntervalSince1970: $0) }
                ?? window.resetAfterSeconds.map { now.addingTimeInterval($0) }
            let label = window.limitWindowSeconds.map(windowLabel(seconds:)) ?? "Limit"
            return UsageWindow(label: label, usedPercent: window.usedPercent ?? 0, resetsAt: resets,
                               duration: window.limitWindowSeconds.map(TimeInterval.init))
        }
        return Result(usage: ServiceUsage(plan: planName(body.planType), windows: windows), email: body.email)
    }
}
