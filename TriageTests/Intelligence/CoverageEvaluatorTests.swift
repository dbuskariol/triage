import XCTest
@testable import Triage

final class CoverageEvaluatorTests: XCTestCase {
    private let accountID = AccountID(rawValue: "account")!
    private let organizationID = OrganizationID(rawValue: "organization")!
    private let credentialRevision = CredentialRevision(rawValue: "credential")!
    private let capabilityRevision = CapabilityRevision(rawValue: "capability")!

    func testIncompleteCoverageCannotAppearComplete() {
        let requirement = CoverageRequirement(feature: .issues, repositoryID: nil)
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
        let requirement = CoverageRequirement(feature: .pullRequests, repositoryID: nil)
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
        let requirement = CoverageRequirement(feature: .issues, repositoryID: nil)
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
        let requirement = CoverageRequirement(feature: .issues, repositoryID: nil)
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

    private func record(feature: CoverageFeature, status: CoverageStatus) -> CoverageRecord {
        CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            feature: feature,
            streamID: SyncStreamID(rawValue: "stream")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            status: status,
            lastSuccessfulAt: .now,
            failureDetail: nil
        )
    }
}
