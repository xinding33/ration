import Foundation

/// Codex's ChatGPT login, read from its `auth.json`. Ration only reads it: Codex renews it,
/// and a second program renewing the same login would sign Codex out.
public struct CodexLogin: Equatable, Sendable {
    public let accessToken: String
    public let accountID: String?

    public static func defaultFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    public static func read(_ file: URL) throws -> CodexLogin {
        guard let data = try? Data(contentsOf: file) else {
            throw ServiceError.codexLogin(.missing)
        }
        struct Tokens: Decodable {
            let access_token: String?
            let account_id: String?
        }
        struct File: Decodable {
            let auth_mode: String?
            let tokens: Tokens?
        }
        guard let auth = try? JSONDecoder().decode(File.self, from: data) else {
            throw ServiceError.codexLogin(.unreadable)
        }
        guard let token = auth.tokens?.access_token, !token.isEmpty else {
            throw ServiceError.codexLogin(.apiKey)
        }
        return CodexLogin(accessToken: token, accountID: auth.tokens?.account_id)
    }
}

public struct ChatGPTClient: Sendable {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    let http: HTTPClient
    let userAgent: String
    let loginFile: URL
    let now: @Sendable () -> Date

    public init(http: HTTPClient, userAgent: String, loginFile: URL = CodexLogin.defaultFile(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.userAgent = userAgent
        self.loginFile = loginFile
        self.now = now
    }

    public func usage() async throws -> ChatGPTUsageResponse.Result {
        let login = try CodexLogin.read(loginFile)
        var request = URLRequest(url: Self.usageURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
        if let account = login.accountID { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await send(http, request)
        switch response.statusCode {
        case 200: break
        case 401, 403:
            throw ServiceError.codexLogin(.expired)
        case 429: throw ServiceError.rateLimited(until: retryAfter(response, now: now()))
        default: throw ServiceError.httpStatus(response.statusCode)
        }
        do {
            return try ChatGPTUsageResponse.parse(data, now: now())
        } catch {
            throw ServiceError.unexpectedResponse("ChatGPT")
        }
    }
}
