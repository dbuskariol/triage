import XCTest
@testable import Triage

final class GitHubHydrationBatchPlannerTests: XCTestCase {
    func testPlannerGrowsConservativelyForLowCostSmallResponses() {
        XCTAssertEqual(
            GitHubHydrationBatchPlanner.nextBatchSize(
                after: 25,
                queryCost: 125,
                responseBytes: 1_048_576
            ),
            30
        )
        XCTAssertEqual(
            GitHubHydrationBatchPlanner.nextBatchSize(
                after: 50,
                queryCost: 1,
                responseBytes: 1
            ),
            50
        )
    }

    func testPlannerShrinksBeforeExceedingHardBudgets() {
        XCTAssertEqual(
            GitHubHydrationBatchPlanner.nextBatchSize(
                after: 40,
                queryCost: 375,
                responseBytes: 1
            ),
            35
        )
        XCTAssertEqual(
            GitHubHydrationBatchPlanner.nextBatchSize(
                after: 25,
                queryCost: 1,
                responseBytes: 3_145_728
            ),
            25
        )
    }

    func testPlannerMaintainsBatchSizeForModerateResponses() {
        XCTAssertEqual(
            GitHubHydrationBatchPlanner.nextBatchSize(
                after: 35,
                queryCost: 200,
                responseBytes: 2_000_000
            ),
            35
        )
    }

    func testRetryPlannerShrinksButNeverBelowTheMinimum() {
        XCTAssertEqual(GitHubHydrationBatchPlanner.retryBatchSize(for: 50), 45)
        XCTAssertEqual(GitHubHydrationBatchPlanner.retryBatchSize(for: 30), 25)
        XCTAssertNil(GitHubHydrationBatchPlanner.retryBatchSize(for: 25))
        XCTAssertNil(GitHubHydrationBatchPlanner.retryBatchSize(for: 1))
    }
}
