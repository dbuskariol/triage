import Foundation
import XCTest
@testable import Triage

@MainActor
final class TriageAppModelSelectionTests: XCTestCase {
    private enum RuntimeStateCase: CustomStringConvertible {
        case downloading
        case verifying

        var description: String {
            switch self {
            case .downloading: "downloading"
            case .verifying: "verifying"
            }
        }
    }

    func testOAuthFailureMessageOnlyAllowsTheStableUnsupportedVersionRecovery() {
        let unsupportedVersion = AuthBrokerClientError.broker(
            AuthBrokerFailure(
                code: .invalidRequest,
                recoveryDescription: "This version of Triage is not supported by the OAuth service."
            )
        )
        XCTAssertEqual(
            TriageAppModel.oauthFailureMessage(
                for: unsupportedVersion,
                fallback: "GitHub sign-in could not be completed. Try again."
            ),
            "This version of Triage is not supported by the OAuth service. Update Triage to continue."
        )
        XCTAssertEqual(
            TriageAppModel.oauthFailureMessage(
                for: unsupportedVersion,
                fallback: "GitHub reconnect could not be completed. Try again."
            ),
            "This version of Triage is not supported by the OAuth service. Update Triage to continue."
        )

        let untrustedBrokerDetail = AuthBrokerClientError.broker(
            AuthBrokerFailure(code: .invalidGrant, recoveryDescription: "sensitive upstream detail")
        )
        XCTAssertEqual(
            TriageAppModel.oauthFailureMessage(
                for: untrustedBrokerDetail,
                fallback: "GitHub sign-in could not be completed. Try again."
            ),
            "GitHub sign-in could not be completed. Try again."
        )

        let unallowlistedInvalidRequest = AuthBrokerClientError.broker(
            AuthBrokerFailure(code: .invalidRequest, recoveryDescription: "untrusted broker detail")
        )
        XCTAssertEqual(
            TriageAppModel.oauthFailureMessage(
                for: unallowlistedInvalidRequest,
                fallback: "GitHub reconnect could not be completed. Try again."
            ),
            "GitHub reconnect could not be completed. Try again."
        )
    }

    func testRapidAToBToAOnlyPublishesFinalActivation() async {
        let controller = WorkspaceActivationTaskController()
        let barrier = ActivationBarrier()
        let recorder = PublicationRecorder()

        controller.replace { generation in
            await barrier.wait()
            guard controller.isCurrent(generation) else { return }
            recorder.append("first-A")
        }
        await barrier.waitForArrival()

        controller.replace { generation in
            guard controller.isCurrent(generation) else { return }
            recorder.append("B")
        }
        controller.replace { generation in
            guard controller.isCurrent(generation) else { return }
            recorder.append("final-A")
        }

        await barrier.release()
        await controller.waitForCurrentTask()

        XCTAssertEqual(recorder.values, ["final-A"])
        await controller.cancelAndWait()
    }

    func testWorkspaceCacheEvictsLeastRecentlyUsedWorkspace() {
        let account = AccountID.make()
        let first = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let second = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let third = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        var cache = WorkspacePresentationCache<Int>(capacity: 2)
        let firstScope = scope(account: account, organization: first)
        let secondScope = scope(account: account, organization: second)
        let thirdScope = scope(account: account, organization: third)

        cache[firstScope] = 1
        cache[secondScope] = 2
        XCTAssertEqual(cache[firstScope], 1) // refresh first's recency
        cache[thirdScope] = 3

        XCTAssertEqual(cache[firstScope], 1)
        XCTAssertNil(cache[secondScope])
        XCTAssertEqual(cache[thirdScope], 3)
    }

    func testCredentialRotationEvictsEveryQualifiedWorkspaceForThatAccount() {
        let accountA = AccountID.make()
        let accountB = AccountID.make()
        let organizationA = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let organizationB = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let scopeA = scope(account: accountA, organization: organizationA)
        let scopeB = scope(account: accountB, organization: organizationB)
        var cache = WorkspacePresentationCache<Int>()

        cache[scopeA] = 1
        cache[scopeB] = 2
        cache.removeAll(for: accountA)

        XCTAssertNil(cache[scopeA])
        XCTAssertEqual(cache[scopeB], 2)
    }

    func testCapabilityRotationEvictsOnlyThatOrganizationsQualifiedWorkspace() {
        let account = AccountID.make()
        let firstOrganization = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let secondOrganization = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let firstScope = scope(account: account, organization: firstOrganization)
        let secondScope = scope(account: account, organization: secondOrganization)
        var cache = WorkspacePresentationCache<Int>()

        cache[firstScope] = 1
        cache[secondScope] = 2
        cache.removeAll(for: account, organizationID: firstOrganization)

        XCTAssertNil(cache[firstScope])
        XCTAssertEqual(cache[secondScope], 2)
    }

    func testMissingSelectedModelPresentsVisibleAutoFallback() {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let state = OrganizationAISettingsState(
            consent: .init(
                accountID: accountID,
                organizationID: organizationID,
                isEnabled: true,
                selectedModelID: "retired-model",
                updatedAt: .now
            ),
            isEffectivelyAvailable: false,
            status: "Model availability is being refreshed.",
            availableModels: [.init(id: "current-model", displayName: "Current Model", isDefault: true)]
        )

        XCTAssertEqual(state.selectedModelTitle, "Auto")
    }

