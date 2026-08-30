import XCTest
@testable import Triage

final class GitHubTimelineNormalizerTests: XCTestCase {
    func testMapsActionableAndUnknownTimelineEvents() {
        XCTAssertEqual(GitHubTimelineNormalizer.kind(for: "review_requested"), .reviewRequested)
        XCTAssertEqual(GitHubTimelineNormalizer.kind(for: "cross-referenced"), .crossReferenced)
        XCTAssertEqual(GitHubTimelineNormalizer.kind(for: "unrecognized"), .unknown)
        XCTAssertEqual(GitHubTimelineNormalizer.kind(for: nil), .unknown)
    }

    func testNormalizesRawPayloadAndRejectsDuplicateEvents() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try decoder.decode(
            [GitHubTimelineEventDTO].self,
            from: Data(
                #"[{"id":1,"event":"mentioned","created_at":"2026-01-01T00:00:00Z","actor":{"node_id":"U_1","login":"octocat"},"label":{"name":"bug"}},{"id":2,"event":"project_v2_item_status_changed","created_at":"2026-01-02T00:00:00Z"}]"#.utf8
            )
        )

        let normalized = try GitHubTimelineNormalizer.normalize(events)

        XCTAssertEqual(normalized.map(\.kind), [.mentioned, .addedToProject])
        XCTAssertEqual(normalized.first?.actor?.id, ActorID(rawValue: "U_1"))
        XCTAssertTrue(String(data: normalized[0].payload, encoding: .utf8)!.contains(#""label""#))

        XCTAssertThrowsError(try GitHubTimelineNormalizer.normalize([events[0], events[0]])) {
            XCTAssertEqual($0 as? GitHubTimelineNormalizationError, .duplicateEventID)
        }
    }
}
