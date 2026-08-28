import XCTest
@testable import Triage

final class SearchShardPlannerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)
    private let end = Date(timeIntervalSince1970: 3_600)

    func testCompleteSearchDoesNotShard() {
        let range = SearchTimeRange(start: start, end: end)
        XCTAssertEqual(
            SearchShardPlanner().nextPlan(range: range, totalCount: 1_000, incompleteResults: false),
            .complete(range)
        )
    }

    func testOversizedAndIncompleteSearchesBisectTime() {
        let range = SearchTimeRange(start: start, end: end)
        let plan = SearchShardPlanner().nextPlan(range: range, totalCount: 1_001, incompleteResults: false)
        XCTAssertEqual(
            plan,
            .split(
                SearchTimeRange(start: start, end: Date(timeIntervalSince1970: 1_800)),
                SearchTimeRange(start: Date(timeIntervalSince1970: 1_800), end: end)
            )
        )
        XCTAssertNotEqual(
            SearchShardPlanner().nextPlan(range: range, totalCount: 1, incompleteResults: true),
            .complete(range)
        )
    }

    func testSmallOverloadedRangeRequiresRepositoryPartition() {
        let range = SearchTimeRange(start: start, end: start.addingTimeInterval(60))
        XCTAssertEqual(
            SearchShardPlanner().nextPlan(range: range, totalCount: 1_001, incompleteResults: false),
            .repositoryPartitionRequired(range)
        )
    }
}
