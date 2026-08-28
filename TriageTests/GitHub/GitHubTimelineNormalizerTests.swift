import XCTest
@testable import Triage

final class GitHubTimelineNormalizerTests: XCTestCase {
    func testMapsActionableAndUnknownTimelineEvents() {
        XCTAssertEqual(GitHubTimelineNormalizer.kind(for: "review_requested"), .reviewRequested)
        XCTAssertEqual(GitHubTimelineNormalizer.kind(for: "cross-referenced"), .crossReferenced)
        XCTAssertEqual(GitHubTimelineNormalizer.kind(for: "unrecognized"), .unknown)
        XCTAssertEqual(GitHubTimelineNormalizer.kind(for: nil), .unknown)
    }
}