    func testAISettingsPresentsRaisedAutomaticActionConfidenceThreshold() {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let state = OrganizationAISettingsState(
            consent: .init(
                accountID: accountID,
                organizationID: organizationID,
                isEnabled: true,
                selectedModelID: nil,
                automaticActionConfidenceThreshold: 0.97,
                updatedAt: .now
            ),
            isEffectivelyAvailable: false,
            status: "Authorization is being checked."
        )

        XCTAssertEqual(state.automaticActionConfidenceTitle, "97% minimum")
    }

    func testWorkspacePublicationAnnouncesScopedInsertedActionItemsWithoutReplays() async throws {
        let accountID = AccountID.make()
        let firstOrganization = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let secondOrganization = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let firstScope = scope(account: accountID, organization: firstOrganization)
        let secondScope = scope(account: accountID, organization: secondOrganization)
        let recorder = WorkspaceAccessibilityRecorder()
        let accessibility = WorkspaceAccessibilityCoordinator(poster: recorder)
        let model = try makeModel(workspaceAccessibility: accessibility)
        let firstItem = workItem(account: accountID, organization: firstOrganization, id: "first")
        let secondItem = workItem(account: accountID, organization: secondOrganization, id: "second")
        let sharedActionID = ActionItemID.make()
        let firstAction = actionItem(id: sharedActionID, workItemID: firstItem.id)
        let secondAction = actionItem(id: sharedActionID, workItemID: secondItem.id)

        model.install(
            accounts: [account(accountID, suffix: "only")],
            organizations: [
                organization(firstOrganization, suffix: "first"),
                organization(secondOrganization, suffix: "second")
            ],
            organizationAccesses: [
                firstOrganization: access(account: accountID, organization: firstOrganization),
                secondOrganization: access(account: accountID, organization: secondOrganization)
            ],
            for: accountID
        )

        model.install(workItems: [firstItem], scope: firstScope)
        model.install(
            workItems: [firstItem.replacing(actionItems: [firstAction])],
            scope: firstScope
        )
        model.install(
            workItems: [firstItem.replacing(actionItems: [firstAction])],
            scope: firstScope
        )

        model.selectOrganization(secondOrganization)
        model.install(
            workItems: [secondItem.replacing(actionItems: [secondAction])],
            scope: secondScope
        )

        XCTAssertEqual(
            recorder.announcements,
            [
                "A new local action item is available in Triage.",
                "A new local action item is available in Triage."
            ]
        )
        XCTAssertFalse(recorder.announcements.joined(separator: " ").contains("Private action"))
        await model.shutdown()
    }

    func testAccountSwitchPublishesItsLatestQualifiedCachedWorkspaceSynchronously() async throws {
        let accountA = AccountID.make()
        let accountB = AccountID.make()
        let organizationA = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let organizationB = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let oldScopeA = scope(account: accountA, organization: organizationA, credential: "credential-a-old")
        let currentScopeA = scope(account: accountA, organization: organizationA, credential: "credential-a-current")
        let scopeB = scope(account: accountB, organization: organizationB, credential: "credential-b")
        let oldItemA = workItem(account: accountA, organization: organizationA, id: "old-a")
        let currentItemA = workItem(account: accountA, organization: organizationA, id: "current-a")
        let itemB = workItem(account: accountB, organization: organizationB, id: "b")
        let model = try makeModel()

        model.install(
            accounts: [account(accountA, suffix: "a"), account(accountB, suffix: "b")],
            organizations: [organization(organizationA, suffix: "a")],
            organizationAccesses: [organizationA: access(account: accountA, organization: organizationA)],
            for: accountA
        )
        model.install(
            accounts: [account(accountA, suffix: "a"), account(accountB, suffix: "b")],
            organizations: [organization(organizationB, suffix: "b")],
            organizationAccesses: [organizationB: access(account: accountB, organization: organizationB)],
            for: accountB
        )
        model.install(workItems: [oldItemA], scope: oldScopeA)
        model.install(workItems: [currentItemA], scope: currentScopeA)
        model.install(workItems: [itemB], scope: scopeB)

        model.selectAccount(accountA)

        XCTAssertEqual(model.workItems, [currentItemA])
        XCTAssertNotEqual(model.workItems, [oldItemA])
        XCTAssertNotEqual(model.workItems, [itemB])
        await model.shutdown()
    }

    func testOrganizationSwitchPublishesOnlyThatOrganizationsQualifiedCacheSynchronously() async throws {
        let accountID = AccountID.make()
        let firstOrganization = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let secondOrganization = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let firstScope = scope(account: accountID, organization: firstOrganization, credential: "credential-first")
        let secondScope = scope(account: accountID, organization: secondOrganization, credential: "credential-second")
        let firstItem = workItem(account: accountID, organization: firstOrganization, id: "first")
        let secondItem = workItem(account: accountID, organization: secondOrganization, id: "second")
        let model = try makeModel()

        model.install(
            accounts: [account(accountID, suffix: "only")],
            organizations: [
                organization(firstOrganization, suffix: "first"),
                organization(secondOrganization, suffix: "second")
            ],
            organizationAccesses: [
                firstOrganization: access(account: accountID, organization: firstOrganization),
                secondOrganization: access(account: accountID, organization: secondOrganization)
            ],
            for: accountID
        )
        model.install(workItems: [firstItem], scope: firstScope)
        model.install(workItems: [secondItem], scope: secondScope)

        model.selectOrganization(secondOrganization)

        XCTAssertEqual(model.workItems, [secondItem])
        XCTAssertNotEqual(model.workItems, [firstItem])
        await model.shutdown()
    }

