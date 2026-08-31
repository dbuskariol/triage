import Foundation
import XCTest
@testable import Triage

@MainActor
final class TriageAppModelSelectionTests: XCTestCase {
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
        workspaceObservationLifecycle: any WorkspaceObservationLifecycleHandling = NoopWorkspaceObservationLifecycle(),
        workspaceAccessibility: WorkspaceAccessibilityCoordinator? = nil,
        purgeAccountNavigationState: @escaping AccountNavigationStatePurging = { _ in },
        purgeAccountNotificationPreferences: @escaping AccountNotificationPreferencePurging = { _ in },
        usesInMemoryUITestFixture: Bool = false
    ) throws -> TriageAppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-app-model-cache-\(UUID().uuidString)", isDirectory: true)
        return TriageAppModel(
            dependencies: TriageApplicationDependencies(
                accountSession: accountSession,
                workspaceCoordinator: CacheCoordinatorSpy(),
                refreshLifecycle: CacheLifecycleSpy(),
                workspaceObserver: CacheObserverSpy(),
                workspaceObservationLifecycle: workspaceObservationLifecycle,
                workspaceMutator: CacheMutatorSpy(),
                purgeAccountNavigationState: purgeAccountNavigationState,
                purgeAccountNotificationPreferences: purgeAccountNotificationPreferences
            ),
            vaultRegistry: try VaultRegistry(rootDirectory: root),
            defaults: UserDefaults(suiteName: "triage-app-model-cache-\(UUID().uuidString)")!,
            workspaceAccessibility: workspaceAccessibility,
            usesInMemoryUITestFixture: usesInMemoryUITestFixture
        )
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

    init(barrier: AccountRemovalBarrier) {
        self.barrier = barrier
    }

    func restoreAccounts() async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try emptySnapshot() }

    func removeAccount(_: AccountID) async throws {
        await barrier.markRemovalStarted()
        await barrier.waitForRelease()
    }

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

private actor CacheLifecycleSpy: OrganizationRefreshLifecycleHandling {
    func launch(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func applicationDidBecomeActive(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func wake(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func scheduleOpportunisticBackgroundRefresh(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func stop() async {}
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
