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

    func testCoverageIsScopedByAccountOrganizationFeatureAndStream() throws {
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

    func testMissingRequiredOrganizationCoverageCannotReportFresh() {
        let coverage = organizationCoverage(feature: .roleDiscovery)

        let freshness = AccountOrganizationCachedState(
            coverage: [coverage],
            coverageRequirements: [requirement(for: coverage)],
            lastSuccessfulSyncAt: coverage.lastSuccessfulAt
        ).freshness

        XCTAssertEqual(freshness.status, .partial)
        XCTAssertEqual(freshness.lastSuccessfulSyncAt, coverage.lastSuccessfulAt)
        XCTAssertEqual(
            AccountOrganizationCoverageManifest.missingFeatures(in: [coverage]),
            AccountOrganizationCoverageManifest.requiredFeatures.subtracting([.roleDiscovery])
        )
    }

    func testEveryRequiredOrganizationFeatureMustHaveExplicitCoverageBeforeFresh() {
        let coverage = AccountOrganizationCoverageManifest.requiredFeatures.map(
            organizationCoverage(feature:)
        )

        let freshness = AccountOrganizationCachedState(
            coverage: coverage,
            coverageRequirements: coverage.map(requirement(for:)),
            lastSuccessfulSyncAt: coverage.compactMap(\.lastSuccessfulAt).max()
        ).freshness

        XCTAssertTrue(AccountOrganizationCoverageManifest.missingFeatures(in: coverage).isEmpty)
        XCTAssertEqual(freshness.status, .fresh)
    }

    func testMissingRequiredRepositoryStreamCannotReportFresh() {
        let organizationCoverage = AccountOrganizationCoverageManifest.requiredFeatures.map(
            organizationCoverage(feature:)
        )
        let coveredRepository = RepositoryID(rawValue: "covered-repository")!
        let missingRepository = RepositoryID(rawValue: "missing-repository")!
        let repositoryRecord = CoverageRecord(
            accountID: organizationCoverage[0].accountID,
            organizationID: organizationCoverage[0].organizationID,
            repositoryID: coveredRepository,
            feature: .issues,
            streamID: SyncStreamID(rawValue: "issues-by-repository")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: organizationCoverage[0].credentialRevision,
            capabilityRevision: organizationCoverage[0].capabilityRevision,
            status: .complete,
            lastSuccessfulAt: organizationCoverage[0].lastSuccessfulAt,
            failureDetail: nil
        )
        let requirements = organizationCoverage.map(requirement(for:)) + [
            requirement(for: repositoryRecord),
            CoverageRequirement(
                feature: .issues,
                repositoryID: missingRepository,
                streamID: repositoryRecord.streamID
            )
        ]

        let freshness = AccountOrganizationCachedState(
            coverage: organizationCoverage + [repositoryRecord],
            coverageRequirements: requirements,
            lastSuccessfulSyncAt: organizationCoverage[0].lastSuccessfulAt
        ).freshness

        XCTAssertEqual(freshness.status, .partial)
        XCTAssertEqual(freshness.detail, "1 coverage requirement(s) incomplete.")
    }

    private func organizationCoverage(feature: CoverageFeature) -> CoverageRecord {
        let successfulAt = Date(timeIntervalSinceReferenceDate: 500)
        return CoverageRecord(
            accountID: AccountID(rawValue: "manifest-account")!,
            organizationID: OrganizationID(rawValue: "manifest-organization")!,
            repositoryID: nil,
            feature: feature,
            streamID: SyncStreamID(rawValue: "manifest-\(feature.rawValue)")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: CredentialRevision(rawValue: "manifest-credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "manifest-capability")!,
            status: .complete,
            lastSuccessfulAt: successfulAt,
            failureDetail: nil
        )
    }

    private func requirement(for coverage: CoverageRecord) -> CoverageRequirement {
        CoverageRequirement(
            feature: coverage.feature,
            repositoryID: coverage.repositoryID,
            streamID: coverage.streamID,
            intervalStart: coverage.intervalStart,
            intervalEnd: coverage.intervalEnd
        )
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