    func testSelectionResolvesBoundedInboxItemsBeforeTheFullGraphArrives() {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let pageItem = workItem(account: accountID, organization: organizationID, id: "page")
        let fullOnlyItem = workItem(account: accountID, organization: organizationID, id: "full")

        XCTAssertEqual(
            TriageAppModel.selectionWorkItems(inboxPage: [pageItem], fullGraph: []).map(\.id),
            [pageItem.id]
        )
        XCTAssertEqual(
            TriageAppModel.selectionWorkItems(
                inboxPage: [pageItem],
                fullGraph: [fullOnlyItem, pageItem]
            ).map(\.id),
            [pageItem.id, fullOnlyItem.id]
        )
    }

    func testInboxSelectionRepairReplacesArchivedOrSnoozedSelectionWithVisiblePageRow() {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let evaluatedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let visible = workItem(account: accountID, organization: organizationID, id: "visible")
            .replacing(workflow: WorkflowState(isPinned: true, updatedAt: evaluatedAt))
        let archived = workItem(account: accountID, organization: organizationID, id: "archived")
            .replacing(workflow: WorkflowState(status: .archived, updatedAt: evaluatedAt))
        let snoozed = workItem(account: accountID, organization: organizationID, id: "snoozed")
            .replacing(workflow: WorkflowState(
                isPinned: true,
                snoozedUntil: evaluatedAt.addingTimeInterval(60),
                updatedAt: evaluatedAt
            ))

        for noLongerEligible in [archived, snoozed] {
            let repaired = TriageAppModel.repairedInboxSelection(
                selectedWorkItemID: noLongerEligible.id,
                selectedWorkItemIDs: [noLongerEligible.id],
                inboxPage: [visible],
                fullGraph: [visible, noLongerEligible],
                evaluatedAt: evaluatedAt
            )
            XCTAssertEqual(repaired.primaryWorkItemID, visible.id)
            XCTAssertEqual(repaired.selectedWorkItemIDs, [visible.id])
        }
    }

    func testInboxSelectionRepairPreservesOffPageInboxMultiSelection() {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let evaluatedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let pageItem = workItem(account: accountID, organization: organizationID, id: "page")
            .replacing(workflow: WorkflowState(isPinned: true, updatedAt: evaluatedAt))
        let offPageItem = workItem(account: accountID, organization: organizationID, id: "off-page")
            .replacing(workflow: WorkflowState(isPinned: true, updatedAt: evaluatedAt))

        let repaired = TriageAppModel.repairedInboxSelection(
            selectedWorkItemID: offPageItem.id,
            selectedWorkItemIDs: [pageItem.id, offPageItem.id],
            inboxPage: [pageItem],
            fullGraph: [pageItem, offPageItem],
            evaluatedAt: evaluatedAt
        )

        XCTAssertEqual(repaired.primaryWorkItemID, offPageItem.id)
        XCTAssertEqual(repaired.selectedWorkItemIDs, [pageItem.id, offPageItem.id])
    }

    func testInboxPageRefreshDeadlineUsesBoundaryLearnedFromFullGraph() {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let evaluatedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let boundary = evaluatedAt.addingTimeInterval(75)
        let item = workItem(account: accountID, organization: organizationID, id: "boundary")
            .replacing(workflow: WorkflowState(
                snoozedUntil: boundary,
                updatedAt: evaluatedAt
            ))

        XCTAssertEqual(
            TriageAppModel.inboxPageRefreshDeadline(
                evaluatedAt: evaluatedAt,
                workItems: [item]
            ),
            boundary
        )
        XCTAssertEqual(
            TriageAppModel.inboxPageRefreshDeadline(
                evaluatedAt: evaluatedAt,
                workItems: []
            ),
            evaluatedAt.addingTimeInterval(30)
        )
    }

    func testAccountRemovalEvictsNotificationDeliveryStateBeforeVaultRemoval() async throws {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let recorder = AccountRemovalOrderRecorder()
        let navigationPurge = NavigationPurgeRecorder()
        let model = try makeModel(
            accountSession: AccountRemovalOrderSessionSpy(recorder: recorder),
            workspaceObservationLifecycle: AccountRemovalObservationLifecycleSpy(recorder: recorder),
            purgeAccountNavigationState: { accountID in navigationPurge.record(accountID) },
            purgeAccountNotificationPreferences: { _ in
                await recorder.append(.notificationPreferencesPurged)
            }
        )
        model.install(
            accounts: [account(accountID, suffix: "removed")],
            organizations: [organization(organizationID, suffix: "removed")],
            organizationAccesses: [organizationID: access(account: accountID, organization: organizationID)],
            for: accountID
        )

        try await model.removeAccount(accountID)

        let events = await recorder.events()
        XCTAssertEqual(events, [.evicted, .notificationPreferencesPurged, .sessionRemoval])
        XCTAssertEqual(navigationPurge.accountIDs, [accountID])
    }

    func testKeylessVaultAccountRemainsRecoverableThroughLocalRemoval() async throws {
        let accountID = AccountID.make()
        let recorder = AccountRemovalOrderRecorder()
        let model = try makeModel(
            accountSession: AccountRemovalOrderSessionSpy(
                recorder: recorder,
                unavailableAccountID: accountID
            ),
            workspaceObservationLifecycle: AccountRemovalObservationLifecycleSpy(recorder: recorder)
        )

        await model.restoreAccounts()

        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertEqual(model.unavailableAccountIDs, [accountID])
        XCTAssertEqual(
            model.restorationError,
            "An account's encrypted local data cannot be opened. Remove its local data in Settings, then reconnect to resync."
        )

        try await model.removeAccount(accountID)

        XCTAssertTrue(model.unavailableAccountIDs.isEmpty)
        XCTAssertNil(model.restorationError)
        XCTAssertNil(model.workspaceRestorationError)
        let events = await recorder.events()
        XCTAssertEqual(events, [.evicted, .sessionRemoval])
    }

