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
        XCTAssertTrue(WorkListPresentation.shouldUseSearchResults(
            producedFor: initial,
            currentRequest: initial
        ))
        XCTAssertFalse(WorkListPresentation.shouldUseSearchResults(
            producedFor: initial,
            currentRequest: replacement
        ))
        XCTAssertFalse(WorkListPresentation.shouldUseSearchResults(
            producedFor: nil,
            currentRequest: initial
        ))
    }

    func testEmptyQueueSuccessCopyRequiresAnUpToDateWorkspaceWithoutSearchFailure() {
        XCTAssertTrue(WorkListPresentation.canPresentSuccessfulEmptyQueue(
            query: "  ",
            isSearching: false,
            searchError: nil,
            workspaceStatus: .upToDate
        ))

        for status in [
            WorkspacePresentationState.SynchronizationStatus.initialSynchronization,
            .refreshing,
            .partial,
            .ssoRequired,
            .approvalRequired,
            .offline,
            .signInRequired,
            .unavailable
        ] {
            XCTAssertFalse(WorkListPresentation.canPresentSuccessfulEmptyQueue(
                query: "",
                isSearching: false,
                searchError: nil,
                workspaceStatus: status
            ))
        }
        XCTAssertFalse(WorkListPresentation.canPresentSuccessfulEmptyQueue(
            query: "review",
            isSearching: false,
            searchError: nil,
            workspaceStatus: .upToDate
        ))
        XCTAssertFalse(WorkListPresentation.canPresentSuccessfulEmptyQueue(
            query: "review",
            isSearching: false,
            searchError: "Triage could not search its encrypted cache.",
            workspaceStatus: .upToDate
        ))
    }

    func testEmptyQueuePresentationRoutesSearchFailureBeforeNoMatch() {
        XCTAssertEqual(
            WorkListPresentation.emptyQueuePresentation(
                query: "review",
                isSearching: false,
                searchError: "Triage could not search its encrypted cache.",
                workspaceStatus: .upToDate
            ),
            .searchUnavailable
        )
        XCTAssertEqual(
            WorkListPresentation.emptyQueuePresentation(
                query: "review",
                isSearching: false,
                searchError: nil,
                workspaceStatus: .upToDate
            ),
            .noMatchingWork
        )
        XCTAssertEqual(
            WorkListPresentation.emptyQueuePresentation(
                query: "",
                isSearching: false,
                searchError: nil,
                workspaceStatus: .partial
            ),
            .workspaceStatus
        )
    }

    func testVisibleMetadataUsesOnlyAvailableCachedWorkflowAndResponsibilityFields() {
        let item = makeWorkItem(
            workflow: WorkflowState(
                status: .waiting,
                priority: .high,
                snoozedUntil: now.addingTimeInterval(3_600),
                updatedAt: now
            ),
            freshness: .partial,
            actions: [],
            relations: [relation(.assigned)]
        )

        let metadata = WorkListPresentation.visibleMetadata(for: item, at: now)

        XCTAssertTrue(metadata.contains("Assigned to you"))
        XCTAssertTrue(metadata.contains("High priority"))
        XCTAssertTrue(metadata.contains("Waiting"))
        XCTAssertTrue(metadata.contains(where: { $0.hasPrefix("Snoozed until ") }))
        XCTAssertTrue(metadata.contains("Partial coverage"))
        XCTAssertTrue(metadata.contains(where: { $0.hasPrefix("Activity ") }))
    }

    func testActionDisclosureNamesOnlyOpenLocalActionItems() {
        let openAction = actionItem(id: "open", state: .open)
        let completedAction = actionItem(id: "completed", state: .completed)
        let item = makeWorkItem(
            workflow: WorkflowState(updatedAt: now),
            freshness: .fresh,
            actions: [openAction, completedAction]
        )

        XCTAssertEqual(
            WorkListPresentation.actionDisclosure(for: item),
            WorkListActionDisclosure(
                title: "1 open action item",
                accessibilityLabel: "1 open action item, stored locally in Triage"
            )
        )
    }

    func testWaitingWakeUpAppearsInInboxAndKeepsItsPersistedRanking() {
        let wakeUp = makeWorkItem(
            id: "wake-up",
            workflow: WorkflowState(status: .waiting, updatedAt: now),
            freshness: .fresh,
            actions: [],
            attentionReasons: [
                AttentionReason(
                    id: "follow-up-due",
                    category: .waiting,
                    ruleID: WaitingAttentionRuleID.followUpDue.rawValue,
                    ruleVersion: 1,
                    strength: 5,
                    title: "Follow up due",
                    explanation: "The stored waiting follow-up is due.",
                    evidence: [],
                    evaluatedAt: now
                )
            ],
            score: 12
        )
        let stillWaiting = makeWorkItem(
            id: "still-waiting",
            workflow: WorkflowState(status: .waiting, updatedAt: now),
            freshness: .fresh,
            actions: [],
            attentionReasons: [],
            score: 500
        )

        XCTAssertEqual(
            WorkListPresentation.items(from: [stillWaiting, wakeUp], section: .inbox, at: now)
                .map(\.id.rawValue),
            ["wake-up"]
        )
        XCTAssertEqual(
            WorkListPresentation.items(from: [wakeUp, stillWaiting], section: .waiting, at: now)
                .map(\.id.rawValue),
            ["still-waiting"]
        )
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

    func testMultipleSelectionRetainsThePrimaryDetailItemUntilItIsDeselected() {
        let itemA = WorkItemID(rawValue: "work-a")!
        let itemB = WorkItemID(rawValue: "work-b")!
        let itemC = WorkItemID(rawValue: "work-c")!
        var selection = WorkListSelection()

        XCTAssertEqual(
            selection.applyNativeSelection([itemB], orderedWorkItemIDs: [itemA, itemB, itemC]),
            itemB
        )
        XCTAssertEqual(
            selection.applyNativeSelection([itemA, itemB], orderedWorkItemIDs: [itemA, itemB, itemC]),
            itemB
        )
        XCTAssertEqual(selection.selectedWorkItemIDs, [itemA, itemB])
        XCTAssertEqual(selection.primaryWorkItemID, itemB)

        XCTAssertEqual(
            selection.applyNativeSelection([itemA, itemC], orderedWorkItemIDs: [itemA, itemB, itemC]),
            itemC
        )
        XCTAssertEqual(selection.primaryWorkItemID, itemC)
    }

    func testSelectionRestorationPreservesLocalMultipleSelectionOnlyWithinItsWorkspace() {
        let account = AccountID(rawValue: "account")!
        let firstOrganization = OrganizationID(rawValue: "organization-a")!
        let secondOrganization = OrganizationID(rawValue: "organization-b")!
        let itemA = WorkItemID(rawValue: "work-a")!
        let itemB = WorkItemID(rawValue: "work-b")!
        var selection = WorkListSelection()
        let firstRequest = WorkListSelectionRestorationRequest(
            accountID: account,
            organizationID: firstOrganization,
            validWorkItemIDs: [itemA, itemB]
        )

        selection.restore(primaryWorkItemID: itemA, request: firstRequest)
        XCTAssertEqual(
            selection.applyNativeSelection([itemA, itemB], orderedWorkItemIDs: [itemA, itemB]),
            itemA
        )
        selection.restore(primaryWorkItemID: itemA, request: firstRequest)
        XCTAssertEqual(selection.selectedWorkItemIDs, [itemA, itemB])

        selection.restore(
            primaryWorkItemID: itemB,
            request: WorkListSelectionRestorationRequest(
                accountID: account,
                organizationID: secondOrganization,
                validWorkItemIDs: [itemA, itemB]
            )
        )
        XCTAssertEqual(selection.selectedWorkItemIDs, [itemB])
        XCTAssertEqual(selection.primaryWorkItemID, itemB)
    }

    func testContextualSelectionPreservesItsExistingMultiSelectionAndExternalHistoryStaysSingle() {
        let itemA = WorkItemID(rawValue: "work-a")!
        let itemB = WorkItemID(rawValue: "work-b")!
        var selection = WorkListSelection()

        _ = selection.applyNativeSelection([itemA, itemB], orderedWorkItemIDs: [itemA, itemB])
        selection.selectContextualWorkItem(itemB)
        XCTAssertEqual(selection.selectedWorkItemIDs, [itemA, itemB])
        XCTAssertEqual(selection.primaryWorkItemID, itemB)

        // The app model echoes the contextual target back through its primary
        // selection binding. That echo must preserve the native row set.
        selection.synchronizePrimarySelection(itemB)
        XCTAssertEqual(selection.selectedWorkItemIDs, [itemA, itemB])

        // A subsequent history target is external rather than contextual and
        // therefore becomes the list's single, visible selection.
        selection.synchronizePrimarySelection(itemA)
        XCTAssertEqual(selection.selectedWorkItemIDs, [itemA])
        XCTAssertEqual(selection.primaryWorkItemID, itemA)
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
        XCTAssertEqual(
            policy.snoozeOperations,
            [.snoozeAfter(3_600), .snoozeAfter(86_400), .snoozeAfter(7 * 86_400)]
        )
        XCTAssertNil(policy.clearSnoozeOperation)
        XCTAssertEqual(policy.waitingOperation, .markWaiting)
        XCTAssertTrue(WorkItemContextMenuPolicy.localOnlyAccessibilityHint.contains("does not modify GitHub"))

        let configured = WorkItemContextMenuPolicy(
            item: item,
            snoozeDurations: InboxSnoozeDurations(
                firstMinutes: 30,
                secondMinutes: 180,
                thirdMinutes: 1_440
            )!
        )
        XCTAssertEqual(
            configured.snoozeOperations,
            [.snoozeAfter(1_800), .snoozeAfter(10_800), .snoozeAfter(86_400)]
        )
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
        let snooze = WorkItemContextMenuOperation.snoozeAfter(3_600).workflowAction(now: now)
        let configuredSnooze = WorkItemContextMenuOperation.snoozeAfter(1_800).workflowAction(now: now)

        XCTAssertEqual(WorkflowTransitionEngine.apply(archive, to: original, at: now).next.status, .archived)
        guard case let .snooze(until: snoozedUntil) = snooze else {
            return XCTFail("The configured context-menu action must use the local snooze workflow action.")
        }
        XCTAssertEqual(snoozedUntil, now.addingTimeInterval(3_600))
        guard case let .snooze(until: configuredSnoozedUntil) = configuredSnooze else {
            return XCTFail("A configured duration must map to the same local snooze workflow action.")
        }
        XCTAssertEqual(configuredSnoozedUntil, now.addingTimeInterval(1_800))
    }

    func testInboxDefaultSortCanPreferRecentActivityWithoutChangingOtherViews() {
        let older = makeWorkItem(
            id: "older",
            workflow: WorkflowState(status: .active, updatedAt: now),
            freshness: .fresh,
            actions: [],
            score: 20
        )
        let newer = WorkItem(
            id: WorkItemID(rawValue: "newer")!,
            accountID: older.accountID,
            organizationID: older.organizationID,
            primaryNodeID: GitHubNodeID(rawValue: "node-newer")!,
            title: "newer",
            state: .active,
            sourceKind: .issue,
            sourceURL: nil,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: older.relations,
            attentionReasons: older.attentionReasons,
            actionItems: [],
            workflow: WorkflowState(status: .active, updatedAt: now),
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: older.lastRelevantActivityAt.addingTimeInterval(60),
            score: AttentionScore(value: 1, breakdown: [:])
        )

        let items = WorkListPresentation.items(
            from: [older, newer],
            section: .inbox,
            at: now,
            inboxDefaultSort: .recentActivity
        )

        XCTAssertEqual(items.map(\.id), [newer.id, older.id])
    }

    private func makeWorkItem(
        id: String = "work",
        workflow: WorkflowState,
        freshness: FreshnessStatus,
        actions: [ActionItem],
        relations: [WorkRelation] = [],
        attentionReasons: [AttentionReason]? = nil,
        score: Int = 1
    ) -> WorkItem {
        WorkItem(
            id: WorkItemID(rawValue: id)!,
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
            relations: relations,
            attentionReasons: attentionReasons ?? [
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
            score: AttentionScore(value: score, breakdown: [:])
        )
    }

    private func relation(_ kind: WorkRelationKind) -> WorkRelation {
        WorkRelation(
            kind: kind,
            subjectNodeID: GitHubNodeID(rawValue: "subject")!,
            objectNodeID: nil,
            confidence: .confirmed,
            evidence: [],
            observedAt: now
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
