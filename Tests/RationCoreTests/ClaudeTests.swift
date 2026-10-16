import XCTest
@testable import RationCore

/// A credential store in memory.
final class MemoryStore: CredentialStore, @unchecked Sendable {
    struct Refused: Error {}
    private let lock = NSLock()
    private var credential: ClaudeCredential?
    private(set) var saves = 0
    /// How many saves to refuse, like a locked Keychain.
    var failingSaves = 0
    var failingDeletes = 0

    init(_ credential: ClaudeCredential?) { self.credential = credential }

    func load() throws -> ClaudeCredential? { lock.lock(); defer { lock.unlock() }; return credential }
    func save(_ credential: ClaudeCredential) throws {
        lock.lock(); defer { lock.unlock() }
        if failingSaves > 0 { failingSaves -= 1; throw Refused() }
        self.credential = credential
        saves += 1
    }
    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        if failingDeletes > 0 { failingDeletes -= 1; throw Refused() }
        credential = nil
    }
}

/// Answers requests from a handler and records them.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    typealias Handler = (URLRequest) async throws -> (Int, [String: String], Data)
    private let lock = NSLock()
    private var handler: Handler
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    private func record(_ request: URLRequest) -> Handler {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, headers, body) = try await record(request)(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func requests(to url: URL) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url == url }
    }
}