    func testSuccessfulAccountRestorationRetryClearsRecoveryState() async throws {
        let unavailableAccountID = AccountID.make()
        let unavailable = try AccountSessionSnapshot(
            accounts: [],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:],
            unavailableAccountIDs: [unavailableAccountID]
        )
        let recovered = try AccountSessionSnapshot(
            accounts: [],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:]
        )
        let model = try makeModel(
            accountSession: SequencedRestorationSessionSpy(snapshots: [unavailable, recovered])
        )

        await model.restoreAccounts()
        XCTAssertNotNil(model.restorationError)

        await model.restoreAccounts()
        XCTAssertNil(model.restorationError)
        XCTAssertNil(model.workspaceRestorationError)
    }

    func testAccountRestorationRetryIsSingleFlightAndPublishesInFlightState() async throws {
        let session = BlockingRestorationRetrySessionSpy()
        let model = try makeModel(accountSession: session)

        let firstRetry = Task { await model.restoreAccounts() }
        await session.waitForRestoreStart()
        XCTAssertTrue(model.isRestoringAccounts)

        await model.restoreAccounts()
        let restorationCallCount = await session.restoreCallCount()
        XCTAssertEqual(restorationCallCount, 1)

        await session.finishRestore()
        await firstRetry.value
        XCTAssertFalse(model.isRestoringAccounts)
    }

    func testCopilotAcquisitionPublishesRealProgressAndDisablesDuplicateOperations() async throws {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let runtimeAuthorization = RuntimeProgressAuthorizationSpy()
        let model = try makeModel(copilotRuntimeAuthorization: runtimeAuthorization)
        model.install(
            accounts: [account(accountID, suffix: "runtime-progress")],
            organizations: [organization(organizationID, suffix: "runtime-progress")],
            organizationAccesses: [organizationID: access(account: accountID, organization: organizationID)],
            for: accountID
        )
        model.selectedAccountID = accountID
        model.selectedOrganizationID = organizationID

        let acquisition = Task { await model.acquireCopilotRuntimeAtUserRequest() }
        await runtimeAuthorization.waitForDownloading()
        await assertRuntimeState(model, matches: .downloading)
        XCTAssertTrue(model.isCopilotRuntimeOperationInProgress)

        await model.acquireCopilotRuntimeAtUserRequest()
        let acquisitionCallCount = await runtimeAuthorization.acquireCallCount()
        XCTAssertEqual(acquisitionCallCount, 1)

        await runtimeAuthorization.beginVerification()
        await assertRuntimeState(model, matches: .verifying)

        await runtimeAuthorization.finishAcquisition()
        await acquisition.value
        XCTAssertFalse(model.isCopilotRuntimeOperationInProgress)
    }

    func testSuccessfulCredentialReplacementClearsResolvedRecoveryState() async throws {
        let accountID = AccountID.make()
        let unavailableAccountID = AccountID.make()
        let activeAccount = account(accountID, suffix: "active")
        let withRecovery = try AccountSessionSnapshot(
            accounts: [activeAccount],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:],
            unavailableAccountIDs: [unavailableAccountID]
        )
        let recovered = try AccountSessionSnapshot(
            accounts: [activeAccount],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:]
        )
        let model = try makeModel(
            accountSession: RecoveryReplacingSessionSpy(
                restoration: withRecovery,
                replacement: recovered
            )
        )

        await model.restoreAccounts()
        XCTAssertNotNil(model.restorationError)

        await model.replacePersonalAccessToken(
            "github_pat_abcdefghijklmnopqrstuvwxyz",
            for: activeAccount
        )

        XCTAssertNil(model.restorationError)
        XCTAssertNil(model.workspaceRestorationError)
    }

    func testCredentialReplacementDisconnectsRetainedCopilotAuthorityBeforePersistingReplacement() async throws {
        let accountID = AccountID.make()
        let activeAccount = account(accountID, suffix: "copilot-replacement")
        let snapshot = try AccountSessionSnapshot(
            accounts: [activeAccount],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:]
        )
        let authorization = RuntimeProgressAuthorizationSpy()
        let model = try makeModel(
            accountSession: RecoveryReplacingSessionSpy(restoration: snapshot, replacement: snapshot),
            copilotRuntimeAuthorization: authorization
        )
        await model.restoreAccounts()

        await model.replacePersonalAccessToken(
            "github_pat_abcdefghijklmnopqrstuvwxyz",
            for: activeAccount
        )

        let disconnectedAccountIDs = await authorization.disconnectedAccountIDs()
        XCTAssertEqual(disconnectedAccountIDs, [accountID])
    }

    func testVerifiedBackupRepairClearsVaultRecoveryWithoutUsingUnavailableAccountPath() async throws {
        let recoveryAccountID = AccountID.make()
        let repairIssue = AccountVaultRecoveryIssue(
            accountID: recoveryAccountID,
            kind: .migrationFailure,
            verifiedBackupMigrationIDs: ["033-role-search-page-replay-v2"]
        )
        let needsRepair = try AccountSessionSnapshot(
            accounts: [],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:],
            vaultRecoveryIssues: [repairIssue]
        )
        let repaired = try AccountSessionSnapshot(
            accounts: [],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:]
        )
        let model = try makeModel(
            accountSession: RecoveryReplacingSessionSpy(
                restoration: needsRepair,
                replacement: repaired
            )
        )

        await model.restoreAccounts()
        XCTAssertEqual(model.vaultRecoveryIssues, [repairIssue])
        XCTAssertTrue(model.unavailableAccountIDs.isEmpty)

        await model.restoreVerifiedMigrationBackup(
            for: recoveryAccountID,
            migrationID: "033-role-search-page-replay-v2"
        )

        XCTAssertTrue(model.vaultRecoveryIssues.isEmpty)
        XCTAssertTrue(model.unavailableAccountIDs.isEmpty)
        XCTAssertNil(model.restorationError)
    }

    func testLateNotificationRouteDoesNotChangeFixtureSelectionAfterShutdown() async throws {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let workItem = workItem(account: accountID, organization: organizationID, id: "late-route")
        let model = try makeModel(usesInMemoryUITestFixture: true)
        model.install(
            accounts: [account(accountID, suffix: "late-route")],
            organizations: [organization(organizationID, suffix: "late-route")],
            organizationAccesses: [organizationID: access(account: accountID, organization: organizationID)],
            for: accountID
        )
        model.install(workItems: [workItem], scope: scope(account: accountID, organization: organizationID))
        model.selectedWorkItemID = nil

        await model.shutdown()
        await model.handleNotificationLocalAction(.openTriage(.init(
            accountID: accountID,
            organizationID: organizationID,
            workItemID: workItem.id
        )))

        XCTAssertNil(model.selectedWorkItemID)
    }

    func testDelayedRestoreCannotReactivateWorkspaceAfterShutdown() async throws {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let barrier = ActivationBarrier()
        let coordinator = CountingCoordinator()
        let snapshot = try AccountSessionSnapshot(
            accounts: [],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:]
        )
        let model = try makeModel(
            accountSession: DelayedRestorationSessionSpy(barrier: barrier, snapshot: snapshot),
            workspaceCoordinator: coordinator
        )
        model.install(
            accounts: [account(accountID, suffix: "restore-shutdown")],
            organizations: [organization(organizationID, suffix: "restore-shutdown")],
            organizationAccesses: [organizationID: access(account: accountID, organization: organizationID)],
            for: accountID
        )

        let restoration = Task { await model.restoreAccounts() }
        await barrier.waitForArrival()
        await model.shutdown()
        await barrier.release()
        await restoration.value

        // Shutdown owns the single cancellation. A late restoration must not
        // schedule activation/recheck work that cancels this account again.
        let cancelAllCount = await coordinator.cancelAllCount()
        XCTAssertEqual(cancelAllCount, 1)
    }

    func testLifecycleLaunchDoesNothingAfterShutdown() async throws {
        let lifecycle = CountingLifecycle()
        let model = try makeModel(refreshLifecycle: lifecycle)

        await model.shutdown()
        await model.launchOrganizationRefreshLifecycle()

        let launchCount = await lifecycle.launchCount()
        XCTAssertEqual(launchCount, 0)
    }

    func testManualRefreshBehaviorSuppressesAutomaticLifecycleTriggers() async throws {
        let lifecycle = CountingLifecycle()
        let model = try makeModel(
            refreshLifecycle: lifecycle,
            automaticRefreshEnabled: false
        )

        await model.launchOrganizationRefreshLifecycle()
        await model.applicationDidBecomeActive()
        await model.handleSystemWake()
        await model.scheduleOpportunisticBackgroundRefresh()

        let launchCount = await lifecycle.launchCount()
        let activationCount = await lifecycle.activationCount()
        let wakeCount = await lifecycle.wakeCount()
        let backgroundCount = await lifecycle.backgroundCount()
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(wakeCount, 0)
        XCTAssertEqual(backgroundCount, 0)
    }

    func testNotificationRouteDoesNotChangeFixtureSelectionDuringAccountRemoval() async throws {
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let workItem = workItem(account: accountID, organization: organizationID, id: "removing-route")
        let removalBarrier = AccountRemovalBarrier()
        let model = try makeModel(
            accountSession: BlockingAccountRemovalSessionSpy(barrier: removalBarrier),
            usesInMemoryUITestFixture: true
        )
        model.install(
            accounts: [account(accountID, suffix: "removing-route")],
            organizations: [organization(organizationID, suffix: "removing-route")],
            organizationAccesses: [organizationID: access(account: accountID, organization: organizationID)],
            for: accountID
        )
        model.install(workItems: [workItem], scope: scope(account: accountID, organization: organizationID))
        model.selectedWorkItemID = nil

        let removal = Task {
            try await model.removeAccount(accountID)
        }
        await removalBarrier.waitForRemovalStart()

        await model.handleNotificationLocalAction(.openTriage(.init(
            accountID: accountID,
            organizationID: organizationID,
            workItemID: workItem.id
        )))

        XCTAssertNil(model.selectedWorkItemID)
        await removalBarrier.release()
        try await removal.value
    }

    func testSameAccountRemovalIsSingleFlightAndKeepsItsFenceUntilCompletion() async throws {
        let accountID = AccountID.make()
        let removalBarrier = AccountRemovalBarrier()
        let session = BlockingAccountRemovalSessionSpy(barrier: removalBarrier)
        let model = try makeModel(accountSession: session)
        model.install(
            accounts: [account(accountID, suffix: "single-flight")],
            organizations: [],
            organizationAccesses: [:],
            for: accountID
        )

        let firstRemoval = Task {
            try await model.removeAccount(accountID)
        }
        await removalBarrier.waitForRemovalStart()
        XCTAssertTrue(model.isRemovingAccount(accountID))

        try await model.removeAccount(accountID)
        let removalCallCount = await session.removalCallCount()
        XCTAssertEqual(removalCallCount, 1)
        XCTAssertTrue(model.isRemovingAccount(accountID))

        await removalBarrier.release()
        try await firstRemoval.value
        XCTAssertFalse(model.isRemovingAccount(accountID))
        XCTAssertTrue(model.accounts.isEmpty)
    }

    private func scope(
        account: AccountID,
        organization: OrganizationID,
        credential: String = "credential"
    ) -> SynchronizationScope {
        SynchronizationScope(
            accountID: account,
            organizationID: organization,
            credentialRevision: CredentialRevision(rawValue: credential)!,
            capabilityRevision: CapabilityRevision(rawValue: "capability")!
        )
    }

    private func makeModel(
        accountSession: any AccountSessionServing = CacheSessionSpy(),
        workspaceCoordinator: any WorkspaceCoordinating = CacheCoordinatorSpy(),
        refreshLifecycle: any OrganizationRefreshLifecycleHandling = CacheLifecycleSpy(),
        workspaceObservationLifecycle: any WorkspaceObservationLifecycleHandling = NoopWorkspaceObservationLifecycle(),
        copilotRuntimeAuthorization: any CopilotRuntimeAuthorizationProviding = NoopCopilotRuntimeAuthorizationProvider(),
        workspaceAccessibility: WorkspaceAccessibilityCoordinator? = nil,
        purgeAccountNavigationState: @escaping AccountNavigationStatePurging = { _ in },
        purgeAccountNotificationPreferences: @escaping AccountNotificationPreferencePurging = { _ in },
        usesInMemoryUITestFixture: Bool = false,
        automaticRefreshEnabled: Bool = true
    ) throws -> TriageAppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-app-model-cache-\(UUID().uuidString)", isDirectory: true)
        return TriageAppModel(
            dependencies: TriageApplicationDependencies(
                accountSession: accountSession,
                workspaceCoordinator: workspaceCoordinator,
                refreshLifecycle: refreshLifecycle,
                workspaceObserver: CacheObserverSpy(),
                workspaceObservationLifecycle: workspaceObservationLifecycle,
                workspaceMutator: CacheMutatorSpy(),
                copilotRuntimeAuthorization: copilotRuntimeAuthorization,
                purgeAccountNavigationState: purgeAccountNavigationState,
                purgeAccountNotificationPreferences: purgeAccountNotificationPreferences
            ),
            vaultRegistry: try VaultRegistry(rootDirectory: root),
            defaults: UserDefaults(suiteName: "triage-app-model-cache-\(UUID().uuidString)")!,
            workspaceAccessibility: workspaceAccessibility,
            usesInMemoryUITestFixture: usesInMemoryUITestFixture,
            automaticRefreshEnabled: automaticRefreshEnabled
        )
    }

    private func assertRuntimeState(
        _ model: TriageAppModel,
        matches expected: RuntimeStateCase
    ) async {
        for _ in 0..<100 {
            switch (expected, model.selectedCopilotAuthorizationState.runtime) {
            case (.downloading, .downloading), (.verifying, .verifying):
                return
            default:
                await Task.yield()
            }
        }
        XCTFail("The app model did not publish the expected Copilot runtime state: \(expected).")
    }

    private func account(_ id: AccountID, suffix: String) -> GitHubAccount {
        GitHubAccount(
            id: id,
            githubUserID: UInt64(abs(suffix.hashValue)),
            nodeID: GitHubNodeID(rawValue: "account-\(suffix)")!,
            login: "account-\(suffix)",
            authenticationKind: .oauth,
            credentialID: CredentialID(rawValue: "credential-\(suffix)")!,
            credentialStatus: .active,
            createdAt: .now
        )
    }

    private func organization(_ id: OrganizationID, suffix: String) -> GitHubOrganization {
        GitHubOrganization(
            id: id,
            githubOrganizationID: UInt64(abs(suffix.hashValue)),
            nodeID: GitHubNodeID(rawValue: "organization-\(suffix)")!,
            login: "organization-\(suffix)"
        )
    }

    private func access(account: AccountID, organization: OrganizationID) -> OrganizationAccess {
        OrganizationAccess(
            accountID: account,
            organizationID: organization,
            state: .available,
            capabilityRevision: CapabilityRevision(rawValue: "capability")!,
            capabilities: [],
            checkedAt: .now
        )
    }

    private func workItem(
        account: AccountID,
        organization: OrganizationID,
        id: String,
        actionItems: [ActionItem] = []
    ) -> WorkItem {
        WorkItem(
            id: WorkItemID(rawValue: "work-\(id)")!,
            accountID: account,
            organizationID: organization,
            primaryNodeID: GitHubNodeID(rawValue: "node-\(id)")!,
            title: id,
            state: .active,
            sourceKind: .issue,
            sourceURL: nil,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: [],
            actionItems: actionItems,
            workflow: WorkflowState(updatedAt: .now),
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: .now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
    }

    private func actionItem(id: ActionItemID, workItemID: WorkItemID) -> ActionItem {
        ActionItem(
            id: id,
            workItemID: workItemID,
            title: "Private action title",
            detail: "Private action detail",
            origin: .deterministicRule,
            createdAt: .now,
            updatedAt: .now
        )
    }
}

