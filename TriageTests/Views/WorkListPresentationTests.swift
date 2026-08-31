import XCTest
@testable import Triage

final class WorkListPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    func testAccessibilityLabelIncludesVisibleWorkflowFreshnessAndActionSemantics() {
        let label = WorkListPresentation.accessibilityLabel(
            for: makeWorkItem(
                workflow: WorkflowState(
                    status: .waiting,
                    isPinned: true,
                    priority: .high,
                    snoozedUntil: now.addingTimeInterval(3_600),
                    followUpAt: now.addingTimeInterval(7_200),
                    updatedAt: now
                ),
                freshness: .partial,
                actions: [actionItem(state: .open), actionItem(id: "done", state: .completed)]
            ),
            at: now
        )

        XCTAssertTrue(label.contains("Pull Request, Resolve review feedback"))
        XCTAssertTrue(label.contains("Repository octo/Triage"))
        XCTAssertTrue(label.contains("Attention: Review requested"))
        XCTAssertTrue(label.contains("Pinned in Triage"))
        XCTAssertTrue(label.contains("Waiting in Triage"))
        XCTAssertTrue(label.contains("High priority in Triage"))
        XCTAssertTrue(label.contains("Snoozed until"))
        XCTAssertTrue(label.contains("Follow up"))
        XCTAssertTrue(label.contains("1 open action item"))
        XCTAssertTrue(label.contains("Freshness: Partial coverage"))
    }

    func testSearchResultGateRejectsCancelledAndSupersededRequests() {
        let initial = WorkListSearchRequest(
            accountID: AccountID(rawValue: "account-a"),
            organizationID: OrganizationID(rawValue: "org-a"),
            query: " review "
        )
        let replacement = WorkListSearchRequest(
            accountID: AccountID(rawValue: "account-b"),
            organizationID: OrganizationID(rawValue: "org-b"),
            query: "review"
        )

        XCTAssertTrue(WorkListPresentation.shouldApplySearchResult(
            for: initial,
            currentRequest: initial,
            isCancelled: false
        ))
        XCTAssertFalse(WorkListPresentation.shouldApplySearchResult(
            for: initial,
            currentRequest: replacement,
            isCancelled: false
        ))
        XCTAssertFalse(WorkListPresentation.shouldApplySearchResult(
            for: initial,
            currentRequest: initial,
            isCancelled: true
        ))
    }

    func testSelectionRestorationBindingTracksExactScopeAndAvailableItems() {
        let itemA = WorkItemID(rawValue: "work-a")!
        let itemB = WorkItemID(rawValue: "work-b")!
        let baseline = WorkListSelectionRestorationRequest(
            accountID: AccountID(rawValue: "account-a"),
            organizationID: OrganizationID(rawValue: "org-a"),
            validWorkItemIDs: [itemA]
        )

        XCTAssertNotEqual(
            baseline,
            WorkListSelectionRestorationRequest(
                accountID: AccountID(rawValue: "account-b"),
                organizationID: OrganizationID(rawValue: "org-a"),
                validWorkItemIDs: [itemA]
            )
        )
        XCTAssertNotEqual(
            baseline,
            WorkListSelectionRestorationRequest(
                accountID: AccountID(rawValue: "account-a"),
                organizationID: OrganizationID(rawValue: "org-b"),
                validWorkItemIDs: [itemA]
            )
        )
        XCTAssertNotEqual(
            baseline,
            WorkListSelectionRestorationRequest(
                accountID: AccountID(rawValue: "account-a"),
                organizationID: OrganizationID(rawValue: "org-a"),
                validWorkItemIDs: [itemB]
            )
        )
    }

    func testContextMenuPolicyMatchesActiveWorkflowCommandAvailability() {
        let item = makeWorkItem(
            workflow: WorkflowState(status: .active, updatedAt: now),
            freshness: .fresh,
            actions: []
        )

        let policy = WorkItemContextMenuPolicy(item: item)

        XCTAssertEqual(policy.archiveOperation, .archive)
        XCTAssertEqual(policy.pinOperation, .setPinned(true))
        XCTAssertEqual(policy.priorityOperations, [.setPriority(.low), .setPriority(.normal), .setPriority(.high)])
        XCTAssertEqual(policy.snoozeOperations, [.snooze(.oneHour), .snooze(.tomorrow), .snooze(.nextWeek)])
        XCTAssertNil(policy.clearSnoozeOperation)
        XCTAssertEqual(policy.waitingOperation, .markWaiting)
        XCTAssertTrue(WorkItemContextMenuPolicy.localOnlyAccessibilityHint.contains("does not modify GitHub"))
    }

    func testContextMenuPolicyRestoresArchivedAndClearsExistingWorkflowStates() {
        let item = makeWorkItem(
            workflow: WorkflowState(
                status: .archived,
                isPinned: true,
                snoozedUntil: now.addingTimeInterval(3_600),
                updatedAt: now
            ),
            freshness: .fresh,
            actions: []
        )

        let policy = WorkItemContextMenuPolicy(item: item)

        XCTAssertEqual(policy.archiveOperation, .unarchive)
        XCTAssertEqual(policy.pinOperation, .setPinned(false))
        XCTAssertTrue(policy.snoozeOperations.isEmpty)
        XCTAssertEqual(policy.clearSnoozeOperation, .clearSnooze)
        XCTAssertNil(policy.waitingOperation)
    }

    func testContextMenuPolicyStopsWaitingRatherThanMarkingItAgain() {
        let item = makeWorkItem(
            workflow: WorkflowState(status: .waiting, updatedAt: now),
            freshness: .fresh,
            actions: []
        )

        XCTAssertEqual(WorkItemContextMenuPolicy(item: item).waitingOperation, .clearWaiting)
    }

    func testContextMenuOperationsMapOnlyToExistingLocalWorkflowActions() {
        let original = WorkflowState(status: .active, updatedAt: now)
        let archive = WorkItemContextMenuOperation.archive.workflowAction(now: now)
        let snooze = WorkItemContextMenuOperation.snooze(.oneHour).workflowAction(now: now)

        XCTAssertEqual(WorkflowTransitionEngine.apply(archive, to: original, at: now).next.status, .archived)
        guard case let .snooze(until: snoozedUntil) = snooze else {
            return XCTFail("The one-hour context menu action must use the local snooze workflow action.")
        }
        XCTAssertEqual(snoozedUntil, now.addingTimeInterval(3_600))
    }

    private func makeWorkItem(
        workflow: WorkflowState,
        freshness: FreshnessStatus,
        actions: [ActionItem]
    ) -> WorkItem {
        WorkItem(
            id: WorkItemID(rawValue: "work")!,
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "organization")!,
            primaryNodeID: GitHubNodeID(rawValue: "node")!,
            title: "Resolve review feedback",
            state: .active,
            sourceKind: .pullRequest,
            sourceURL: nil,
            repository: RepositorySummary(
                id: RepositoryID(rawValue: "repository")!,
                nodeID: GitHubNodeID(rawValue: "repository-node")!,
                ownerLogin: "octo",
                name: "Triage",
                isPrivate: true,
                isArchived: false,
                hasDiscussions: true,
                url: URL(string: "https://github.com/octo/Triage")!
            ),
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: [
                AttentionReason(
                    id: "review-requested",
                    category: .pullRequest,
                    ruleID: "review-requested",
                    ruleVersion: 1,
                    strength: 100,
                    title: "Review requested",
                    explanation: "A review is requested.",
                    evidence: [],
                    evaluatedAt: now
                )
            ],
            actionItems: actions,
            workflow: workflow,
            freshness: FreshnessState(status: freshness),
            lastRelevantActivityAt: now,
            score: AttentionScore(value: 1, breakdown: [:])
        )
    }

    private func actionItem(
        id: String = "open",
        state: ActionItemState
    ) -> ActionItem {
        ActionItem(
            id: ActionItemID(rawValue: id)!,
            workItemID: WorkItemID(rawValue: "work")!,
            title: "Respond",
            origin: .manual,
            state: state,
            priority: .normal,
            createdAt: now,
            updatedAt: now
        )
    }
}
