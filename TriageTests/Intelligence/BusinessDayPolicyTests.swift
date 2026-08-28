import XCTest
@testable import Triage

final class BusinessDayPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testDefaultPolicyCountsWeekdaysAndPreservesTimeOfDay() {
        let latestProgress = date(year: 2026, month: 8, day: 28, hour: 14)
        let due = BusinessDayPolicy().staleAfter(
            latestProgressAt: latestProgress,
            calendar: calendar
        )

        XCTAssertEqual(due, date(year: 2026, month: 9, day: 2, hour: 14))
    }

    func testStalenessBeginsAtTheThirdBusinessDayDeadline() {
        let latestProgress = date(year: 2026, month: 8, day: 28, hour: 14)
        let policy = BusinessDayPolicy()
        let due = date(year: 2026, month: 9, day: 2, hour: 14)

        XCTAssertFalse(
            policy.isStale(
                latestProgressAt: latestProgress,
                at: due.addingTimeInterval(-1),
                calendar: calendar
            )
        )
        XCTAssertTrue(
            policy.isStale(
                latestProgressAt: latestProgress,
                at: due,
                calendar: calendar
            )
        )
    }

    private func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        )!
    }
}