@MainActor
private final class WorkspaceAccessibilityRecorder: WorkspaceAccessibilityAnnouncementPosting {
    private(set) var announcements = [String]()

    func post(announcement: String) {
        announcements.append(announcement)
    }
}

@MainActor
private final class NavigationPurgeRecorder {
    private(set) var accountIDs = [AccountID]()

    func record(_ accountID: AccountID) {
        accountIDs.append(accountID)
    }
}

private actor CacheSessionSpy: AccountSessionServing {
    func restoreAccounts() async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func removeAccount(_: AccountID) async throws {}

    private func emptySnapshot() throws -> AccountSessionSnapshot {
        try AccountSessionSnapshot(
            accounts: [], organizationsByAccount: [:], organizationAccessesByAccount: [:], accountCapabilitiesByAccount: [:]
        )
    }
}

private actor BlockingRestorationRetrySessionSpy: AccountSessionServing {
    private var restoreCalls = 0
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func restoreAccounts() async throws -> AccountSessionSnapshot {
        restoreCalls += 1
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return try emptySnapshot()
    }

    func waitForRestoreStart() async {
        guard restoreCalls == 0 else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func finishRestore() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func restoreCallCount() -> Int { restoreCalls }

    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func removeAccount(_: AccountID) async throws {}

    private func emptySnapshot() throws -> AccountSessionSnapshot {
        try AccountSessionSnapshot(
            accounts: [], organizationsByAccount: [:], organizationAccessesByAccount: [:], accountCapabilitiesByAccount: [:]
        )
    }
}

private actor RuntimeProgressAuthorizationSpy: CopilotRuntimeAuthorizationProviding {
    private var continuation: AsyncStream<CopilotRuntimeStatus>.Continuation?
    private var currentRuntime: CopilotRuntimeStatus = .missing
    private var acquireCalls = 0
    private var downloadingContinuation: CheckedContinuation<Void, Never>?
    private var acquireRelease: CheckedContinuation<Void, Never>?
    private var verificationRelease: CheckedContinuation<Void, Never>?
    private var disconnectedAccounts = [AccountID]()

    func state(for _: AccountID) async -> CopilotAccountAuthorizationState {
        .init(
            runtime: currentRuntime,
            authentication: .signedOut,
            isEntitled: false,
            hasOrganizationConsent: false
        )
    }

    func runtimeStateUpdates() async -> AsyncStream<CopilotRuntimeStatus>? {
        var captured: AsyncStream<CopilotRuntimeStatus>.Continuation!
        let stream = AsyncStream<CopilotRuntimeStatus> { captured = $0 }
        continuation = captured
        captured.yield(currentRuntime)
        return stream
    }

    func acquireRuntimeAtUserRequest() async throws {
        acquireCalls += 1
        publish(.downloading(receivedBytes: 0, expectedBytes: 100))
        downloadingContinuation?.resume()
        downloadingContinuation = nil
        await withCheckedContinuation { continuation in
            acquireRelease = continuation
        }
        publish(.verifying)
        await withCheckedContinuation { continuation in
            verificationRelease = continuation
        }
        publish(.ready)
    }

    func waitForDownloading() async {
        if case .downloading = currentRuntime { return }
        await withCheckedContinuation { continuation in
            downloadingContinuation = continuation
        }
    }

    func beginVerification() {
        acquireRelease?.resume()
        acquireRelease = nil
    }

    func finishAcquisition() {
        verificationRelease?.resume()
        verificationRelease = nil
    }

    func acquireCallCount() -> Int { acquireCalls }

    func repairRuntimeAtUserRequest() async throws { throw CancellationError() }
    func removeRuntimeAtUserRequest() async throws {}
    func authenticate(account _: GitHubAccount, organizationID _: OrganizationID, hasOrganizationConsent _: Bool, isEntitled _: Bool) async throws {}
    func models(accountID _: AccountID, organizationID _: OrganizationID) async throws -> [CopilotModel] { [] }
    func externalState(for _: SynchronizationScope, account _: GitHubAccount) async -> OrganizationAIExternalState { .unavailable }
    func disconnect(accountID: AccountID) async { disconnectedAccounts.append(accountID) }

    func disconnectedAccountIDs() -> [AccountID] { disconnectedAccounts }

    private func publish(_ state: CopilotRuntimeStatus) {
        currentRuntime = state
        continuation?.yield(state)
    }
}

private actor AccountRemovalOrderRecorder {
    enum Event: Equatable, Sendable {
        case evicted
        case notificationPreferencesPurged
        case sessionRemoval
    }

    private var storage: [Event] = []

    func append(_ event: Event) {
        storage.append(event)
    }

    func events() -> [Event] { storage }
}

private actor AccountRemovalOrderSessionSpy: AccountSessionServing {
    private let recorder: AccountRemovalOrderRecorder
    private let unavailableAccountID: AccountID?

    init(
        recorder: AccountRemovalOrderRecorder,
        unavailableAccountID: AccountID? = nil
    ) {
        self.recorder = recorder
        self.unavailableAccountID = unavailableAccountID
    }

    func restoreAccounts() async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try emptySnapshot() }

    func removeAccount(_: AccountID) async throws {
        await recorder.append(.sessionRemoval)
    }

    private func emptySnapshot() throws -> AccountSessionSnapshot {
        try AccountSessionSnapshot(
            accounts: [],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:],
            unavailableAccountIDs: unavailableAccountID.map { [$0] } ?? []
        )
    }
}

