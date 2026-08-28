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
}
