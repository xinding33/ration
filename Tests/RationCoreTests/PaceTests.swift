import XCTest
@testable import RationCore

final class PaceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let week: TimeInterval = 7 * 86400

    /// A weekly window with `elapsed` of it gone.
    func weekly(_ used: Double, elapsed: Double) -> UsageWindow {
        UsageWindow(label: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(week * (1 - elapsed)), duration: week)
    }

    func testJudgesWeeklyWindowsByAnEvenPace() {
        XCTAssertEqual(weekly(48, elapsed: 0.72).pace(now: now), .under(projectedPercent: 48 / 0.72))
        XCTAssertEqual(weekly(70, elapsed: 0.72).pace(now: now), .on(projectedPercent: 70 / 0.72))
        XCTAssertEqual(weekly(50, elapsed: 0.5).pace(now: now), .on(projectedPercent: 100))
        // 85% by the reset is the lowest that's on pace.
        XCTAssertEqual(weekly(42.5, elapsed: 0.5).pace(now: now), .on(projectedPercent: 85))
        XCTAssertEqual(weekly(42, elapsed: 0.5).pace(now: now), .under(projectedPercent: 84))
    }

    func testOverPaceSaysWhenItRunsOut() throws {
        // 60% used halfway through: 100% comes at 5/6 of the week.
        let pace = try XCTUnwrap(weekly(60, elapsed: 0.5).pace(now: now))
        let start = now.addingTimeInterval(-week / 2)
        guard case .over(let runsOutAt) = pace else { return XCTFail("expected over, got \(pace)") }
        XCTAssertEqual(runsOutAt.timeIntervalSince(start), week * 5 / 6, accuracy: 1)
        XCTAssertEqual(pace.projectedPercent, 100)
    }

    func testWaitsBeforeJudging() {
        // Nothing in the first 10%, whichever way it's going.
        XCTAssertNil(weekly(0, elapsed: 0.05).pace(now: now))
        XCTAssertNil(weekly(20, elapsed: 0.05).pace(now: now))
        XCTAssertNotNil(weekly(20, elapsed: 0.15).pace(now: now))
        // Under pace waits until a quarter of the week has passed.
        XCTAssertEqual(weekly(14, elapsed: 0.15).pace(now: now), .on(projectedPercent: 14 / 0.15))
        XCTAssertNil(weekly(10, elapsed: 0.15).pace(now: now))
        XCTAssertNil(weekly(5, elapsed: 0.2).pace(now: now))
        XCTAssertEqual(weekly(5, elapsed: 0.25).pace(now: now), .under(projectedPercent: 20))
        XCTAssertEqual(weekly(0, elapsed: 0.5).pace(now: now), .under(projectedPercent: 0))
    }

    func testOnlyLongWindowsWithAResetTimeHaveAPace() {
        let session = UsageWindow(label: "Session (5 hours)", usedPercent: 90, resetsAt: now.addingTimeInterval(3600), duration: 5 * 3600)
        XCTAssertFalse(session.showsPace)
        XCTAssertNil(session.pace(now: now))
        let daily = UsageWindow(label: "Daily", usedPercent: 10, resetsAt: now.addingTimeInterval(3600), duration: 86400)
        XCTAssertNil(daily.pace(now: now))
        XCTAssertNil(UsageWindow(label: "Weekly", usedPercent: 10, resetsAt: now, duration: nil).pace(now: now))
        XCTAssertNil(UsageWindow(label: "Weekly", usedPercent: 10, resetsAt: nil, duration: week).pace(now: now))
        // Used up, already reset, or reporting a reset further off than the window is long.
        XCTAssertNil(weekly(100, elapsed: 0.5).pace(now: now))
        XCTAssertNil(weekly(50, elapsed: 1).pace(now: now))
        XCTAssertNil(weekly(50, elapsed: -0.1).pace(now: now))
    }
}