private actor BlockingAccountRemovalSessionSpy: AccountSessionServing {
    private let barrier: AccountRemovalBarrier
    private var removalCalls = 0

    init(barrier: AccountRemovalBarrier) {
        self.barrier = barrier
    }

    func restoreAccounts() async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try emptySnapshot() }

    func removeAccount(_: AccountID) async throws {
        removalCalls += 1
        await barrier.markRemovalStarted()
        await barrier.waitForRelease()
    }

    func removalCallCount() -> Int { removalCalls }

    private func emptySnapshot() throws -> AccountSessionSnapshot {
        try AccountSessionSnapshot(
            accounts: [], organizationsByAccount: [:], organizationAccessesByAccount: [:], accountCapabilitiesByAccount: [:]
        )
    }
}

private actor SequencedRestorationSessionSpy: AccountSessionServing {
    private var snapshots: [AccountSessionSnapshot]

    init(snapshots: [AccountSessionSnapshot]) {
        self.snapshots = snapshots
    }

    func restoreAccounts() async throws -> AccountSessionSnapshot {
        guard !snapshots.isEmpty else { throw CancellationError() }
        return snapshots.removeFirst()
    }

    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func removeAccount(_: AccountID) async throws {}
}

private actor DelayedRestorationSessionSpy: AccountSessionServing {
    private let barrier: ActivationBarrier
    private let snapshot: AccountSessionSnapshot

    init(barrier: ActivationBarrier, snapshot: AccountSessionSnapshot) {
        self.barrier = barrier
        self.snapshot = snapshot
    }

    func restoreAccounts() async throws -> AccountSessionSnapshot {
        await barrier.wait()
        return snapshot
    }

    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { snapshot }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { snapshot }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { snapshot }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { snapshot }
    func removeAccount(_: AccountID) async throws {}
}