final class ClaudeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let usageJSON = Data(#"{"five_hour": {"utilization": 6, "resets_at": null}, "seven_day": {"utilization": 13, "resets_at": null}}"#.utf8)

    func credential(expiresIn seconds: TimeInterval, access: String = "old-access", refresh: String = "old-refresh") -> ClaudeCredential {
        ClaudeCredential(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(seconds),
                         scopes: ["user:inference", "user:profile"], subscriptionType: "max")
    }

    func grant(access: String = "new-access", refresh: String = "new-refresh") -> Data {
        Data(#"{"access_token": "\#(access)", "refresh_token": "\#(refresh)", "expires_in": 28800, "scope": "user:inference user:profile"}"#.utf8)
    }

    func client(_ store: MemoryStore, _ http: FakeHTTP) -> ClaudeClient {
        let now = self.now
        return ClaudeClient(store: store, http: http, userAgent: "Ration/test", now: { now })
    }

    func testImportsClaudeCodesLogin() throws {
        let json = #"{"claudeAiOauth": {"accessToken": "a", "refreshToken": "r", "expiresAt": 2000000000000, "scopes": ["user:inference", "user:profile"], "subscriptionType": "max"}}"#
        let imported = try ClaudeCredential(claudeCodeJSON: Data(json.utf8))
        XCTAssertEqual(imported, ClaudeCredential(accessToken: "a", refreshToken: "r", expiresAt: now,
                                                  scopes: ["user:inference", "user:profile"], subscriptionType: "max"))
    }

    func testRefusesLoginsThatCannotReadUsage() {
        let tokenOnly = #"{"claudeAiOauth": {"accessToken": "a", "refreshToken": null, "expiresAt": 1, "scopes": ["user:inference"]}}"#
        XCTAssertThrowsError(try ClaudeCredential(claudeCodeJSON: Data(tokenOnly.utf8))) {
            XCTAssertEqual($0 as? ClaudeLoginError, .notRenewable)
        }
        let inferenceOnly = #"{"claudeAiOauth": {"accessToken": "a", "refreshToken": "r", "expiresAt": 1, "scopes": ["user:inference"]}}"#
        XCTAssertThrowsError(try ClaudeCredential(claudeCodeJSON: Data(inferenceOnly.utf8))) {
            XCTAssertEqual($0 as? ClaudeLoginError, .missingScope)
        }
        XCTAssertThrowsError(try ClaudeCredential(claudeCodeJSON: Data("{}".utf8))) {
            XCTAssertEqual($0 as? ClaudeLoginError, .noLogin)
        }
    }

    func testNamesClaudeCodesKeychainItemForAProfile() {
        // Claude Code suffixes the service with the SHA-256 of the config directory (`printf /tmp/x | shasum -a 256`).
        XCTAssertEqual(claudeCodeKeychainService(configDirectory: "/tmp/x"), "Claude Code-credentials-2e56aa36")
    }

    func testUsesAFreshTokenWithoutRenewing() async throws {
        let store = MemoryStore(credential(expiresIn: 3600))
        let http = FakeHTTP { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            return (200, [:], self.usageJSON)
        }
        let usage = try await client(store, http).usage()
        XCTAssertEqual(usage.windows.map(\.usedPercent), [6, 13])
        XCTAssertEqual(usage.plan, "Max")
        XCTAssertEqual(http.requests(to: ClaudeClient.tokenURL).count, 0)
        XCTAssertEqual(store.saves, 0)
    }

    func testRenewsBeforeExpiryAndSavesTheRotatedLogin() async throws {
        let store = MemoryStore(credential(expiresIn: 60))
        let http = FakeHTTP { request in
            if request.url == ClaudeClient.tokenURL {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                XCTAssertEqual(body, ["grant_type": "refresh_token", "refresh_token": "old-refresh", "client_id": ClaudeClient.clientID])
                return (200, [:], self.grant())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            return (200, [:], self.usageJSON)
        }
        _ = try await client(store, http).usage()
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "new-refresh")
        XCTAssertEqual(saved.expiresAt, now.addingTimeInterval(28800))
        XCTAssertEqual(saved.subscriptionType, "max")
    }

    func testConcurrentChecksRenewOnce() async throws {
        let store = MemoryStore(credential(expiresIn: -10))
        let http = FakeHTTP { request in
            if request.url == ClaudeClient.tokenURL {
                try await Task.sleep(nanoseconds: 100_000_000)
                return (200, [:], self.grant())
            }
            return (200, [:], self.usageJSON)
        }
        let claude = client(store, http)
        async let a = claude.usage()
        async let b = claude.usage()
        async let c = claude.usage()
        _ = try await (a, b, c)
        XCTAssertEqual(http.requests(to: ClaudeClient.tokenURL).count, 1)
        XCTAssertEqual(store.saves, 1)
    }

    func testRenewsOnceWhenTheServiceRejectsTheToken() async throws {
        let store = MemoryStore(credential(expiresIn: 3600))
        let http = FakeHTTP { request in
            if request.url == ClaudeClient.tokenURL { return (200, [:], self.grant()) }
            let token = request.value(forHTTPHeaderField: "Authorization")
            return token == "Bearer old-access" ? (401, [:], Data()) : (200, [:], self.usageJSON)
        }
        _ = try await client(store, http).usage()
        XCTAssertEqual(http.requests(to: ClaudeClient.tokenURL).count, 1)
        XCTAssertEqual(http.requests(to: ClaudeClient.usageURL).count, 2)
    }

    func testARefusedRenewalSignsOutAndIsNotRetried() async throws {
        let store = MemoryStore(credential(expiresIn: -10))
        let http = FakeHTTP { request in
            request.url == ClaudeClient.tokenURL ? (400, [:], Data(#"{"error": "invalid_grant"}"#.utf8)) : (200, [:], self.usageJSON)
        }
        let claude = client(store, http)
        for _ in 0..<2 {
            do { _ = try await claude.usage(); XCTFail("should be signed out") }
            catch { XCTAssertEqual(error as? ServiceError, .signedOut) }
        }
        XCTAssertEqual(http.requests(to: ClaudeClient.tokenURL).count, 1)
        // The login is kept, so a transient refusal can be retried after signing in again.
        XCTAssertEqual(try store.load()?.refreshToken, "old-refresh")
    }

    func testRateLimitedRenewalKeepsTheLogin() async throws {
        let store = MemoryStore(credential(expiresIn: -10))
        let http = FakeHTTP { _ in (429, ["Retry-After": "120"], Data()) }
        do { _ = try await client(store, http).usage(); XCTFail("should be rate-limited") }
        catch { XCTAssertEqual(error as? ServiceError, .rateLimited(until: now.addingTimeInterval(120))) }
        XCTAssertEqual(try store.load()?.refreshToken, "old-refresh")
    }

    func testRateLimitedUsage() async throws {
        let store = MemoryStore(credential(expiresIn: 3600))
        let http = FakeHTTP { _ in (429, ["Retry-After": "3585"], Data()) }
        do { _ = try await client(store, http).usage(); XCTFail("should be rate-limited") }
        catch { XCTAssertEqual(error as? ServiceError, .rateLimited(until: now.addingTimeInterval(3585))) }
    }

    func testNoLoginIsSignedOut() async {
        let http = FakeHTTP { _ in (200, [:], Data()) }
        do { _ = try await client(MemoryStore(nil), http).usage(); XCTFail("should be signed out") }
        catch { XCTAssertEqual(error as? ServiceError, .signedOut) }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testSigningOutThroughRationDuringARenewalWins() async throws {
        let store = MemoryStore(credential(expiresIn: -10))
        var claude: ClaudeClient!
        let http = FakeHTTP { request in
            if request.url == ClaudeClient.tokenURL {
                try await claude.signOut()
                return (200, [:], self.grant())
            }
            return (200, [:], self.usageJSON)
        }
        claude = client(store, http)
        do { _ = try await claude.usage(); XCTFail("should be signed out") }
        catch { XCTAssertEqual(error as? ServiceError, .signedOut) }
        XCTAssertNil(try store.load())
    }

    func testANewLoginDoesNotInheritTheOldLoginsFailedRenewal() async throws {
        let store = MemoryStore(credential(expiresIn: -10))
        let replacement = credential(expiresIn: 3600, access: "other-access", refresh: "other-refresh")
        var claude: ClaudeClient!
        let http = FakeHTTP { request in
            switch request.url {
            case ClaudeClient.tokenURL:
                _ = try await claude.adopt(replacement)
                return (429, ["Retry-After": "3600"], Data())
            case ClaudeClient.profileURL:
                return (500, [:], Data())
            default:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer other-access")
                return (200, [:], self.usageJSON)
            }
        }
        claude = client(store, http)
        let usage = try await claude.usage()
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(try store.load(), replacement)
    }

    func testAKeychainFailureAfterRenewingKeepsTheRenewedLogin() async throws {
        let store = MemoryStore(credential(expiresIn: -10))
        store.failingSaves = 1
        let http = FakeHTTP { request in
            request.url == ClaudeClient.tokenURL ? (200, [:], self.grant()) : (200, [:], self.usageJSON)
        }
        let claude = client(store, http)
        _ = try await claude.usage()
        XCTAssertEqual(try store.load()?.refreshToken, "old-refresh", "the first save was refused")
        let pending = try await claude.currentCredential()
        XCTAssertEqual(pending?.refreshToken, "new-refresh")
        _ = try await claude.usage()
        XCTAssertEqual(try store.load()?.refreshToken, "new-refresh", "saved on the next check")
        XCTAssertEqual(http.requests(to: ClaudeClient.tokenURL).count, 1, "the spent refresh token is never offered again")
    }

    func testRepeatedKeychainFailuresKeepTheNewestLogin() async throws {
        let store = MemoryStore(credential(expiresIn: -10, refresh: "r0"))
        store.failingSaves = 3
        var renewals = 0
        let http = FakeHTTP { request in
            guard request.url == ClaudeClient.tokenURL else {
                return request.value(forHTTPHeaderField: "Authorization") == "Bearer a1" ? (401, [:], Data()) : (200, [:], self.usageJSON)
            }
            renewals += 1
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            XCTAssertEqual(body["refresh_token"], "r\(renewals - 1)", "each renewal offers the newest refresh token")
            return (200, [:], self.grant(access: "a\(renewals)", refresh: "r\(renewals)"))
        }
        let claude = client(store, http)
        // r0 → r1 (save refused); the service rejects a1, so r1 → r2 (both saves refused again).
        _ = try await claude.usage()
        XCTAssertEqual(renewals, 2)
        XCTAssertEqual(try store.load()?.refreshToken, "r0")
        let pending = try await claude.currentCredential()
        XCTAssertEqual(pending?.refreshToken, "r2")
        // The Keychain works again: r2 is saved without renewing.
        _ = try await claude.usage()
        XCTAssertEqual(renewals, 2)
        XCTAssertEqual(try store.load()?.refreshToken, "r2")
    }

    func testAFailedSignOutOrSignInKeepsTheUnsavedLogin() async throws {
        let store = MemoryStore(credential(expiresIn: -10))
        store.failingSaves = 1
        let http = FakeHTTP { request in
            request.url == ClaudeClient.tokenURL ? (200, [:], self.grant()) : (200, [:], self.usageJSON)
        }
        let claude = client(store, http)
        _ = try await claude.usage()
        store.failingDeletes = 1
        do { try await claude.signOut(); XCTFail("refused") } catch {}
        store.failingSaves = 1
        do { _ = try await claude.adopt(credential(expiresIn: 3600, access: "x", refresh: "x")); XCTFail("refused") } catch {}
        let current = try await claude.currentCredential()
        XCTAssertEqual(current?.refreshToken, "new-refresh")
        _ = try await claude.usage()
        XCTAssertEqual(try store.load()?.refreshToken, "new-refresh")
        XCTAssertEqual(http.requests(to: ClaudeClient.tokenURL).count, 1)
    }

    func testAdoptingSavesTheLoginEvenIfTheProfileLookupFails() async throws {
        let store = MemoryStore(nil)
        let http = FakeHTTP { _ in throw URLError(.notConnectedToInternet) }
        let imported = credential(expiresIn: 3600)
        let adopted = try await client(store, http).adopt(imported)
        XCTAssertNil(adopted.email)
        XCTAssertEqual(try store.load(), imported)
    }

    func testDiagnosticsNeverRenew() async throws {
        let http = FakeHTTP { request in
            request.url == ClaudeClient.tokenURL ? (200, [:], self.grant()) : (200, [:], self.usageJSON)
        }
        do { _ = try await client(MemoryStore(credential(expiresIn: -10)), http).usageWithoutRenewing(); XCTFail("expired") }
        catch { XCTAssertEqual(error as? ServiceError, .accessTokenExpired) }
        let usage = try await client(MemoryStore(credential(expiresIn: 60)), http).usageWithoutRenewing()
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(http.requests(to: ClaudeClient.tokenURL).count, 0)
    }

    func testAdoptingALoginRecordsItsEmail() async throws {
        let store = MemoryStore(nil)
        let http = FakeHTTP { request in
            XCTAssertEqual(request.url, ClaudeClient.profileURL)
            return (200, [:], Data(#"{"account": {"email": "someone@example.com"}, "organization": {}}"#.utf8))
        }
        let adopted = try await client(store, http).adopt(credential(expiresIn: 3600))
        XCTAssertEqual(adopted.email, "someone@example.com")
        XCTAssertEqual(try store.load(), adopted)
    }

    func testReadsRetryAfter() {
        func response(_ value: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: ClaudeClient.usageURL, statusCode: 429, httpVersion: nil,
                            headerFields: value.map { ["Retry-After": $0] })!
        }
        XCTAssertEqual(retryAfter(response("120"), now: now), now.addingTimeInterval(120))
        XCTAssertEqual(retryAfter(response("5"), now: now), now.addingTimeInterval(60))
        XCTAssertEqual(retryAfter(response("99999"), now: now), now.addingTimeInterval(3600))
        XCTAssertEqual(retryAfter(response(nil), now: now), now.addingTimeInterval(300))
        XCTAssertEqual(retryAfter(response("Wed, 18 May 2033 03:43:20 GMT"), now: now), now.addingTimeInterval(600))
    }
}
