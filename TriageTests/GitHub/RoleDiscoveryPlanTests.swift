import XCTest
@testable import Triage

final class RoleDiscoveryPlanTests: XCTestCase {
    func testPlanIncludesAllOpenAndRecentClosedRelationshipStreams() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let plan = try RoleDiscoveryPlan(
            organizationLogin: "github",
            userLogin: "octocat",
            now: Date(timeIntervalSince1970: 1_000_000),
            calendar: calendar
        )

        XCTAssertEqual(plan.openQueries.count, 7)
        XCTAssertEqual(plan.recentClosedQueries.count, 7)
        XCTAssertTrue(plan.openQueries.contains { $0.value.contains("review-requested:octocat") })
        XCTAssertTrue(plan.recentClosedQueries.allSatisfy { $0.value.contains("closed:>=") })
    }
}
