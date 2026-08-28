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
        try assertRoundTrip(coverage)
        try assertRoundTrip(
            FreshnessState(
                status: .rateLimited,
                lastSuccessfulSyncAt: Date(timeIntervalSinceReferenceDate: 50),
                nextRetryAt: Date(timeIntervalSinceReferenceDate: 200),
                detail: "GitHub search quota is exhausted."
            )
        )
    }

    func testScoresCompareOnlyTheirRankedValueAndRelationsRoundTrip() throws {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let evidence = EvidenceReference(
            id: EvidenceID(rawValue: "evidence-1")!,
            source: .graphQL,
            observedAt: date
        )
        let relation = WorkRelation(
            kind: .blocks,
            subjectNodeID: GitHubNodeID(rawValue: "node-1")!,
            objectNodeID: GitHubNodeID(rawValue: "node-2")!,
            confidence: .confirmed,
            evidence: [evidence],
            observedAt: date
        )
        let score = AttentionScore(value: 50, breakdown: ["direct": 50])

        XCTAssertNotEqual(score, AttentionScore(value: 50, breakdown: ["other": 50]))
        XCTAssertFalse(score < AttentionScore(value: 50, breakdown: [:]))
        XCTAssertLessThan(AttentionScore(value: 49, breakdown: [:]), score)
        XCTAssertEqual(try JSONDecoder().decode(
            WorkRelation.self,
            from: JSONEncoder().encode(relation)
        ), relation)
    }

    func testUnknownEvidenceAndFreshnessEnumValuesAreRejected() {
        assertUnknownCaseRejected(EvidenceSource.self)
        assertUnknownCaseRejected(WorkRelationKind.self)
        assertUnknownCaseRejected(RelationConfidence.self)
        assertUnknownCaseRejected(AttentionCategory.self)
        assertUnknownCaseRejected(CoverageFeature.self)
        assertUnknownCaseRejected(CoverageStatus.self)
        assertUnknownCaseRejected(FreshnessStatus.self)
    }

    private func assertUnknownCaseRejected<T: Decodable>(
        _ type: T.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(T.self, from: Data("\"future-case\"".utf8)),
            file: file,
            line: line
        )
    }

    private func assertRoundTrip<T: Codable & Equatable>(
        _ value: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)),
            value,
            file: file,
            line: line
        )
    }
}
