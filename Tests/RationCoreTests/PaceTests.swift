import XCTest
@testable import RationCore

final class PaceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let week: TimeInterval = 7 * 86400
    let session: TimeInterval = 5 * 3600

    /// A weekly window with `elapsed` of it gone.
    func weekly(_ used: Double, elapsed: Double) -> UsageWindow {
        UsageWindow(label: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(week * (1 - elapsed)), duration: week)
    }

    /// A 5-hour session with `hours` of it gone.
    func session(_ used: Double, hours: Double) -> UsageWindow {
        UsageWindow(label: "Session (5 hours)", usedPercent: used, resetsAt: now.addingTimeInterval(session - hours * 3600), duration: session)
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

    func testWaitsADayIntoTheWeek() {
        let day = 1.0 / 7
        XCTAssertNil(weekly(0, elapsed: day * 0.9).pace(now: now))
        XCTAssertNil(weekly(20, elapsed: day * 0.9).pace(now: now))
        XCTAssertNotNil(weekly(20, elapsed: day).pace(now: now))
        XCTAssertEqual(weekly(5, elapsed: day).pace(now: now), .under(projectedPercent: 35))
        XCTAssertEqual(weekly(0, elapsed: 0.5).pace(now: now), .under(projectedPercent: 0))
    }

    func testSessionsHaveAPaceFromTheStart() throws {
        XCTAssertTrue(session(0, hours: 0).showsPace)
        XCTAssertNil(session(0, hours: 0).pace(now: now))
        XCTAssertEqual(session(0, hours: 1.0 / 60).pace(now: now), .under(projectedPercent: 0))
        XCTAssertEqual(session(2, hours: 0.25).pace(now: now), .under(projectedPercent: 40))
        XCTAssertEqual(session(30, hours: 0.5).pace(now: now).map(\.projectedPercent), 100)
        XCTAssertEqual(session(10, hours: 1).pace(now: now), .under(projectedPercent: 50))
        XCTAssertEqual(session(45, hours: 2.5).pace(now: now), .on(projectedPercent: 90))
        // 60% used 2 hours in: 100% comes at 3 hours 20 minutes.
        let pace = try XCTUnwrap(session(60, hours: 2).pace(now: now))
        guard case .over(let runsOutAt) = pace else { return XCTFail("expected over, got \(pace)") }
        XCTAssertEqual(runsOutAt.timeIntervalSince(now), 80 * 60, accuracy: 1)
    }

    func testOnlyWindowsWithALengthAndResetTimeHaveAPace() {
        XCTAssertNil(UsageWindow(label: "Limit", usedPercent: 10, resetsAt: now.addingTimeInterval(3600)).pace(now: now))
        XCTAssertNil(UsageWindow(label: "Weekly", usedPercent: 10, resetsAt: nil, duration: week).pace(now: now))
        // Used up, already reset, or reporting a reset further off than the window is long.
        XCTAssertNil(weekly(100, elapsed: 0.5).pace(now: now))
        XCTAssertNil(weekly(50, elapsed: 1).pace(now: now))
        XCTAssertNil(weekly(50, elapsed: -0.1).pace(now: now))
    }
}
