import CryptoKit
import Foundation

/// Ration's own Claude login: imported once from Claude Code's sign-in, then renewed only by Ration.
public struct ClaudeCredential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: [String]
    public var subscriptionType: String?
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scopes: [String],
                subscriptionType: String?, email: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.email = email
    }

    /// Reads the login Claude Code saves after `claude auth login`.
    public init(claudeCodeJSON data: Data) throws {
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double
            let scopes: [String]?
            let subscriptionType: String?
        }
        struct File: Decodable { let claudeAiOauth: OAuth? }
        guard let oauth = (try? JSONDecoder().decode(File.self, from: data))?.claudeAiOauth else {
            throw ClaudeLoginError.noLogin
        }
        guard let refresh = oauth.refreshToken, !refresh.isEmpty else { throw ClaudeLoginError.notRenewable }
        let scopes = oauth.scopes ?? []
        guard scopes.contains("user:profile") else { throw ClaudeLoginError.missingScope }
        self.init(accessToken: oauth.accessToken, refreshToken: refresh,
                  expiresAt: Date(timeIntervalSince1970: oauth.expiresAt / 1000),
                  scopes: scopes, subscriptionType: oauth.subscriptionType)
    }
}

public enum ClaudeLoginError: LocalizedError, Equatable {
    case noLogin, notRenewable, missingScope

    public var errorDescription: String? {
        switch self {
        case .noLogin: return "Claude Code didn't save a login."
        case .notRenewable: return "Claude Code saved a login that can't be renewed."
        case .missingScope: return "That login can't read usage. Sign in with a Claude subscription account."
        }
    }
}

/// The Keychain item `claude auth login` writes when `CLAUDE_CONFIG_DIR` is set: Claude Code
/// suffixes its service with the first 8 hex digits of the SHA-256 of that directory.
public func claudeCodeKeychainService(configDirectory: String) -> String {
    let digest = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "Claude Code-credentials-" + hex.prefix(8)
}

/// Where Ration keeps its Claude login.
public protocol CredentialStore: Sendable {
    func load() throws -> ClaudeCredential?
    func save(_ credential: ClaudeCredential) throws
    func delete() throws
}

