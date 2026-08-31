import SwiftUI
import XCTest
@testable import Triage

final class WorkspacePresentationStateTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)
    private let accountID = AccountID(rawValue: "account")!
    private let organizationID = OrganizationID(rawValue: "github")!

    func testCountsRepresentEachSidebarWorkViewWithoutChangingSelection() {
        let inbox = makeWorkItem(
            id: "inbox",
            relations: [relation(.assigned)],
            reasons: [reason()]
        )
        let review = makeWorkItem(
            id: "review",
            relations: [relation(.reviewRequestedDirectly)]
        )
        let waiting = makeWorkItem(
            id: "waiting",
            workflow: WorkflowState(status: .waiting, updatedAt: now)
        )
        let snoozed = makeWorkItem(
            id: "snoozed",
            workflow: WorkflowState(snoozedUntil: now.addingTimeInterval(60), updatedAt: now)
        )

        let state = makeState(workItems: [inbox, review, waiting, snoozed])

        XCTAssertEqual(state.selectedAccountID, accountID)
        XCTAssertEqual(state.selectedOrganizationID, organizationID)
        XCTAssertEqual(state.count(for: .inbox), 1)
        XCTAssertEqual(state.count(for: .myWork), 1)
        XCTAssertEqual(state.count(for: .reviews), 1)
        XCTAssertEqual(state.count(for: .waiting), 1)
        XCTAssertEqual(state.count(for: .snoozed), 1)
        XCTAssertEqual(state.count(for: .allWork), 4)
    }

    func testSSOStatusTakesPrecedenceOverCachedItemFreshness() {
        let state = makeState(
            workItems: [makeWorkItem(id: "fresh", freshness: .fresh)],
            access: organizationAccess(state: .ssoAuthorizationRequired)
        )

        XCTAssertEqual(state.synchronizationStatus, .ssoRequired)
        XCTAssertEqual(
            state.synchronizationDetail,
            "Authorize this account with your organization to refresh its work."
        )
    }

    func testOrganizationApprovalIsPresentedSeparatelyFromPartialAccess() {
        let state = makeState(
            workItems: [makeWorkItem(id: "fresh", freshness: .fresh)],
            access: organizationAccess(state: .organizationApprovalRequired)
        )

        XCTAssertEqual(state.synchronizationStatus, .approvalRequired)
        XCTAssertEqual(
            state.synchronizationDetail,
            "Your organization must approve this account or application before all work can sync."
        )
    }

    func testOfflineCachedWorkIsPresentedAsOffline() {
        let state = makeState(
            workItems: [
                makeWorkItem(
                    id: "offline",
                    freshness: .offline,
                    freshnessDetail: "Network connection is unavailable."
                )
            ]
        )

        XCTAssertEqual(state.synchronizationStatus, .offline)
        XCTAssertEqual(state.synchronizationDetail, "Network connection is unavailable.")
    }

    func testPartialWorkspaceFreshnessCannotRenderFreshCachedItemsAsUpToDate() {
        let state = makeState(
            workItems: [makeWorkItem(id: "fresh", freshness: .fresh)],
            workspaceFreshness: FreshnessState(
                status: .partial,
                detail: "Review-thread coverage is incomplete."
            )
        )

        XCTAssertEqual(state.synchronizationStatus, .partial)
        XCTAssertEqual(state.synchronizationDetail, "Review-thread coverage is incomplete.")
    }

    func testIncompleteOrganizationVisibilityCannotRenderFreshWorkspaceAsUpToDate() {
        let state = makeState(
            workItems: [makeWorkItem(id: "fresh", freshness: .fresh)],
            workspaceFreshness: FreshnessState(status: .fresh),
            organizationVisibilityFreshness: FreshnessState(
                status: .partial,
                detail: "Organization visibility could not be refreshed. Showing saved organizations."
            )
        )

        XCTAssertEqual(state.synchronizationStatus, .partial)
        XCTAssertEqual(
            state.synchronizationDetail,
            "Organization visibility could not be refreshed. Showing saved organizations."
        )
    }

    func testCachedPartialItemPreservesItsConcreteCoverageDetail() {
        let state = makeState(
            workItems: [
                makeWorkItem(
                    id: "partial",
                    freshness: .partial,
                    freshnessDetail: "Discussion reply coverage is incomplete."
                )
            ]
        )

        XCTAssertEqual(state.synchronizationStatus, .partial)
        XCTAssertEqual(state.synchronizationDetail, "Discussion reply coverage is incomplete.")
    }

    func testSSOWorkspaceFreshnessCannotRenderFreshCachedItemsAsUpToDate() {
        let state = makeState(
            workItems: [makeWorkItem(id: "fresh", freshness: .fresh)],
            workspaceFreshness: FreshnessState(
                status: .ssoRequired,
                detail: "GitHub organization SSO authorization is required."
            )
        )

        XCTAssertEqual(state.synchronizationStatus, .ssoRequired)
        XCTAssertNotEqual(state.synchronizationStatus, .upToDate)
    }

    func testStaleWorkspaceFreshnessCannotRenderFreshCachedItemsAsUpToDate() {
        let state = makeState(
            workItems: [makeWorkItem(id: "fresh", freshness: .fresh)],
            workspaceFreshness: FreshnessState(
                status: .stale,
                detail: "No current-revision coverage is available."
            )
        )

        XCTAssertEqual(state.synchronizationStatus, .partial)
        XCTAssertNotEqual(state.synchronizationStatus, .upToDate)
    }

    func testFreshWorkspaceFreshnessRendersUpToDate() {
        let state = makeState(
            workItems: [makeWorkItem(id: "cached", freshness: .partial)],
            workspaceFreshness: FreshnessState(status: .fresh)
        )

        XCTAssertEqual(state.synchronizationStatus, .upToDate)
        XCTAssertTrue(state.canPresentSuccessfulEmptyQueue)
    }

    func testObservationFailureOverridesPriorFreshWorkspaceWhileKeepingCachedRows() {
        let state = WorkspacePresentationState(
            workItems: [makeWorkItem(id: "cached", freshness: .fresh)],
            selectedAccountID: accountID,
            selectedOrganizationID: organizationID,
            organizationAccess: nil,
            hasSSOAuthorizationHeader: false,
            isRefreshing: false,
            refreshError: "Triage could not update this workspace. Cached work remains available.",
            workspaceFreshness: FreshnessState(status: .fresh),
            now: now
        )

        XCTAssertEqual(state.synchronizationStatus, .partial)
        XCTAssertEqual(
            state.synchronizationDetail,
            "Triage could not update this workspace. Cached work remains available."
        )
        XCTAssertFalse(state.canPresentSuccessfulEmptyQueue)
    }

    func testIncompleteCurrentRevisionCoverageOverridesFreshWorkspaceStatus() {
        let state = makeState(
            workItems: [makeWorkItem(id: "fresh", freshness: .fresh)],
            workspaceFreshness: FreshnessState(status: .fresh),
            workspaceCoverage: CoverageEvaluation(
                freshness: FreshnessState(
                    status: .partial,
                    detail: "3 coverage requirements incomplete."
                ),
                missing: []
            )
        )

        XCTAssertEqual(state.synchronizationStatus, .partial)
        XCTAssertEqual(state.synchronizationDetail, "3 coverage requirements incomplete.")
        XCTAssertFalse(state.canPresentSuccessfulEmptyQueue)
    }

    func testEveryNonSuccessfulStatusRejectsSuccessfulEmptyQueueCopy() {
        for status in [
            WorkspacePresentationState.SynchronizationStatus.noAccount,
            .noOrganization,
            .initialSynchronization,
            .refreshing,
            .partial,
            .ssoRequired,
            .approvalRequired,
            .offline,
            .signInRequired,
            .unavailable
        ] {
            XCTAssertFalse(
                WorkspacePresentationState.emptyQueueCanUseSuccessCopy(for: status),
                "\(status) must not present success-empty copy."
            )
        }
        XCTAssertTrue(WorkspacePresentationState.emptyQueueCanUseSuccessCopy(for: .upToDate))
    }

    func testSynchronizationPresentationExposesWorkspaceLastSuccessfulSync() {
        let successfulAt = now.addingTimeInterval(-3_600)
        let state = makeState(
            workItems: [makeWorkItem(id: "cached", freshness: .partial)],
            workspaceFreshness: FreshnessState(
                status: .partial,
                lastSuccessfulSyncAt: successfulAt,
                detail: "Review-thread coverage is incomplete."
            )
        )

        XCTAssertEqual(state.lastSuccessfulSyncAt, successfulAt)
        XCTAssertEqual(state.synchronizationDetail, "Review-thread coverage is incomplete.")
    }

    @MainActor
    func testSidebarStatusRetainsOnlyOneVisibleSecondaryLine() {
        let lastSuccessfulSyncAt = now.addingTimeInterval(-3_600)
        let label = SynchronizationStatusLabel(
            status: .partial,
            detail: "Review-thread coverage is incomplete.",
            lastSuccessfulSyncAt: lastSuccessfulSyncAt
        )

        let secondaryText = label.secondaryText
        let accessibilityLabel = label.accessibilityLabel

        XCTAssertEqual(secondaryText, "Review-thread coverage is incomplete.")
        XCTAssertEqual(
            accessibilityLabel,
            "Partial access. Review-thread coverage is incomplete. Last successful sync \(lastSuccessfulSyncAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    @MainActor
    func testSidebarStatusAccessibilitySeparatesFragmentsWithoutDuplicatingTerminalPunctuation() {
        let lastSuccessfulSyncAt = now.addingTimeInterval(-3_600)
        let timestamp = lastSuccessfulSyncAt.formatted(date: .abbreviated, time: .shortened)

        for (detail, expected) in [
            ("Coverage is incomplete", "Partial access. Coverage is incomplete. Last successful sync \(timestamp)"),
            ("Coverage is incomplete!", "Partial access. Coverage is incomplete! Last successful sync \(timestamp)"),
            ("Coverage is incomplete?", "Partial access. Coverage is incomplete? Last successful sync \(timestamp)")
        ] {
            let label = SynchronizationStatusLabel(
                status: .partial,
                detail: detail,
                lastSuccessfulSyncAt: lastSuccessfulSyncAt
            )
            let accessibilityLabel = label.accessibilityLabel

            XCTAssertEqual(accessibilityLabel, expected)
            XCTAssertFalse(accessibilityLabel.contains(".."))
        }
    }

    func testExplicitOrganizationAccessTakesPrecedenceOverWorkspaceFreshness() {
        let state = makeState(
            workItems: [makeWorkItem(id: "fresh", freshness: .fresh)],
            access: organizationAccess(state: .organizationApprovalRequired),
            workspaceFreshness: FreshnessState(status: .fresh)
        )

        XCTAssertEqual(state.synchronizationStatus, .approvalRequired)
    }

    func testNoAccountIsExplicitEvenWhenStalePresentationDataExists() {
        let state = WorkspacePresentationState(
            workItems: [makeWorkItem(id: "cached", freshness: .fresh)],
            selectedAccountID: nil,
            selectedOrganizationID: organizationID,
            organizationAccess: nil,
            hasSSOAuthorizationHeader: false,
            isRefreshing: false,
            refreshError: nil,
            now: now
        )

        XCTAssertEqual(state.synchronizationStatus, .noAccount)
        XCTAssertEqual(state.synchronizationDetail, "Connect a GitHub account to view work.")
    }

    func testNoOrganizationIsExplicitBeforeQueueState() {
        let state = WorkspacePresentationState(
            workItems: [],
            selectedAccountID: accountID,
            selectedOrganizationID: nil,
            organizationAccess: nil,
            hasSSOAuthorizationHeader: false,
            isRefreshing: false,
            refreshError: nil,
            now: now
        )

        XCTAssertEqual(state.synchronizationStatus, .noOrganization)
        XCTAssertEqual(
            state.synchronizationDetail,
            "Choose an organization to view its local work queue."
        )
        XCTAssertEqual(state.count(for: .allWork), 0)
    }

    func testEmptyOrganizationWithoutCoverageIsReadyForInitialSynchronization() {
        let state = makeState(workItems: [])

        XCTAssertEqual(state.synchronizationStatus, .initialSynchronization)
        XCTAssertEqual(
            state.synchronizationDetail,
            "Synchronize this organization to create its local work queue."
        )
    }

    func testRefreshFailureDoesNotMasqueradeAsInitialSynchronization() {
        let state = WorkspacePresentationState(
            workItems: [],
            selectedAccountID: accountID,
            selectedOrganizationID: organizationID,
            organizationAccess: nil,
            hasSSOAuthorizationHeader: false,
            isRefreshing: false,
            refreshError: "GitHub did not complete the first synchronization.",
            now: now
        )

        XCTAssertEqual(state.synchronizationStatus, .partial)
        XCTAssertEqual(state.synchronizationDetail, "GitHub did not complete the first synchronization.")
    }

    func testCacheRestorationFailureWithoutRowsIsExplicitlyUnavailable() {
        let state = WorkspacePresentationState(
            workItems: [],
            selectedAccountID: accountID,
            selectedOrganizationID: organizationID,
            organizationAccess: nil,
            hasSSOAuthorizationHeader: false,
            isRefreshing: true,
            refreshError: nil,
            restorationError: "/private/path/to/vault could not be read",
            now: now
        )

        XCTAssertEqual(state.synchronizationStatus, .unavailable)
        XCTAssertEqual(state.synchronizationDetail, "Triage could not load local work for this organization.")
        XCTAssertTrue(state.shouldPresentUnavailableQueue)
        XCTAssertFalse(state.synchronizationDetail?.contains("/private/path") ?? true)
    }

    func testCacheRestorationFailureKeepsAvailableRowsVisibleAsPartial() {
        let state = WorkspacePresentationState(
            workItems: [makeWorkItem(id: "cached", freshness: .fresh)],
            selectedAccountID: accountID,
            selectedOrganizationID: organizationID,
            organizationAccess: nil,
            hasSSOAuthorizationHeader: false,
            isRefreshing: false,
            refreshError: nil,
            restorationError: "Database error",
            now: now
        )

        XCTAssertEqual(state.synchronizationStatus, .partial)
        XCTAssertEqual(
            state.synchronizationDetail,
            "Triage could not load all local work for this organization. Showing available local work."
        )
        XCTAssertFalse(state.shouldPresentUnavailableQueue)
    }

    func testAuthoritativeFreshEmptyCoverageRemainsAnEmptyQueue() {
        let state = makeState(
            workItems: [],
            workspaceFreshness: FreshnessState(status: .fresh)
        )

        XCTAssertEqual(state.synchronizationStatus, .upToDate)
    }

    func testSidebarSynchronizationStatusIsReservedForAttentionStates() {
        XCTAssertFalse(WorkspaceSidebarPresentation.showsSynchronizationStatus(.upToDate))
        XCTAssertFalse(WorkspaceSidebarPresentation.showsSynchronizationStatus(.refreshing))
        XCTAssertTrue(WorkspaceSidebarPresentation.showsSynchronizationStatus(.partial))
        XCTAssertTrue(WorkspaceSidebarPresentation.showsSynchronizationStatus(.ssoRequired))
        XCTAssertTrue(WorkspaceSidebarPresentation.showsSynchronizationStatus(.offline))
    }

    func testSystemDetailOnlySplitStateDoesNotOverwriteSidebarPreference() {
        var splitState = WorkspaceSplitViewVisibilityState(isSidebarVisible: true)

        splitState.receiveSystemVisibility(.detailOnly)

        XCTAssertEqual(splitState.visibility, .detailOnly)
        XCTAssertFalse(splitState.isSidebarPresented)
        XCTAssertTrue(splitState.shouldShowPrincipalOrganizationTitle)

        splitState.applyExplicitSidebarPreference(false)
        XCTAssertEqual(splitState.visibility, .doubleColumn)
        XCTAssertFalse(splitState.isSidebarPresented)
        XCTAssertTrue(splitState.shouldShowPrincipalOrganizationTitle)

        splitState.applyExplicitSidebarPreference(true)
        XCTAssertEqual(splitState.visibility, .all)
        XCTAssertTrue(splitState.isSidebarPresented)
        XCTAssertFalse(splitState.shouldShowPrincipalOrganizationTitle)
    }

    private func makeState(
        workItems: [WorkItem],
        access: OrganizationAccess? = nil,
        workspaceFreshness: FreshnessState? = nil,
        workspaceCoverage: CoverageEvaluation? = nil,
        organizationVisibilityFreshness: FreshnessState? = nil
    ) -> WorkspacePresentationState {
        WorkspacePresentationState(
            workItems: workItems,
            selectedAccountID: accountID,
            selectedOrganizationID: organizationID,
            organizationAccess: access,
            hasSSOAuthorizationHeader: false,
            isRefreshing: false,
            refreshError: nil,
            workspaceFreshness: workspaceFreshness,
            workspaceCoverage: workspaceCoverage,
            organizationVisibilityFreshness: organizationVisibilityFreshness,
            now: now
        )
    }

    private func makeWorkItem(
        id: String,
        relations: [WorkRelation] = [],
        reasons: [AttentionReason] = [],
        workflow: WorkflowState? = nil,
        freshness: FreshnessStatus = .fresh,
        freshnessDetail: String? = nil
    ) -> WorkItem {
        WorkItem(
            id: WorkItemID(rawValue: id)!,
            accountID: accountID,
            organizationID: organizationID,
            primaryNodeID: GitHubNodeID(rawValue: "node-\(id)")!,
            title: id,
            state: .active,
            sourceKind: .issue,
            sourceURL: nil,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: relations,
            attentionReasons: reasons,
            actionItems: [],
            workflow: workflow ?? WorkflowState(updatedAt: now),
            freshness: FreshnessState(status: freshness, detail: freshnessDetail),
            lastRelevantActivityAt: now,
            score: AttentionScore(value: 0, breakdown: [:])
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

    private func reason() -> AttentionReason {
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

    private func organizationAccess(state: OrganizationAccessState) -> OrganizationAccess {
        OrganizationAccess(
            accountID: accountID,
            organizationID: organizationID,
            state: state,
            capabilityRevision: CapabilityRevision(rawValue: "revision")!,
            capabilities: [],
            checkedAt: now
        )
    }
}
