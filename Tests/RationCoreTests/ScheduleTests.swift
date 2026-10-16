import XCTest
@testable import RationCore

final class ScheduleTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testChecksAtLaunchThenEveryFiveMinutes() {
        var schedule = CheckSchedule(now: now)
        XCTAssertTrue(schedule.isDue(now))
        schedule.succeeded(now)
        XCTAssertFalse(schedule.isDue(now.addingTimeInterval(299)))
        XCTAssertTrue(schedule.isDue(now.addingTimeInterval(300)))
    }

    func testOpeningTheMenuChecksOnlyStaleNumbers() {
        var schedule = CheckSchedule(now: now)
        XCTAssertTrue(schedule.shouldCheckOnOpen(lastUpdate: nil, now: now))
        schedule.succeeded(now)
        XCTAssertFalse(schedule.shouldCheckOnOpen(lastUpdate: now, now: now.addingTimeInterval(59)))
        XCTAssertTrue(schedule.shouldCheckOnOpen(lastUpdate: now, now: now.addingTimeInterval(61)))
    }

    func testWaitsAsLongAsARateLimitAsks() {
        var schedule = CheckSchedule(now: now)
        let until = now.addingTimeInterval(3585)
        schedule.failed(ServiceError.rateLimited(until: until), now: now)
        XCTAssertFalse(schedule.isDue(until.addingTimeInterval(-1)))
        XCTAssertFalse(schedule.shouldCheckOnOpen(lastUpdate: nil, now: until.addingTimeInterval(-1)))
        schedule.checkSoon(now)
        XCTAssertFalse(schedule.isDue(now), "waking from sleep doesn't override a rate limit")
        XCTAssertTrue(schedule.isDue(until))
    }

    func testBacksOffAfterRepeatedFailures() {
        var schedule = CheckSchedule(now: now)
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            schedule.failed(ServiceError.httpStatus(500), now: now)
            waits.append(schedule.nextCheck.timeIntervalSince(now))
        }
        XCTAssertEqual(waits, [300, 600, 1200, 2400, 3600, 3600])
        schedule.succeeded(now)
        XCTAssertEqual(schedule.failures, 0)
    }

    func testOpeningTheMenuDoesNotSkipTheBackoff() {
        var schedule = CheckSchedule(now: now)
        schedule.failed(ServiceError.httpStatus(500), now: now)
        schedule.failed(ServiceError.httpStatus(500), now: now)
        XCTAssertFalse(schedule.shouldCheckOnOpen(lastUpdate: nil, now: now.addingTimeInterval(599)))
        XCTAssertTrue(schedule.shouldCheckOnOpen(lastUpdate: nil, now: now.addingTimeInterval(600)))
    }

    func testOpeningTheMenuSoonChecksAFixedLogin() {
        var schedule = CheckSchedule(now: now)
        schedule.failed(ServiceError.codexLogin(.expired), now: now)
        XCTAssertTrue(schedule.shouldCheckOnOpen(lastUpdate: nil, now: now.addingTimeInterval(31)))
    }

    func testANewLoginChecksRightAway() {
        var schedule = CheckSchedule(now: now)
        schedule.failed(ServiceError.rateLimited(until: now.addingTimeInterval(3000)), now: now)
        schedule.reset(now)
        XCTAssertTrue(schedule.isDue(now))
    }
}

final class TextTests: XCTestCase {
    var text: UsageText!
    var now: Date!

    override func setUp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        text = UsageText(calendar: calendar, locale: Locale(identifier: "en_US"))
        // Thursday, October 15, 2026, 4:52 PM in Los Angeles.
        now = ISO8601DateFormatter().date(from: "2026-10-15T23:52:00Z")!
    }

    func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testDescribesResetTimes() {
        XCTAssertEqual(text.resets(date("2026-10-16T04:40:00Z"), now: now), "Resets today at 9:40\u{202F}PM")
        XCTAssertEqual(text.resets(date("2026-10-16T20:00:00Z"), now: now), "Resets tomorrow at 1:00\u{202F}PM")
        XCTAssertEqual(text.resets(date("2026-10-17T20:00:00Z"), now: now), "Resets Sat at 1:00\u{202F}PM")
        XCTAssertEqual(text.resets(date("2026-10-30T20:00:00Z"), now: now), "Resets Oct 30 at 1:00\u{202F}PM")
        XCTAssertEqual(text.resets(now.addingTimeInterval(-5), now: now), "Resetting now")
        XCTAssertEqual(text.resets(nil, now: now), "Reset time not reported")
    }

    func testDescribesPace() {
        XCTAssertEqual(text.pace(.under(projectedPercent: 66.7), now: now), "On track to leave about 35% unused")
        XCTAssertEqual(text.pace(.on(projectedPercent: 93), now: now), "On track to use about 95% by the reset")
        XCTAssertEqual(text.pace(.on(projectedPercent: 99), now: now), "On track to use all of it by the reset")
        // Rounded up to the quarter hour.
        XCTAssertEqual(text.pace(.over(runsOutAt: date("2026-10-16T15:03:00Z")), now: now), "On track to run out tomorrow at 8:15\u{202F}AM")
        XCTAssertEqual(text.pace(.over(runsOutAt: date("2026-10-16T01:30:00Z")), now: now), "On track to run out today at 6:30\u{202F}PM")
    }

    func testRoundsPercentages() {
        XCTAssertEqual(text.percent(6.4), "6%")
        XCTAssertEqual(text.percent(12.5), "13%")
        XCTAssertEqual(text.percent(100), "100%")
    }
}

final class LaunchAgentTests: XCTestCase {
    func testWritesAndRemovesTheAgent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = LaunchAgent(label: "test.ration", directory: folder)
        XCTAssertFalse(agent.exists)
        try agent.write(executable: "/Applications/Ration.app/Contents/MacOS/Ration")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: agent.url))
        XCTAssertEqual(plist["Label"] as? String, "test.ration")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Applications/Ration.app/Contents/MacOS/Ration"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        try agent.remove()
        XCTAssertFalse(agent.exists)
    }
}

final class SecurityOutputTests: XCTestCase {
    func testReadsPlainAndHexPasswords() {
        let json = Data(#"{"email":"zoë@example.com"}"#.utf8)
        let hex = json.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(securityPasswordOutput(Data((hex + "\n").utf8)), json)
        XCTAssertEqual(securityPasswordOutput(Data(#"{"a":1}"#.utf8) + Data("\n".utf8)), Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(securityPasswordOutput(Data("abc".utf8)), Data("abc".utf8), "odd length isn't hex")
    }
}
