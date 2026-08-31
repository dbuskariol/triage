import Foundation
import XCTest
@testable import Triage

final class TriageApplicationDependenciesTests: XCTestCase {
    func testWorkspaceConstructionFatalDiagnosticNeverIncludesUnderlyingErrorDetails() {
        let sensitiveText = "ghp_sensitive_token_and_private_path_must_not_escape"
        let error = NSError(
            domain: sensitiveText,
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: sensitiveText,
                NSFilePathErrorKey: "/Users/person/Library/Application Support/Triage/private.sqlite"
            ]
        )

        let diagnostic = TriageStartupDiagnostics.workspaceConstructionFatalDiagnostic(for: error)

        XCTAssertEqual(diagnostic, "Triage could not construct its local encrypted workspace.")
        XCTAssertFalse(diagnostic.contains(sensitiveText))
        XCTAssertFalse(diagnostic.contains("private.sqlite"))
    }

    func testProductionCompositionHasConcreteServicesForEveryBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-production-composition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let composition = TriageProductionComposition(
            vaultRegistry: try VaultRegistry(rootDirectory: root),
            secretStore: KeychainSecretStore(),
            applicationSupportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true)
        )
        let dependencies = composition.dependencies()

        XCTAssertTrue(dependencies.accountSession is TriageAccountSessionService)
        XCTAssertTrue(dependencies.workspaceCoordinator is TriageWorkspaceCoordinator)
        XCTAssertTrue(dependencies.refreshLifecycle is TriageWorkspaceCoordinator)
        XCTAssertTrue(dependencies.workspaceObserver is DatabaseWorkspaceObserver)
        XCTAssertTrue(dependencies.workspaceMutator is TriageWorkspaceMutator)
    }

    func testProductionCompositionWithNotificationSettingsWrapsObservationAndLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-production-notification-composition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let composition = TriageProductionComposition(
            vaultRegistry: try VaultRegistry(rootDirectory: root),
            secretStore: KeychainSecretStore(),
            applicationSupportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true)
        )
        let settings = NotificationPreferencesSpy()
        let dependencies = composition.dependencies(notificationSettings: settings)

        XCTAssertTrue(dependencies.workspaceObserver is NotificationDeliveringWorkspaceObserver)
        XCTAssertTrue(dependencies.workspaceObservationLifecycle is NotificationDeliveringWorkspaceObserver)
        await dependencies.workspaceObservationLifecycle.shutdown()
    }

    func testSessionSnapshotRepresentsKeylessVaultAsRecoveryOnlyAccount() throws {
        let unavailableAccountID = AccountID.make()

        let snapshot = try AccountSessionSnapshot(
            accounts: [],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:],
            unavailableAccountIDs: [unavailableAccountID]
        )

        XCTAssertEqual(snapshot.unavailableAccountIDs, [unavailableAccountID])
        XCTAssertTrue(snapshot.accounts.isEmpty)
    }

    func testProductionSessionRestoresKeylessVaultAsRecoverableLocalAccount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-keyless-production-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unavailableAccountID = AccountID.make()
        let session = TriageAccountSessionService(
            vaultRegistry: try VaultRegistry(rootDirectory: root),
            secretStore: KeychainSecretStore(),
            applicationSupportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true),
            restoreAccountState: {
                AccountRestorationResult(
                    accounts: [],
                    organizationsByAccount: [:],
                    organizationAccessesByAccount: [:],
                    accountCapabilitiesByAccount: [:],
                    unavailableAccountIDs: [unavailableAccountID]
                )
            }
        )

        let snapshot = try await session.restoreAccounts()

        XCTAssertEqual(snapshot.unavailableAccountIDs, [unavailableAccountID])
        XCTAssertTrue(snapshot.accounts.isEmpty)
    }

    func testStartupDeletionRecoveryPurgesEveryRecoveredAccountBeforeRestoration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-startup-deletion-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRecoveredAccountID = AccountID.make()
        let secondRecoveredAccountID = AccountID.make()
        let purger = RecoveredAccountStatePurgerSpy()
        let session = TriageAccountSessionService(
            vaultRegistry: try VaultRegistry(rootDirectory: root),
            secretStore: KeychainSecretStore(),
            applicationSupportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true),
            restoreAccountState: {
                guard await purger.purgedAccountIDs() == [firstRecoveredAccountID, secondRecoveredAccountID] else {
                    throw StartupDeletionRecoveryTestError.restoredBeforeCleanup
                }
                return AccountRestorationResult(
                    accounts: [],
                    organizationsByAccount: [:],
                    organizationAccessesByAccount: [:],
                    accountCapabilitiesByAccount: [:],
                    unavailableAccountIDs: []
                )
            },
            recoverInterruptedRemovals: {
                [firstRecoveredAccountID, secondRecoveredAccountID]
            },
            deletionRecoveryStatePurger: purger
        )

        let snapshot = try await session.restoreAccounts()
        let purgedAccountIDs = await purger.purgedAccountIDs()

        XCTAssertTrue(snapshot.accounts.isEmpty)
        XCTAssertEqual(
            purgedAccountIDs,
            [firstRecoveredAccountID, secondRecoveredAccountID]
        )
    }

    func testPostCredentialReplayMapsOnlyValidOrganizationIdentities() throws {
        let mapped = try TriageAccountSessionService.organizationForInventoryReplay(
            GitHubOrganizationDTO(id: 1, nodeID: "O_1", login: "acme", avatarURL: nil)
        )
        XCTAssertEqual(mapped.id.rawValue, "O_1")
        XCTAssertEqual(mapped.nodeID.rawValue, "O_1")
        XCTAssertEqual(mapped.githubOrganizationID, 1)
        XCTAssertEqual(mapped.login, "acme")

        XCTAssertThrowsError(
            try TriageAccountSessionService.organizationForInventoryReplay(
                GitHubOrganizationDTO(id: 1, nodeID: "", login: "acme", avatarURL: nil)
            )
        ) { error in
            XCTAssertEqual(error as? AccountConnectionError, .invalidGitHubIdentity)
        }
    }

    func testDependenciesRequireExplicitServicesAndRouteCallsToThem() async throws {
        let session = SessionSpy()
        let coordinator = CoordinatorSpy()
        let lifecycle = LifecycleSpy()
        let observer = ObserverSpy()
        let mutator = MutatorSpy()
        let dependencies = TriageApplicationDependencies(
            accountSession: session,
            workspaceCoordinator: coordinator,
            refreshLifecycle: lifecycle,
            workspaceObserver: observer,
            workspaceMutator: mutator
        )
        let scope = fixtureScope()

        _ = try await dependencies.accountSession.restoreAccounts()
        _ = try await dependencies.workspaceCoordinator.select(scope)
        await dependencies.refreshLifecycle.launch(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        await dependencies.refreshLifecycle.applicationDidBecomeActive(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        await dependencies.refreshLifecycle.wake(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        await dependencies.refreshLifecycle.scheduleOpportunisticBackgroundRefresh(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        await dependencies.refreshLifecycle.stop()
        _ = try await dependencies.workspaceObserver.snapshots(for: scope)
        try await dependencies.workspaceMutator.apply(.archive, to: WorkItemID.make(), in: scope)

        let restoreCount = await session.restoreCallCount()
        let selectedScopes = await coordinator.selectedScopes()
        let observedScopes = await observer.observedScopes()
        let appliedScopes = await mutator.appliedScopes()
        let lifecycleEvents = await lifecycle.events()
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(selectedScopes, [scope])
        XCTAssertEqual(observedScopes, [scope])
        XCTAssertEqual(appliedScopes, [scope])
        XCTAssertEqual(lifecycleEvents, [.launch, .active, .wake, .background, .stop])
    }

    func testProductionCoordinatorRejectsObsoleteScopeBeforeNewerRuntimeDispatch() async throws {
        let current = fixtureScope()
        let obsolete = SynchronizationScope(
            accountID: current.accountID,
            organizationID: current.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-obsolete")!,
            capabilityRevision: current.capabilityRevision
        )
        let runtime = CoordinatorRuntimeSpy(currentScope: current)
        let coordinator = TriageWorkspaceCoordinator(makeRuntime: { _ in runtime })

        do {
            _ = try await coordinator.refresh(obsolete, priority: .manual)
            XCTFail("An obsolete scope must cancel before dispatching newer authority.")
        } catch is CancellationError {
            // Expected.
        }

        let dispatched = await runtime.refreshScopes()
        XCTAssertTrue(dispatched.isEmpty)
    }

    func testProductionCoordinatorEvictsLifecycleRuntimeForReplacementAndRemoval() async throws {
        let scope = fixtureScope()
        let first = CoordinatorRuntimeSpy(currentScope: scope)
        let second = CoordinatorRuntimeSpy(currentScope: scope)
        let factory = RotatingCoordinatorRuntimeFactory([first, second])
        let coordinator = TriageWorkspaceCoordinator(
            makeRuntime: { accountID in try await factory.makeRuntime(for: accountID) }
        )

        await coordinator.launch(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        try await coordinator.cancelAll(for: scope.accountID)
        await coordinator.applicationDidBecomeActive(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )

        let resolutionsAfterReplacement = await factory.resolutionCount()
        let firstCancels = await first.cancelCount()
        let secondActivations = await second.activationCount()
        XCTAssertEqual(resolutionsAfterReplacement, 2)
        XCTAssertGreaterThanOrEqual(firstCancels, 1)
        XCTAssertEqual(secondActivations, 1)

        try await coordinator.cancelAll(for: scope.accountID)
        await coordinator.applicationDidBecomeActive(
            synchronizationScopes: [],
            activeAccountID: nil
        )
        let finalResolutions = await factory.resolutionCount()
        XCTAssertEqual(finalResolutions, 2)
    }

    func testProductionCoordinatorStaleScheduledCallbackCannotReopenRuntimeAfterCancellation() async throws {
        let scope = fixtureScope()
        let first = CoordinatorRuntimeSpy(currentScope: scope)
        let scheduler = CoordinatorBackgroundSchedulerSpy()
        let factory = RotatingCoordinatorRuntimeFactory([first])
        let coordinator = TriageWorkspaceCoordinator(
            backgroundScheduler: scheduler,
            makeRuntime: { accountID in try await factory.makeRuntime(for: accountID) }
        )

        await coordinator.launch(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        try await coordinator.cancelAll(for: scope.accountID)
        await scheduler.runScheduledOperation()

        let resolutions = await factory.resolutionCount()
        XCTAssertEqual(resolutions, 1)
    }

    func testProductionCoordinatorDiscardsRuntimeProducedAfterCancellation() async throws {
        let scope = fixtureScope()
        let stale = CoordinatorRuntimeSpy(currentScope: scope)
        let fresh = CoordinatorRuntimeSpy(currentScope: scope)
        let factory = SuspendedCoordinatorRuntimeFactory(stale: stale, fresh: fresh)
        let coordinator = TriageWorkspaceCoordinator(
            makeRuntime: { accountID in try await factory.makeRuntime(for: accountID) }
        )
        let select = Task { () -> Bool in
            do {
                _ = try await coordinator.select(scope)
                return true
            } catch {
                return false
            }
        }

        await factory.waitUntilFirstResolutionStarts()
        try await coordinator.cancelAll(for: scope.accountID)
        await factory.resumeFirstResolution()

        let selected = await select.value
        let staleCancels = await stale.cancelCount()
        XCTAssertFalse(selected)
        XCTAssertEqual(staleCancels, 1)

        await coordinator.applicationDidBecomeActive(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        let resolutions = await factory.resolutionCount()
        let freshActivations = await fresh.activationCount()
        XCTAssertEqual(resolutions, 2)
        XCTAssertEqual(freshActivations, 1)
    }

    func testSnapshotRejectsMixedAuthorityCoverage() throws {
        let scope = fixtureScope()
        let record = CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: nil,
            feature: .issues,
            streamID: SyncStreamID(rawValue: UUID().uuidString.lowercased())!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!,
            capabilityRevision: scope.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: .now,
            failureDetail: nil
        )

        XCTAssertThrowsError(
            try WorkspacePresentationSnapshot(
                scope: scope,
                workItems: [],
                durableState: AccountOrganizationDurableState(cachedState: nil),
                coverageRequirements: [],
                coverageRecords: [record],
                menuCounts: nil,
                derivedEvaluatedAt: nil,
                origin: .observed
            )
        ) { error in
            XCTAssertEqual(error as? WorkspacePresentationSnapshotError, .coverageScopeMismatch)
        }
    }

    func testSnapshotCoverageEvaluationUsesItsExactScope() throws {
        let scope = fixtureScope()
        let requirement = CoverageRequirement(
            feature: .issues,
            repositoryID: nil,
            streamID: SyncStreamID(rawValue: UUID().uuidString.lowercased())!
        )
        let snapshot = try WorkspacePresentationSnapshot(
            scope: scope,
            workItems: [],
            durableState: AccountOrganizationDurableState(cachedState: nil),
            coverageRequirements: [requirement],
            coverageRecords: [],
            menuCounts: nil,
            derivedEvaluatedAt: .now,
            origin: .cached
        )

        XCTAssertFalse(snapshot.coverageEvaluation.isComplete)
        XCTAssertEqual(snapshot.coverageEvaluation.missing, [requirement])
        XCTAssertEqual(snapshot.coverageEvaluation.freshness.status, .partial)
    }

    private func fixtureScope() -> SynchronizationScope {
        SynchronizationScope(
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: UUID().uuidString.lowercased())!,
            credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!,
            capabilityRevision: CapabilityRevision(rawValue: UUID().uuidString.lowercased())!
        )
    }
}

@MainActor
private final class NotificationPreferencesSpy: NotificationDeliveryPreferencesProviding {
    func deliveryPreferences(for _: OrganizationID) async -> NotificationPreferences? { nil }
}

private actor SessionSpy: AccountSessionServing {
    private var restores = 0

    func restoreAccounts() async throws -> AccountSessionSnapshot {
        restores += 1
        return try AccountSessionSnapshot(
            accounts: [],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:]
        )
    }

    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func connectPersonalAccessToken(_: PersonalAccessToken, resourceOwnerOrganization _: String?) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func reconnectOAuth(_: AuthBrokerExchangeRequest, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func replacePersonalAccessToken(_: PersonalAccessToken, replacing _: GitHubAccount) async throws -> AccountSessionSnapshot { try await restoreAccounts() }
    func removeAccount(_: AccountID) async throws {}

    func restoreCallCount() -> Int { restores }
}

private enum StartupDeletionRecoveryTestError: Error {
    case restoredBeforeCleanup
}

private actor RecoveredAccountStatePurgerSpy: AccountDeletionRecoveryStatePurging {
    private var accountIDs = [AccountID]()

    func purgeRecoveredDeletedAccountState(for accountID: AccountID) {
        accountIDs.append(accountID)
    }

    func purgedAccountIDs() -> [AccountID] { accountIDs }
}

private actor CoordinatorSpy: WorkspaceCoordinating {
    private var selections: [SynchronizationScope] = []

    func select(_ scope: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? {
        selections.append(scope)
        return nil
    }

    func refresh(_: SynchronizationScope, priority _: AccountOrganizationRefreshPriority) async throws -> AccountOrganizationCoordinatorState? { nil }
    func cancel(_: SynchronizationScope) async throws {}
    func cancelAll(for _: AccountID) async throws {}
    func shutdown() async {}

    func selectedScopes() -> [SynchronizationScope] { selections }
}

private actor ObserverSpy: WorkspaceObserving {
    private var scopes: [SynchronizationScope] = []

    func snapshots(for scope: SynchronizationScope) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        scopes.append(scope)
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func observedScopes() -> [SynchronizationScope] { scopes }
}

private actor LifecycleSpy: OrganizationRefreshLifecycleHandling {
    enum Event: Equatable, Sendable {
        case launch
        case active
        case wake
        case background
        case stop
    }

    private var storage = [Event]()

    func launch(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {
        storage.append(.launch)
    }

    func applicationDidBecomeActive(
        synchronizationScopes _: [SynchronizationScope],
        activeAccountID _: AccountID?
    ) async {
        storage.append(.active)
    }

    func wake(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {
        storage.append(.wake)
    }

    func scheduleOpportunisticBackgroundRefresh(
        synchronizationScopes _: [SynchronizationScope],
        activeAccountID _: AccountID?
    ) async {
        storage.append(.background)
    }

    func stop() async {
        storage.append(.stop)
    }

    func events() -> [Event] { storage }
}

private actor MutatorSpy: WorkspaceMutating {
    private var scopes: [SynchronizationScope] = []

    func apply(_: WorkflowAction, to _: WorkItemID, in scope: SynchronizationScope) async throws {
        scopes.append(scope)
    }

    func completeActionItem(_: ActionItemID, in _: WorkItemID, scope: SynchronizationScope) async throws {}
    func editActionItem(_: LocalActionItemEdit, actionItemID _: ActionItemID, in _: WorkItemID, expectedUpdatedAt _: Date, scope _: SynchronizationScope) async throws -> ActionItem { throw CancellationError() }

    func appliedScopes() -> [SynchronizationScope] { scopes }
}

private actor CoordinatorRuntimeSpy: AccountWorkspaceRefreshRunning {
    private let currentScope: SynchronizationScope
    private var refreshed = [SynchronizationScope]()
    private var activations = 0
    private var cancellations = 0

    init(currentScope: SynchronizationScope) {
        self.currentScope = currentScope
    }

    func select(_ scope: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? {
        guard scope == currentScope else { throw CancellationError() }
        return nil
    }

    func refresh(
        _ scope: SynchronizationScope,
        priority _: AccountOrganizationRefreshPriority
    ) async throws -> AccountOrganizationCoordinatorState? {
        guard scope == currentScope else { throw CancellationError() }
        refreshed.append(scope)
        return nil
    }

    func cancel(organizationID _: OrganizationID) async throws {}

    func applicationDidBecomeActive(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID _: AccountID?
    ) async throws {
        guard synchronizationScopes.allSatisfy({ $0 == currentScope }) else {
            throw CancellationError()
        }
        activations += 1
    }

    func cancelAll() async throws {
        cancellations += 1
    }

    func refreshScopes() -> [SynchronizationScope] { refreshed }
    func activationCount() -> Int { activations }
    func cancelCount() -> Int { cancellations }
}

private actor RotatingCoordinatorRuntimeFactory {
    private var values: [any AccountWorkspaceRefreshRunning]
    private var resolutions = 0

    init(_ values: [any AccountWorkspaceRefreshRunning]) {
        self.values = values
    }

    func makeRuntime(for _: AccountID) throws -> any AccountWorkspaceRefreshRunning {
        guard !values.isEmpty else { throw CoordinatorRuntimeFactoryError.exhausted }
        resolutions += 1
        return values.removeFirst()
    }

    func resolutionCount() -> Int { resolutions }
}

private enum CoordinatorRuntimeFactoryError: Error {
    case exhausted
}

private actor CoordinatorBackgroundSchedulerSpy: OrganizationRefreshBackgroundScheduling {
    private var operation: (@Sendable () async -> Void)?

    func schedule(
        identifier _: String,
        interval _: TimeInterval,
        operation: @escaping @Sendable () async -> Void
    ) async {
        self.operation = operation
    }

    func cancel(identifier _: String) async {
        operation = nil
    }

    func runScheduledOperation() async {
        guard let operation else { return }
        await operation()
    }
}

private actor SuspendedCoordinatorRuntimeFactory {
    private let stale: any AccountWorkspaceRefreshRunning
    private let fresh: any AccountWorkspaceRefreshRunning
    private var resolutions = 0
    private var firstResolutionStarted = false
    private var firstResolutionWaiters = [CheckedContinuation<Void, Never>]()
    private var firstResolutionContinuation: CheckedContinuation<Void, Never>?

    init(stale: any AccountWorkspaceRefreshRunning, fresh: any AccountWorkspaceRefreshRunning) {
        self.stale = stale
        self.fresh = fresh
    }

    func makeRuntime(for _: AccountID) async throws -> any AccountWorkspaceRefreshRunning {
        resolutions += 1
        guard resolutions == 1 else { return fresh }
        firstResolutionStarted = true
        let waiters = firstResolutionWaiters
        firstResolutionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            firstResolutionContinuation = continuation
        }
        return stale
    }

    func waitUntilFirstResolutionStarts() async {
        guard !firstResolutionStarted else { return }
        await withCheckedContinuation { continuation in
            firstResolutionWaiters.append(continuation)
        }
    }

    func resumeFirstResolution() {
        let continuation = firstResolutionContinuation
        firstResolutionContinuation = nil
        continuation?.resume()
    }

    func resolutionCount() -> Int { resolutions }
}
