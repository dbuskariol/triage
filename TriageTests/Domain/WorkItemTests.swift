import XCTest
@testable import Triage

final class WorkItemTests: XCTestCase {
    func testArchivedAndSnoozedItemsAreExcludedFromInbox() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        var item = makeWorkItem(
            workflow: WorkflowState(status: .archived, updatedAt: date)
        )

        XCTAssertFalse(item.isVisibleInInbox(at: date))

        item = makeWorkItem(
            workflow: WorkflowState(
                isPinned: true,
                snoozedUntil: date.addingTimeInterval(1),
                updatedAt: date
            )
        )
        XCTAssertFalse(item.isVisibleInInbox(at: date))
    }

    func testPinMakesAnOtherwiseInformationalItemVisibleInInbox() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let item = makeWorkItem(
            workflow: WorkflowState(isPinned: true, updatedAt: date)
        )

        XCTAssertTrue(item.isVisibleInInbox(at: date))
    }

    func testOpenActionsAreSelectedWithoutIncludingDismissedHistory() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let workItemID = WorkItemID.make()
        let item = makeWorkItem(
            id: workItemID,
            actionItems: [
                ActionItem(
                    id: ActionItemID.make(),
                    workItemID: workItemID,
                    title: "Respond",
                    origin: .manual,
                    state: .open,
                    createdAt: date,
                    updatedAt: date
                ),
                ActionItem(
                    id: ActionItemID.make(),
                    workItemID: workItemID,
                    title: "Old suggestion",
                    origin: .copilot,
                    state: .dismissed,
                    createdAt: date,
                    updatedAt: date,
                    dismissedAt: date
                )
            ]
        )

        XCTAssertEqual(item.openActionItems.count, 1)
        XCTAssertEqual(item.openActionItems.first?.title, "Respond")
    }

    func testReplacementChangesOnlyTheRequestedWorkItemState() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let item = makeWorkItem()
        let replacement = WorkflowState(
            status: .waiting,
            isPinned: true,
            priority: .high,
            followUpAt: date.addingTimeInterval(60),
            updatedAt: date
        )

        let updated = item.replacing(workflow: replacement)

        XCTAssertEqual(updated.id, item.id)
        XCTAssertEqual(updated.primaryNodeID, item.primaryNodeID)
        XCTAssertEqual(updated.title, item.title)
        XCTAssertEqual(updated.score, item.score)
        XCTAssertEqual(updated.workflow, replacement)
    }

    func testGroupingStrengthHasStrictStableOrder() {
        XCTAssertLessThan(GroupingStrength.contextual, .strong)
        XCTAssertLessThan(GroupingStrength.strong, .userConfirmed)
        XCTAssertFalse(GroupingStrength.contextual < .contextual)
        XCTAssertFalse(GroupingStrength.userConfirmed < .strong)
    }

    func testUnknownWorkItemEnumValuesAreRejected() {
        assertUnknownCaseRejected(WorkItemState.self)
        assertUnknownCaseRejected(WorkItemMemberRole.self)
        assertUnknownCaseRejected(GroupingStrength.self)
    }

    func testFullWorkGraphRoundTripsWithoutLosingProvenance() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let nodeID = GitHubNodeID(rawValue: "node-1")!
        let content = GitHubContentSummary(
            id: nodeID,
            kind: .issue,
            repository: nil,
            number: 1,
            title: "Work item",
            state: .open,
            author: nil,
            url: URL(string: "https://github.com/github/triage/issues/1")!,
            createdAt: date,
            updatedAt: date,
            closedAt: nil,
            mergedAt: nil
        )
        let evidence = EvidenceReference(
            id: EvidenceID(rawValue: "evidence-1")!,
            source: .restSearch,
            nodeID: nodeID,
            observedAt: date
        )
        let relation = WorkRelation(
            kind: .assigned,
            subjectNodeID: nodeID,
            objectNodeID: nil,
            confidence: .confirmed,
            evidence: [evidence],
            observedAt: date
        )
        let workItemID = WorkItemID(rawValue: "work-1")!
        let action = ActionItem(
            id: ActionItemID(rawValue: "action-1")!,
            workItemID: workItemID,
            title: "Respond",
            origin: .manual,
            createdAt: date,
            updatedAt: date
        )
        let item = WorkItem(
            id: workItemID,
            accountID: AccountID(rawValue: "account-1")!,
            organizationID: OrganizationID(rawValue: "organization-1")!,
            primaryNodeID: nodeID,
            title: "Work item",
            state: .active,
            sourceKind: .issue,
            sourceURL: content.url,
            repository: nil,
            members: [WorkItemMember(id: nodeID, role: .primary, content: content, evidence: [evidence])],
            contextLinks: [WorkItemContextLink(
                id: GitHubNodeID(rawValue: "node-2")!,
                relation: .blocks,
                content: content,
                evidence: [evidence]
            )],
            relations: [relation],
            attentionReasons: [AttentionReason(
                id: "reason-1",
                category: .directResponsibility,
                ruleID: "assigned",
                ruleVersion: 1,
                strength: 50,
                title: "Assigned to you",
                explanation: "You are directly assigned.",
                evidence: [evidence],
                evaluatedAt: date
            )],
            actionItems: [action],
            workflow: WorkflowState(updatedAt: date),
            freshness: FreshnessState(status: .fresh, lastSuccessfulSyncAt: date),
            lastRelevantActivityAt: date,
            score: AttentionScore(value: 50, breakdown: ["assigned": 50])
        )
        let decision = WorkItemGroupingDecision(
            sourceNodeID: nodeID,
            destinationNodeID: GitHubNodeID(rawValue: "node-2")!,
            relation: .blocks,
            strength: .strong,
            evidence: [evidence],
            decidedAt: date
        )

        try assertRoundTrip(item)
        try assertRoundTrip(decision)
    }

    private func makeWorkItem(
        id: WorkItemID = .make(),
        workflow: WorkflowState? = nil,
        actionItems: [ActionItem] = []
    ) -> WorkItem {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let nodeID = GitHubNodeID(rawValue: "I_kwDOExample")!
        return WorkItem(
            id: id,
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: "github")!,
            primaryNodeID: nodeID,
            title: "Example work item",
            state: .active,
            sourceKind: .issue,
            sourceURL: nil,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: [],
            actionItems: actionItems,
            workflow: workflow ?? WorkflowState(updatedAt: date),
            freshness: FreshnessState(status: .fresh, lastSuccessfulSyncAt: date),
            lastRelevantActivityAt: date,
            score: AttentionScore(value: 0, breakdown: [:])
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
