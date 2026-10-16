import Foundation

/// Sends requests. URLSession in the app, a fake in tests.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPClient {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Why a usage check didn't produce numbers.
public enum ServiceError: LocalizedError, Equatable {
    /// Ration has no Claude login, or the service refused it for good.
    case signedOut
    /// The saved access token has expired, and this caller isn't the one that renews it.
    case accessTokenExpired
    /// Codex's login is missing, expired or not a ChatGPT login.
    case codexLogin(CodexLoginProblem)
    /// The service asked Ration to wait until this time.
    case rateLimited(until: Date)
    case httpStatus(Int)
    case unexpectedResponse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: return "Not signed in."
        case .accessTokenExpired: return "The saved access token has expired. The running app renews it."
        case .codexLogin(let problem): return problem.message
        case .rateLimited: return "Rate-limited."
        case .httpStatus(let status): return "The service responded with HTTP status \(status)."
        case .unexpectedResponse(let service): return "\(service) sent a usage response Ration doesn't understand."
        case .transport(let message): return message
        }
    }
}

public enum CodexLoginProblem: Equatable, Sendable {
    case missing, apiKey, unreadable, expired

    public var message: String {
        switch self {
        case .missing: return "Codex isn't signed in on this Mac. Sign in to Codex with your ChatGPT account."
        case .apiKey: return "Codex is signed in with an API key. ChatGPT usage needs a ChatGPT sign-in."
        case .unreadable: return "Ration can't read Codex's login file."
        case .expired: return "Codex's login has expired. Open Codex to renew it."
        }
    }

    /// For the menu.
    public var short: String {
        switch self {
        case .missing, .apiKey: return "Sign in to Codex to see usage"
        case .unreadable: return "Can't read Codex's login"
        case .expired: return "Open Codex to renew its login"
        }
    }
}

/// Reads a Retry-After header, in seconds or as an HTTP date. Waits at least a minute and at most an hour.
public func retryAfter(_ response: HTTPURLResponse, now: Date) -> Date {
    let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces)
    var seconds: TimeInterval = 300
    if let value, let number = TimeInterval(value) {
        seconds = number
    } else if let value {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { seconds = date.timeIntervalSince(now) }
    }
    return now.addingTimeInterval(min(max(seconds, 60), 3600))
}

func send(_ http: HTTPClient, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
        return try await http.send(request)
    } catch let error as URLError {
        throw ServiceError.transport(error.localizedDescription)
    }
}
