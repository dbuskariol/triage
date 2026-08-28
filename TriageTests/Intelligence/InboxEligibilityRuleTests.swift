import XCTest
@testable import Triage

final class InboxEligibilityRuleTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    func testLocalWorkflowStateHasDocumentedPrecedence() {
        let rule = InboxEligibilityRule()
        XCTAssertEqual(
            rule.disposition(
                for: makeWorkItem(
                    state: .inaccessible,
                    workflow: WorkflowState(
                        status: .archived,
                        snoozedUntil: now.addingTimeInterval(1),
                        updatedAt: now
                    )
                ),
                at: now
            ),
            .inaccessible
        )
        XCTAssertEqual(
            rule.disposition(
                for: makeWorkItem(
                    workflow: WorkflowState(
                        status: .archived,
                        snoozedUntil: now.addingTimeInterval(1),
                        updatedAt: now
                    )
                ),
                at: now
            ),
            .snoozed
        )
        XCTAssertEqual(
            rule.disposition(
                for: makeWorkItem(workflow: WorkflowState(status: .waiting, updatedAt: now)),
                at: now
            ),
            .waiting
        )
    }

    func testResolvedWorkWithoutOpenActionsLeavesInbox() {
        XCTAssertEqual(
            InboxEligibilityRule().disposition(
                for: makeWorkItem(state: .resolved),
                at: now
            ),
            .resolved
        )
    }

    func testAttentionOrOpenActionsEnterInbox() {
        XCTAssertEqual(
            InboxEligibilityRule().disposition(
                for: makeWorkItem(reasons: [makeReason()]),
                at: now
            ),
            .inbox
        )
    }

    private func makeWorkItem(
        state: WorkItemState = .active,
        workflow: WorkflowState? = nil,
        reasons: [AttentionReason] = []
    ) -> WorkItem {
        WorkItem(
            id: WorkItemID.make(),
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: "github")!,
            primaryNodeID: GitHubNodeID(rawValue: "I_kwDOExample")!,
            title: "Example",
            state: state,
            sourceKind: .issue,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: reasons,
            actionItems: [],
            workflow: workflow ?? WorkflowState(updatedAt: now),
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
    }

    private func makeReason() -> AttentionReason {
        AttentionReason(
            id: "assigned",
            category: .directResponsibility,
            ruleID: "assigned",
            ruleVersion: 1,
            strength: 850,
            title: "Assigned",
            explanation: "Assigned to you.",
            evidence: [],
            evaluatedAt: now
        )
    }
}