private actor RecoveryReplacingSessionSpy: AccountSessionServing {
    private let restoration: AccountSessionSnapshot
    private let replacement: AccountSessionSnapshot

    init(restoration: AccountSessionSnapshot, replacement: AccountSessionSnapshot) {
        self.restoration = restoration
        self.replacement = replacement
    }

    func restoreAccounts() async throws -> AccountSessionSnapshot { restoration }
    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { replacement }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { replacement }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { replacement }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { replacement }
    func restoreVerifiedMigrationBackup(
        for _: AccountID,
        migrationID _: String
    ) async throws -> AccountSessionSnapshot { replacement }
    func removeAccount(_: AccountID) async throws {}
}

private actor AccountRemovalObservationLifecycleSpy: WorkspaceObservationLifecycleHandling {
    private let recorder: AccountRemovalOrderRecorder

    init(recorder: AccountRemovalOrderRecorder) {
        self.recorder = recorder
    }

    func evictAccount(_: AccountID) async {
        await recorder.append(.evicted)
    }

    func shutdown() async {}
}

private actor CacheCoordinatorSpy: WorkspaceCoordinating {
    func select(_: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? { nil }
    func refresh(_: SynchronizationScope, priority _: AccountOrganizationRefreshPriority) async throws -> AccountOrganizationCoordinatorState? { nil }
    func cancel(_: SynchronizationScope) async throws {}
    func cancelAll(for _: AccountID) async throws {}
    func shutdown() async {}
}

private actor CountingCoordinator: WorkspaceCoordinating {
    private var cancelAllCalls = 0

    func select(_: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? { nil }
    func refresh(_: SynchronizationScope, priority _: AccountOrganizationRefreshPriority) async throws -> AccountOrganizationCoordinatorState? { nil }
    func cancel(_: SynchronizationScope) async throws {}
    func cancelAll(for _: AccountID) async throws { cancelAllCalls += 1 }
    func shutdown() async {}

    func cancelAllCount() -> Int { cancelAllCalls }
}

private actor CacheLifecycleSpy: OrganizationRefreshLifecycleHandling {
    func launch(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func applicationDidBecomeActive(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func wake(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func scheduleOpportunisticBackgroundRefresh(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func stop() async {}
}

private actor CountingLifecycle: OrganizationRefreshLifecycleHandling {
    private var launches = 0
    private var activations = 0
    private var wakes = 0
    private var backgrounds = 0

    func launch(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {
        launches += 1
    }
    func applicationDidBecomeActive(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {
        activations += 1
    }
    func wake(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {
        wakes += 1
    }
    func scheduleOpportunisticBackgroundRefresh(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {
        backgrounds += 1
    }
    func stop() async {}

    func launchCount() -> Int { launches }
    func activationCount() -> Int { activations }
    func wakeCount() -> Int { wakes }
    func backgroundCount() -> Int { backgrounds }
}

private actor CacheObserverSpy: WorkspaceObserving {
    func snapshots(for _: SynchronizationScope) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor CacheMutatorSpy: WorkspaceMutating {
    func apply(_: WorkflowAction, to _: WorkItemID, in _: SynchronizationScope) async throws {}
    func completeActionItem(_: ActionItemID, in _: WorkItemID, scope _: SynchronizationScope) async throws {}
    func editActionItem(_: LocalActionItemEdit, actionItemID _: ActionItemID, in _: WorkItemID, expectedUpdatedAt _: Date, scope _: SynchronizationScope) async throws -> ActionItem { throw CancellationError() }
}

private actor ActivationBarrier {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var arrivalContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        arrivalContinuation?.resume()
        arrivalContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForArrival() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            arrivalContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AccountRemovalBarrier {
    private var hasStartedRemoval = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func markRemovalStarted() {
        hasStartedRemoval = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitForRemovalStart() async {
        guard !hasStartedRemoval else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class PublicationRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
