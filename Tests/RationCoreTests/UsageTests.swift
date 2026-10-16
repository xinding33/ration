import XCTest
@testable import RationCore

final class UsageTests: XCTestCase {
    func testParsesClaudeWindowsAndScopedLimits() throws {
        let json = """
            {"five_hour": {"utilization": 6.0, "resets_at": "2026-10-16T04:40:00.717375+00:00"},
             "seven_day": {"utilization": 13.0, "resets_at": "2026-10-17T20:00:00+00:00"},
             "seven_day_opus": null, "seven_day_sonnet": {"utilization": 40, "resets_at": null},
             "extra_usage": {"is_enabled": false},
             "limits": [
               {"kind": "session", "percent": 6, "resets_at": "2026-10-16T04:40:00+00:00", "scope": null},
               {"kind": "weekly_scoped", "percent": 55, "resets_at": "2026-10-17T20:00:00+00:00",
                "scope": {"model": {"display_name": "Fable"}}},
               {"kind": "weekly_scoped", "percent": 40, "scope": {"model": {"display_name": "Sonnet"}}}
             ]}
            """
        let usage = try ClaudeUsageResponse.parse(Data(json.utf8), plan: "max")
        XCTAssertEqual(usage.plan, "Max")
        XCTAssertEqual(usage.windows.map(\.label), ["Session (5 hours)", "Weekly", "Weekly (Sonnet)", "Weekly (Fable)"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [6, 13, 40, 55])
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(try XCTUnwrap(usage.windows[0].resetsAt).timeIntervalSince(iso.date(from: "2026-10-16T04:40:00Z")!),
                       0.717375, accuracy: 0.001)
        XCTAssertEqual(usage.windows[1].resetsAt, iso.date(from: "2026-10-17T20:00:00Z"))
        XCTAssertNil(usage.windows[2].resetsAt)
        XCTAssertEqual(usage.windows.map(\.duration), [18000, 604800, 604800, 604800])
        XCTAssertEqual(usage.tightest?.label, "Weekly (Fable)")
    }

    func testClaudeWithoutLimitsHasNoWindows() throws {
        let usage = try ClaudeUsageResponse.parse(Data(#"{"five_hour": null, "seven_day": null}"#.utf8), plan: nil)
        XCTAssertEqual(usage.windows, [])
        XCTAssertNil(usage.plan)
        XCTAssertNil(usage.tightest)
        XCTAssertThrowsError(try ClaudeUsageResponse.parse(Data("<html>".utf8), plan: nil))
    }

    func testParsesChatGPTWindowsShortestFirst() throws {
        let json = """
            {"email": "someone@example.com", "plan_type": "pro",
             "rate_limit": {"allowed": true,
               "primary_window": {"used_percent": 1, "limit_window_seconds": 604800, "reset_at": 1792652134},
               "secondary_window": {"used_percent": 30, "limit_window_seconds": 18000, "reset_after_seconds": 600}},
             "credits": {"has_credits": true}}
            """
        let now = Date(timeIntervalSince1970: 1_000_000)
        let result = try ChatGPTUsageResponse.parse(Data(json.utf8), now: now)
        XCTAssertEqual(result.email, "someone@example.com")
        XCTAssertEqual(result.usage.plan, "Pro")
        XCTAssertEqual(result.usage.windows, [
            UsageWindow(label: "Session (5 hours)", usedPercent: 30, resetsAt: now.addingTimeInterval(600), duration: 18000),
            UsageWindow(label: "Weekly", usedPercent: 1, resetsAt: Date(timeIntervalSince1970: 1792652134), duration: 604800),
        ])
    }

    func testChatGPTSkipsMissingWindows() throws {
        let json = #"{"plan_type": "plus", "rate_limit": {"primary_window": null, "secondary_window": {"limit_window_seconds": 18000}}}"#
        let result = try ChatGPTUsageResponse.parse(Data(json.utf8))
        XCTAssertEqual(result.usage.windows, [])
        XCTAssertEqual(result.usage.plan, "Plus")
    }

    func testNamesWindowsByLength() {
        XCTAssertEqual(windowLabel(seconds: 18000), "Session (5 hours)")
        XCTAssertEqual(windowLabel(seconds: 86400), "Daily")
        XCTAssertEqual(windowLabel(seconds: 604800), "Weekly")
        XCTAssertEqual(windowLabel(seconds: 30 * 86400), "30-day")
        XCTAssertEqual(windowLabel(seconds: 3 * 3600), "3-hour")
        XCTAssertEqual(windowLabel(seconds: 90), "1-minute")
    }

    func testPlanNames() {
        XCTAssertEqual(planName("max"), "Max")
        XCTAssertEqual(planName("claude_pro"), "Pro")
        XCTAssertEqual(planName("enterprise_plus"), "Enterprise Plus")
        XCTAssertNil(planName(""))
        XCTAssertNil(planName(nil))
    }

    func testClampsPercentages() {
        XCTAssertEqual(UsageWindow(label: "x", usedPercent: 140, resetsAt: nil).usedPercent, 100)
        XCTAssertEqual(UsageWindow(label: "x", usedPercent: -3, resetsAt: nil).usedPercent, 0)
        XCTAssertTrue(UsageWindow(label: "x", usedPercent: 80, resetsAt: nil).isNearLimit)
        XCTAssertFalse(UsageWindow(label: "x", usedPercent: 79.9, resetsAt: nil).isNearLimit)
    }
}

final class CodexLoginTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func write(_ text: String) throws -> URL {
        let file = folder.appendingPathComponent("auth.json")
        try Data(text.utf8).write(to: file)
        return file
    }

    func testReadsTheChatGPTLogin() throws {
        let file = try write(#"{"auth_mode": "chatgpt", "tokens": {"access_token": "a", "account_id": "acct", "refresh_token": "r"}}"#)
        XCTAssertEqual(try CodexLogin.read(file), CodexLogin(accessToken: "a", accountID: "acct"))
    }

    func testExplainsLoginsItCannotUse() throws {
        func problem(_ file: URL) -> ServiceError? {
            do { _ = try CodexLogin.read(file); return nil } catch { return error as? ServiceError }
        }
        XCTAssertEqual(problem(folder.appendingPathComponent("missing.json")), .codexLogin(.missing))
        XCTAssertEqual(problem(try write("not json")), .codexLogin(.unreadable))
        XCTAssertEqual(problem(try write(#"{"auth_mode": "apikey", "OPENAI_API_KEY": "k", "tokens": null}"#)), .codexLogin(.apiKey))
    }

    func testFollowsCodexHome() {
        XCTAssertEqual(CodexLogin.defaultFile(environment: ["CODEX_HOME": "/tmp/codex"]).path, "/tmp/codex/auth.json")
        XCTAssertTrue(CodexLogin.defaultFile(environment: [:]).path.hasSuffix("/.codex/auth.json"))
    }
}
