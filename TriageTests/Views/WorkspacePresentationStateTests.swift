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

    func testAuthoritativeFreshEmptyCoverageRemainsAnEmptyQueue() {
        let state = makeState(
            workItems: [],
            workspaceFreshness: FreshnessState(status: .fresh)
        )

        XCTAssertEqual(state.synchronizationStatus, .upToDate)
    }

    private func makeState(
        workItems: [WorkItem],
        access: OrganizationAccess? = nil,
        workspaceFreshness: FreshnessState? = nil
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
