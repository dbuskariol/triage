import XCTest
@testable import Triage

final class GitHubRateLimitTests: XCTestCase {
    func testParsesExhaustedSearchLimit() throws {
        let limit = try XCTUnwrap(
            GitHubRateLimit(headers: [
                "X-RateLimit-Resource": "search",
                "X-RateLimit-Limit": "30",
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "1000"
            ])
        )

        XCTAssertEqual(limit.resource, .search)
        XCTAssertEqual(limit.remaining, 0)
        XCTAssertEqual(limit.resetAt, Date(timeIntervalSince1970: 1000))
    }

    func testRetryAfterTakesPriorityOverCoreReset() {
        let limit = GitHubRateLimit(headers: [
            "X-RateLimit-Resource": "core",
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": "1000",
            "Retry-After": "60"
        ])!

        XCTAssertNotNil(limit.pauseUntil)
    }
}
