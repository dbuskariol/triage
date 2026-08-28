import XCTest
@testable import Triage

final class EvidenceAndFreshnessTests: XCTestCase {
    func testEvidencePreservesItsSpecificSourceProvenance() {
        let evidence = EvidenceReference(
            id: EvidenceID(rawValue: "event-1")!,
            source: .restTimeline,
            nodeID: GitHubNodeID(rawValue: "I_kwDOExample")!,
            eventID: GitHubEventID(rawValue: "123")!,
            sourceRevision: "updated-at:2026-08-28T00:00:00Z",
            observedAt: Date(timeIntervalSinceReferenceDate: 100),
            excerpt: "@octocat Please review this."
        )

        XCTAssertEqual(evidence.source, .restTimeline)
        XCTAssertEqual(evidence.eventID?.rawValue, "123")
        XCTAssertEqual(evidence.excerpt, "@octocat Please review this.")
    }

    func testCoverageIsScopedByAccountOrganizationFeatureAndStream() {
        let coverage = CoverageRecord(
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: "github")!,
            repositoryID: RepositoryID(rawValue: "repo-1")!,
            feature: .discussions,
            streamID: SyncStreamID(rawValue: "discussion-scan")!,
            intervalStart: Date(timeIntervalSinceReferenceDate: 0),
            intervalEnd: Date(timeIntervalSinceReferenceDate: 100),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
            status: .partial,
            lastSuccessfulAt: nil,
            failureDetail: "Token cannot read discussions."
        )

        XCTAssertEqual(coverage.feature, .discussions)
        XCTAssertEqual(coverage.status, .partial)
        XCTAssertNotNil(coverage.repositoryID)
    }
}
