import XCTest
@testable import Triage

final class WorkDetailPresentationTests: XCTestCase {
    func testPartialFreshnessNeverUsesCurrentLabel() {
        let freshness = FreshnessState(status: .partial)

        XCTAssertEqual(WorkDetailPresentation.freshnessTitle(freshness), "Partial coverage")
        XCTAssertNotEqual(WorkDetailPresentation.freshnessTitle(freshness), "Current")
        XCTAssertTrue(WorkDetailPresentation.freshnessDescription(freshness).contains("incomplete"))
    }

    func testEvidenceDeduplicatesAndOrdersNewestFirst() {
        let older = evidence(id: "older", observedAt: 1)
        let newer = evidence(id: "newer", observedAt: 2)
        let item = makeWorkItem(reasons: [reason(evidence: [older, newer])], relations: [relation(evidence: [older])])

        XCTAssertEqual(WorkDetailPresentation.allEvidence(for: item).map(\.id.rawValue), ["newer", "older"])
    }

    func testEmptyEvidenceIsExplicitlyUnavailable() {
        XCTAssertEqual(WorkDetailPresentation.availabilityTitle(for: makeWorkItem()), "No normalized evidence is available")
    }

    func testEveryNonFreshStateKeepsAvailableEvidenceExplicitlyIncomplete() {
        let sourceEvidence = evidence(id: "source", observedAt: 1)
        let nonFreshStates: [FreshnessStatus] = [
            .refreshing,
            .stale,
            .partial,
            .offline,
            .authenticationRequired,
            .ssoRequired,
            .approvalRequired,
            .rateLimited,
            .failed
        ]

        for status in nonFreshStates {
            let item = makeWorkItem(
                reasons: [reason(evidence: [sourceEvidence])],
                freshness: FreshnessState(status: status)
            )

            XCTAssertNotEqual(
                WorkDetailPresentation.freshnessTitle(item.freshness),
                "Current",
                "\(status.rawValue) must not be presented as current."
            )
            XCTAssertEqual(
                WorkDetailPresentation.availabilityTitle(for: item),
                "Evidence may be incomplete",
                "\(status.rawValue) must not turn locally available evidence into a completeness claim."
            )
        }
    }

    private func makeWorkItem(
        reasons: [AttentionReason] = [],
        relations: [WorkRelation] = [],
        freshness: FreshnessState = FreshnessState(status: .fresh)
    ) -> WorkItem {
        let accountID = AccountID(rawValue: "account")!
        let organizationID = OrganizationID(rawValue: "organization")!
        return WorkItem(
            id: WorkItemID(rawValue: "work")!,
            accountID: accountID,
            organizationID: organizationID,
            primaryNodeID: GitHubNodeID(rawValue: "node")!,
            title: "Title",
            state: .active,
            sourceKind: .issue,
            sourceURL: nil,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: relations,
            attentionReasons: reasons,
            actionItems: [],
            workflow: WorkflowState(updatedAt: .now),
            freshness: freshness,
            lastRelevantActivityAt: .now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
    }

    private func evidence(id: String, observedAt: TimeInterval) -> EvidenceReference {
        EvidenceReference(
            id: EvidenceID(rawValue: id)!,
            source: .restTimeline,
            locator: .endpoint("/timeline"),
            authority: .localWorkflow(
                accountID: AccountID(rawValue: "account")!,
                organizationID: OrganizationID(rawValue: "organization")!
            ),
            confidence: .confirmed,
            confirmation: .confirmed,
            observedAt: Date(timeIntervalSinceReferenceDate: observedAt)
        )
    }

    private func reason(evidence: [EvidenceReference]) -> AttentionReason {
        AttentionReason(
            id: "reason",
            category: .conversation,
            ruleID: "rule",
            ruleVersion: 1,
            strength: 1,
            title: "Reason",
            explanation: "Explanation",
            evidence: evidence,
            evaluatedAt: .now
        )
    }

    private func relation(evidence: [EvidenceReference]) -> WorkRelation {
        WorkRelation(
            kind: .mentioned,
            subjectNodeID: GitHubNodeID(rawValue: "node")!,
            objectNodeID: nil,
            confidence: .confirmed,
            evidence: evidence,
            observedAt: .now
        )
    }
}
