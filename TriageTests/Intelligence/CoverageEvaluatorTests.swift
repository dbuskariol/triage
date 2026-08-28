import XCTest
@testable import Triage

final class CoverageEvaluatorTests: XCTestCase {
    private let accountID = AccountID(rawValue: "account")!
    private let organizationID = OrganizationID(rawValue: "organization")!
    private let credentialRevision = CredentialRevision(rawValue: "credential")!
    private let capabilityRevision = CapabilityRevision(rawValue: "capability")!
    private let streamID = SyncStreamID(rawValue: "stream")!

    func testIncompleteCoverageCannotAppearComplete() {
        let requirement = requirement(feature: .issues)
        let evaluation = CoverageEvaluator().evaluate(
            requirements: [requirement],
            records: [],
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )

        XCTAssertFalse(evaluation.isComplete)
        XCTAssertEqual(evaluation.freshness.status, .partial)
        XCTAssertEqual(evaluation.missing.count, 1)
    }

    func testSSORequirementIsExplicit() {
        let requirement = requirement(feature: .pullRequests)
        let evaluation = CoverageEvaluator().evaluate(
            requirements: [requirement],
            records: [record(feature: .pullRequests, status: .requiresSSO)],
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )

        XCTAssertEqual(evaluation.freshness.status, .ssoRequired)
        XCTAssertFalse(evaluation.isComplete)
    }

    func testCompleteMatchingCoverageIsFresh() {
        let requirement = requirement(feature: .issues)
        let evaluation = CoverageEvaluator().evaluate(
            requirements: [requirement],
            records: [record(feature: .issues, status: .complete)],
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )

        XCTAssertTrue(evaluation.isComplete)
        XCTAssertEqual(evaluation.freshness.status, .fresh)
    }

    func testStaleCredentialOrCapabilityRevisionsCannotSatisfyCoverage() {
        let requirement = requirement(feature: .issues)
        let staleCredential = CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            feature: .issues,
            streamID: SyncStreamID(rawValue: "stream")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: CredentialRevision(rawValue: "old-credential")!,
            capabilityRevision: capabilityRevision,
            status: .complete,
            lastSuccessfulAt: .now,
            failureDetail: nil
        )
        let staleCapability = CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            feature: .issues,
            streamID: SyncStreamID(rawValue: "stream")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: credentialRevision,
            capabilityRevision: CapabilityRevision(rawValue: "old-capability")!,
            status: .complete,
            lastSuccessfulAt: .now,
            failureDetail: nil
        )

        let evaluation = CoverageEvaluator().evaluate(
            requirements: [requirement],
            records: [staleCredential, staleCapability],
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )

        XCTAssertFalse(evaluation.isComplete)
        XCTAssertEqual(evaluation.freshness.status, .partial)
        XCTAssertEqual(evaluation.missing.count, 1)
        XCTAssertEqual(evaluation.missing.first?.feature, .issues)
        XCTAssertNil(evaluation.missing.first?.repositoryID)
    }

    func testIntervalCoverageCannotSatisfyAnOrganizationWideRequirement() {
        let interval = DateInterval(
            start: Date(timeIntervalSinceReferenceDate: 0),
            end: Date(timeIntervalSinceReferenceDate: 100)
        )
        let intervalRecord = CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            feature: .issues,
            streamID: streamID,
            intervalStart: interval.start,
            intervalEnd: interval.end,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            status: .complete,
            lastSuccessfulAt: interval.end,
            failureDetail: nil
        )

        let evaluation = CoverageEvaluator().evaluate(
            requirements: [requirement(feature: .issues)],
            records: [intervalRecord],
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )

        XCTAssertFalse(evaluation.isComplete)
        XCTAssertEqual(evaluation.freshness.status, .partial)
    }

    func testCompleteCoverageMustSpanTheRequiredInterval() {
        let requirementInterval = DateInterval(
            start: Date(timeIntervalSinceReferenceDate: 100),
            end: Date(timeIntervalSinceReferenceDate: 200)
        )
        let coveringRecord = CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            feature: .issues,
            streamID: streamID,
            intervalStart: Date(timeIntervalSinceReferenceDate: 0),
            intervalEnd: Date(timeIntervalSinceReferenceDate: 300),
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            status: .complete,
            lastSuccessfulAt: requirementInterval.end,
            failureDetail: nil
        )

        let evaluation = CoverageEvaluator().evaluate(
            requirements: [requirement(feature: .issues, interval: requirementInterval)],
            records: [coveringRecord],
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )

        XCTAssertTrue(evaluation.isComplete)
    }

    private func record(feature: CoverageFeature, status: CoverageStatus) -> CoverageRecord {
        CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            feature: feature,
            streamID: streamID,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            status: status,
            lastSuccessfulAt: .now,
            failureDetail: nil
        )
    }

    private func requirement(
        feature: CoverageFeature,
        interval: DateInterval? = nil
    ) -> CoverageRequirement {
        CoverageRequirement(
            feature: feature,
            repositoryID: nil,
            streamID: streamID,
            intervalStart: interval?.start,
            intervalEnd: interval?.end
        )
    }
}