/// Claude's usage and login endpoints. Every renewal goes through one actor, and only one is ever
/// in flight: a refresh token works once, so two renewals racing would sign Ration out.
public actor ClaudeClient {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's OAuth client. Its logins can only be renewed by the client that issued them.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Renew this long before the access token expires.
    static let renewalMargin: TimeInterval = 5 * 60

    private let store: CredentialStore
    private let http: HTTPClient
    private let userAgent: String
    private let now: @Sendable () -> Date
    /// Counts sign-ins and sign-outs. Work started for one login never touches the next.
    private var generation = 0
    /// The renewal in flight, and the login it belongs to.
    private var flight: (generation: Int, task: Task<ClaudeCredential, Error>)?
    /// A renewed login the Keychain refused to save. Its refresh token is the only one that works
    /// now, so it is kept here and saved again before the next renewal could spend the old one.
    private var unsaved: (generation: Int, credential: ClaudeCredential)?
    /// The refresh token the service refused for good, so Ration stops offering it.
    private var refusedRefreshToken: String?

    public init(store: CredentialStore, http: HTTPClient, userAgent: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.http = http
        self.userAgent = userAgent
        self.now = now
    }

    public func usage() async throws -> ServiceUsage {
        let credential = try await validCredential(rejecting: nil)
        var (data, response) = try await get(Self.usageURL, token: credential.accessToken)
        var current = credential
        if response.statusCode == 401 {
            current = try await validCredential(rejecting: credential.accessToken)
            (data, response) = try await get(Self.usageURL, token: current.accessToken)
            if response.statusCode == 401 { throw ServiceError.signedOut }
        }
        return try parse(data, response, plan: current.subscriptionType)
    }

    /// Checks usage with the saved access token only, never renewing it, so a second process such
    /// as `--diagnose` can't spend the refresh token the running app owns.
    public func usageWithoutRenewing() async throws -> ServiceUsage {
        guard let credential = try store.load() else { throw ServiceError.signedOut }
        guard credential.expiresAt > now() else { throw ServiceError.accessTokenExpired }
        let (data, response) = try await get(Self.usageURL, token: credential.accessToken)
        if response.statusCode == 401 { throw ServiceError.accessTokenExpired }
        return try parse(data, response, plan: credential.subscriptionType)
    }

    /// Saves a login imported from Claude Code as the only one Ration uses, then adds its account
    /// email if the profile lookup works. The login is saved before anything that could fail.
    public func adopt(_ imported: ClaudeCredential) async throws -> ClaudeCredential {
        // The Keychain first: if it refuses, the current login and its state stay as they were.
        try store.save(imported)
        generation += 1
        unsaved = nil
        refusedRefreshToken = nil
        let adopted = generation
        var credential = imported
        guard let (data, response) = try? await get(Self.profileURL, token: credential.accessToken),
              response.statusCode == 200 else { return credential }
        struct Profile: Decodable { struct Account: Decodable { let email: String? }; let account: Account? }
        credential.email = (try? JSONDecoder().decode(Profile.self, from: data))?.account?.email
        // Only if nothing replaced or renewed the login meanwhile.
        if generation == adopted, flight == nil, unsaved == nil, (try? store.load()) == imported { try? store.save(credential) }
        return credential
    }

    public func signOut() throws {
        try store.delete()
        generation += 1
        unsaved = nil
        refusedRefreshToken = nil
    }

    public func currentCredential() throws -> ClaudeCredential? {
        if let unsaved, unsaved.generation == generation { return unsaved.credential }
        return try store.load()
    }

    /// The saved login, renewed first if it is about to expire or the service just refused `rejecting`.
    func validCredential(rejecting: String?) async throws -> ClaudeCredential {
        while true {
            let started = generation
            do {
                return try await credential(for: started, rejecting: rejecting)
            } catch {
                // Signed in again while waiting: answer for the new login, not the old one's failure.
                if generation != started { continue }
                throw error
            }
        }
    }

    private func credential(for current: Int, rejecting: String?) async throws -> ClaudeCredential {
        if let flight, flight.generation == current { return try await flight.task.value }
        var credential: ClaudeCredential
        if let unsaved, unsaved.generation == current {
            credential = unsaved.credential
            if (try? store.save(credential)) != nil { self.unsaved = nil }
        } else {
            guard let saved = try store.load() else { throw ServiceError.signedOut }
            credential = saved
        }
        guard credential.refreshToken != refusedRefreshToken else { throw ServiceError.signedOut }
        if credential.expiresAt.timeIntervalSince(now()) > Self.renewalMargin && credential.accessToken != rejecting {
            return credential
        }
        // Not tied to the caller, so a caller that gives up never cancels a renewal halfway,
        // after the old refresh token is spent but before the new one is saved.
        let task = Task { try await self.renew(credential, generation: current) }
        flight = (current, task)
        defer { if flight?.generation == current { flight = nil } }
        return try await task.value
    }

    private func renew(_ credential: ClaudeCredential, generation started: Int) async throws -> ClaudeCredential {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": credential.refreshToken, "client_id": Self.clientID,
        ])
        let (data, response) = try await send(http, request)
        switch response.statusCode {
        case 200: break
        case 400, 401, 403:
            if generation == started { refusedRefreshToken = credential.refreshToken }
            throw ServiceError.signedOut
        case 429: throw ServiceError.rateLimited(until: retryAfter(response, now: now()))
        default: throw ServiceError.httpStatus(response.statusCode)
        }
        struct Grant: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
            let scope: String?
        }
        guard let grant = try? JSONDecoder().decode(Grant.self, from: data), grant.expires_in > 0 else {
            throw ServiceError.unexpectedResponse("Claude")
        }
        var renewed = credential
        renewed.accessToken = grant.access_token
        if let refresh = grant.refresh_token, !refresh.isEmpty { renewed.refreshToken = refresh }
        renewed.expiresAt = now().addingTimeInterval(grant.expires_in)
        if let scope = grant.scope { renewed.scopes = scope.split(separator: " ").map(String.init) }
        // Signed out or in again while this was in flight: that login wins. Callers retry for it.
        // Only this actor writes the saved login, so the generation is the whole story.
        guard generation == started else { throw ServiceError.signedOut }
        // Saved before use: the old refresh token no longer works. If the Keychain refuses, the
        // renewed login is kept in memory, replacing any earlier unsaved one, and saved again
        // before it is needed.
        do {
            try store.save(renewed)
            unsaved = nil
        } catch {
            unsaved = (started, renewed)
        }
        return renewed
    }

    private func get(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await send(http, request)
    }

    private func parse(_ data: Data, _ response: HTTPURLResponse, plan: String?) throws -> ServiceUsage {
        switch response.statusCode {
        case 200: break
        case 429: throw ServiceError.rateLimited(until: retryAfter(response, now: now()))
        default: throw ServiceError.httpStatus(response.statusCode)
        }
        do {
            return try ClaudeUsageResponse.parse(data, plan: plan)
        } catch {
            throw ServiceError.unexpectedResponse("Claude")
        }
    }
}
