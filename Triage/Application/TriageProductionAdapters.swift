import Foundation

/// The production, local-only composition root. It deliberately has no
/// convenience/default constructor: application launch must either construct
/// every dependency or fail visibly before presenting a partially functional
/// workspace.
struct TriageProductionComposition: Sendable {
    let vaultRegistry: VaultRegistry
    let secretStore: KeychainSecretStore
    let applicationSupportDirectory: URL
    let cachesDirectory: URL

    init(
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        applicationSupportDirectory: URL,
        cachesDirectory: URL
    ) {
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cachesDirectory = cachesDirectory
    }

    func dependencies(
        notificationSettings: (any NotificationDeliveryPreferencesProviding)? = nil,
        notificationDeliveryLeaseGate: NotificationDeliveryLeaseGate? = nil,
        businessDayPolicyProvider: @escaping @Sendable () -> BusinessDayPolicy = { .init() },
        purgeAccountNavigationState: @escaping AccountNavigationStatePurging = { _ in },
        purgeAccountNotificationPreferences: @escaping AccountNotificationPreferencePurging = { _ in }
    ) -> TriageApplicationDependencies {
        let deletionRecoveryStatePurger = AccountDeletionRecoveryStatePurger(
            purgeAccountNavigationState: purgeAccountNavigationState
        )
        let copilotRuntimeAuthorization = CopilotRuntimeAuthenticationService(
            applicationSupportDirectory: applicationSupportDirectory,
            secretStore: secretStore
        )
        let copilotCandidateBudgetAvailability = OrganizationCopilotCandidateBudgetAvailabilityProvider(
            vaultRegistry: vaultRegistry,
            secretStore: secretStore
        )
        let organizationAIControllers = OrganizationAIControllerRegistry { scope, account in
            let authorizationState = await copilotRuntimeAuthorization.externalState(
                for: scope,
                account: account
            )
            return OrganizationAIExternalState(
                isRuntimeAvailable: authorizationState.isRuntimeAvailable,
                isAuthenticatedIdentityMatch: authorizationState.isAuthenticatedIdentityMatch,
                isEntitled: authorizationState.isEntitled,
                supportsAutoModel: authorizationState.supportsAutoModel,
                availableModelIDs: authorizationState.availableModelIDs,
                hasAvailableBudget: await copilotCandidateBudgetAvailability.hasAvailableBudget(for: scope)
            )
        }
        let workspaceCoordinator = TriageWorkspaceCoordinator(
            vaultRegistry: vaultRegistry,
            secretStore: secretStore,
            backgroundScheduler: NSBackgroundOrganizationRefreshScheduler(),
            organizationAIControllers: organizationAIControllers,
            businessDayPolicyProvider: businessDayPolicyProvider
        )
        let databaseObserver = DatabaseWorkspaceObserver(
            vaultRegistry: vaultRegistry,
            secretStore: secretStore
        )
        let inboxPageObserver = DatabaseInboxPageObserver(
            vaultRegistry: vaultRegistry,
            secretStore: secretStore
        )
        let workspaceObserver: any WorkspaceObserving
        let workspaceObservationLifecycle: any WorkspaceObservationLifecycleHandling
        if let notificationSettings {
            let notificationObserver = NotificationDeliveringWorkspaceObserver(
                source: databaseObserver,
                vaultRegistry: vaultRegistry,
                secretStore: secretStore,
                settings: notificationSettings,
                deliveryLeaseGate: notificationDeliveryLeaseGate ?? .init()
            )
            workspaceObserver = notificationObserver
            workspaceObservationLifecycle = notificationObserver
        } else {
            workspaceObserver = databaseObserver
            workspaceObservationLifecycle = NoopWorkspaceObservationLifecycle()
        }
        return TriageApplicationDependencies(
            accountSession: TriageAccountSessionService(
                vaultRegistry: vaultRegistry,
                secretStore: secretStore,
                applicationSupportDirectory: applicationSupportDirectory,
                cachesDirectory: cachesDirectory,
                organizationAIControllers: organizationAIControllers,
                copilotRuntimeAuthorization: copilotRuntimeAuthorization,
                deletionRecoveryStatePurger: deletionRecoveryStatePurger
            ),
            workspaceCoordinator: workspaceCoordinator,
            refreshLifecycle: workspaceCoordinator,
            workspaceObserver: workspaceObserver,
            inboxPageObserver: inboxPageObserver,
            workspaceObservationLifecycle: workspaceObservationLifecycle,
            workspaceMutator: TriageWorkspaceMutator(
                vaultRegistry: vaultRegistry,
                secretStore: secretStore
            ),
            organizationAIControllers: organizationAIControllers,
            copilotRuntimeAuthorization: copilotRuntimeAuthorization,
            purgeAccountNavigationState: purgeAccountNavigationState,
            purgeAccountNotificationPreferences: purgeAccountNotificationPreferences
        )
    }
}

actor TriageAccountSessionService: AccountSessionServing {
    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore
    private let applicationSupportDirectory: URL
    private let cachesDirectory: URL
    private let restoreAccountState: @Sendable () async throws -> AccountRestorationResult
    private let recoverInterruptedRemovals: @Sendable () async throws -> [AccountID]
    private let deletionRecoveryStatePurger: any AccountDeletionRecoveryStatePurging
    private let organizationAIControllers: any OrganizationAIControllerProviding
    private let copilotRuntimeAuthorization: any CopilotRuntimeAuthorizationProviding

    init(
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        applicationSupportDirectory: URL,
        cachesDirectory: URL,
        restoreAccountState: (@Sendable () async throws -> AccountRestorationResult)? = nil,
        recoverInterruptedRemovals: (@Sendable () async throws -> [AccountID])? = nil,
        organizationAIControllers: any OrganizationAIControllerProviding = OrganizationAIControllerRegistry(),
        copilotRuntimeAuthorization: any CopilotRuntimeAuthorizationProviding = NoopCopilotRuntimeAuthorizationProvider(),
        deletionRecoveryStatePurger: any AccountDeletionRecoveryStatePurging = NoopAccountDeletionRecoveryStatePurger()
    ) {
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cachesDirectory = cachesDirectory
        self.restoreAccountState = restoreAccountState ?? {
            try await AccountRestorationService(
                secretStore: secretStore,
                vaultRegistry: vaultRegistry
            ).restore()
        }
        self.recoverInterruptedRemovals = recoverInterruptedRemovals ?? {
            try await AccountDataRemovalService(
                vaultRegistry: vaultRegistry,
                secretStore: secretStore,
                applicationSupportDirectory: applicationSupportDirectory,
                cachesDirectory: cachesDirectory
            ).recoverInterruptedRemovals()
        }
        self.organizationAIControllers = organizationAIControllers
        self.copilotRuntimeAuthorization = copilotRuntimeAuthorization
        self.deletionRecoveryStatePurger = deletionRecoveryStatePurger
    }

    func restoreAccounts() async throws -> AccountSessionSnapshot {
        // A journal is the sole durable authorization for recovery. Complete it
        // before restoration so a keyless vault can never reappear as usable.
        let recoveredAccountIDs = try await recoverInterruptedRemovals()
        for accountID in recoveredAccountIDs {
            await deletionRecoveryStatePurger.purgeRecoveredDeletedAccountState(for: accountID)
        }
        return try await restoredSnapshot()
    }

    func connectOAuth(_ request: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot {
        let configuration = try RuntimeOAuthConfiguration()
        _ = try await AccountConnectionService(
            brokerURL: configuration.brokerURL,
            applicationVersion: configuration.applicationVersion,
            secretStore: secretStore,
            vaultRegistry: vaultRegistry
        ).connectOAuth(exchangeRequest: request)
        return try await restoredSnapshot()
    }

    func connectPersonalAccessToken(
        _ token: PersonalAccessToken,
        resourceOwnerOrganization: String?
    ) async throws -> AccountSessionSnapshot {
        _ = try await AccountConnectionService(
            secretStore: secretStore,
            vaultRegistry: vaultRegistry
        ).connect(personalAccessToken: token, resourceOwnerOrganization: resourceOwnerOrganization)
        return try await restoredSnapshot()
    }

    func reconnectOAuth(
        _ request: AuthBrokerExchangeRequest,
        replacing account: GitHubAccount
    ) async throws -> AccountSessionSnapshot {
        let configuration = try RuntimeOAuthConfiguration()
        let response = try await AuthBrokerClient(
            baseURL: configuration.brokerURL,
            applicationVersion: configuration.applicationVersion
        ).exchange(request)
        let replacement = try await AccountCredentialReplacementService(
            secretStore: secretStore,
            vaultRegistry: vaultRegistry
        ).replace(oauthTokenResponse: response, for: account)
        await replayOrganizationInventory(after: replacement)
        return try await restoredSnapshot(
            credentialActionNotice: replacement.retiredCredentialCleanupFailed
                ? "The new credential is active, but Triage could not erase the retired Keychain entry."
                : nil
        )
    }

    func replacePersonalAccessToken(
        _ token: PersonalAccessToken,
        replacing account: GitHubAccount
    ) async throws -> AccountSessionSnapshot {
        let replacement = try await AccountCredentialReplacementService(
            secretStore: secretStore,
            vaultRegistry: vaultRegistry
        ).replace(personalAccessToken: token, for: account)
        await replayOrganizationInventory(after: replacement)
        return try await restoredSnapshot(
            credentialActionNotice: replacement.retiredCredentialCleanupFailed
                ? "The new credential is active, but Triage could not erase the retired Keychain entry."
                : nil
        )
    }

    func removeAccount(_ accountID: AccountID) async throws {
        try await AccountDataRemovalService(
            vaultRegistry: vaultRegistry,
            secretStore: secretStore,
            applicationSupportDirectory: applicationSupportDirectory,
            cachesDirectory: cachesDirectory,
            willBeginCryptoErasure: { [organizationAIControllers, copilotRuntimeAuthorization] in
                // A deletion journal fences future helper scratch, but an
                // already-running controller can still own a helper process.
                // Drain it before crossing the irreversible key-erasure
                // boundary so it cannot recreate account-scoped artifacts.
                await organizationAIControllers.evict(accountID: accountID)
                // This closure is also reached by recovery/deletion paths
                // that do not pass through the view model.
                await copilotRuntimeAuthorization.disconnect(accountID: accountID)
            }
        ).removeAllPrivateData(for: accountID)
        await GitHubRateLimitControllerRegistry.shared.removeController(for: accountID)
    }

    func restoreVerifiedMigrationBackup(
        for accountID: AccountID,
        migrationID: String
    ) async throws -> AccountSessionSnapshot {
        guard let keyData = try await secretStore.read(
            kind: .vaultKey,
            accountID: accountID,
            credentialID: nil
        ) else {
            throw VaultError.invalidMigrationBackup
        }
        let vaultKey = try VaultKey(data: keyData)
        // The registry repeats verification immediately before installing the
        // copy, so the UI's earlier recovery snapshot cannot authorize a
        // stale or replaced backup.
        try await vaultRegistry.restoreVerifiedMigrationBackup(
            accountID: accountID,
            vaultKey: vaultKey,
            migrationID: migrationID
        )
        return try await restoredSnapshot()
    }

    private func restoredSnapshot(credentialActionNotice: String? = nil) async throws -> AccountSessionSnapshot {
        let result = try await restoreAccountState()
        return try AccountSessionSnapshot(
            accounts: result.accounts,
            organizationsByAccount: result.organizationsByAccount,
            organizationAccessesByAccount: result.organizationAccessesByAccount,
            accountCapabilitiesByAccount: result.accountCapabilitiesByAccount,
            unavailableAccountIDs: Set(result.unavailableAccountIDs),
            vaultRecoveryIssues: result.vaultRecoveryIssues,
            credentialActionNotice: credentialActionNotice
        )
    }

    /// A credential rotation has already committed a new credential revision
    /// when this runs. The replay service persists and validates its bounded
    /// raw receipt before returning a complete inventory; only then do we
    /// upsert safely decoded identities. Any replay failure preserves prior
    /// membership and access rows rather than manufacturing an empty session.
    private func replayOrganizationInventory(
        after replacement: AccountCredentialReplacementResult
    ) async {
        do {
            try Task.checkCancellation()
            guard let vaultKey = try await secretStore.readVaultKey(for: replacement.account.id) else {
                return
            }
            let vault = try await vaultRegistry.open(accountID: replacement.account.id, vaultKey: vaultKey)
            let rateLimitController = try await GitHubRateLimitControllerRegistry.shared.controller(
                for: replacement.account.id,
                vault: vault
            )
            let token = try await AccountCredentialReader(secretStore: secretStore)
                .accessToken(for: replacement.account)
            try Task.checkCancellation()
            let client = GitHubRESTClient(
                transport: try GitHubRESTTransport(),
                credential: token,
                rateLimitController: rateLimitController,
                requestPriority: .selectedOrganizationRefresh
            )
            let receipts = PostAccountIdentityReplayReceiptRepository(vault: vault)
            let inventory = try await PostAccountOrganizationInventoryReplayService(
                client: GitHubIdentityClient(client: client),
                receipts: receipts,
                rawSnapshots: RawAPISnapshotRepository(vault: vault)
            ).organizations(
                accountID: replacement.account.id,
                credentialRevision: replacement.credentialRevision
            )
            try Task.checkCancellation()
            // Recheck exact account authority after the final network/receipt
            // boundary, before touching any account-organization row.
            _ = try await receipts.inventoryValidators(
                for: AccountOrganizationInventoryReplayIdentity(
                    accountID: replacement.account.id,
                    credentialRevision: replacement.credentialRevision
                )
            )
            let organizations = try inventory.organizations.map(Self.organizationForInventoryReplay)
            let repository = AccountRepository(vault: vault)
            try await repository.reconcilePostCredentialOrganizationInventory(
                organizations,
                accountID: replacement.account.id,
                expectedCredentialRevision: replacement.credentialRevision,
                observedAt: Date()
            )
        } catch is CancellationError {
            return
        } catch {
            // The credential replacement remains valid. Receipt, transport,
            // or identity failures intentionally leave prior memberships in
            // place and are surfaced by subsequent scoped refresh coverage.
            return
        }
    }

    static func organizationForInventoryReplay(
        _ value: GitHubOrganizationDTO
    ) throws -> GitHubOrganization {
        guard let nodeID = GitHubNodeID(rawValue: value.nodeID),
              let organizationID = OrganizationID(rawValue: value.nodeID)
        else {
            throw AccountConnectionError.invalidGitHubIdentity
        }
        return GitHubOrganization(
            id: organizationID,
            githubOrganizationID: value.id,
            nodeID: nodeID,
            login: value.login,
            avatarURL: value.avatarURL
        )
    }

}

private actor OrganizationRefreshLifecycleInputs {
    private var synchronizationScopes = [SynchronizationScope]()
    private var activeAccountID: AccountID?

    func replace(synchronizationScopes: [SynchronizationScope], activeAccountID: AccountID?) {
        self.synchronizationScopes = synchronizationScopes
        self.activeAccountID = activeAccountID
    }

    func scopes() -> [SynchronizationScope] { synchronizationScopes }
    func activeAccount() -> AccountID? { activeAccountID }
}

/// The coordinator needs both the foreground request surface and the narrow
/// lifecycle surface. Keeping this seam explicit lets tests exercise the
/// production coordinator's revision and teardown behavior without opening a
/// Keychain or a network client.
protocol AccountWorkspaceRefreshRunning: AccountOrganizationLifecycleRunning {
    func select(_ scope: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState?
    func refresh(
        _ scope: SynchronizationScope,
        priority: AccountOrganizationRefreshPriority
    ) async throws -> AccountOrganizationCoordinatorState?
    func cancel(organizationID: OrganizationID) async throws
}

extension AccountOrganizationRefreshRuntime: AccountWorkspaceRefreshRunning {}

actor TriageWorkspaceCoordinator: WorkspaceCoordinating, OrganizationRefreshLifecycleHandling {
    private let backgroundScheduler: any OrganizationRefreshBackgroundScheduling
    private let organizationAIControllers: any OrganizationAIControllerProviding
    private let makeRuntime: @Sendable (AccountID) async throws -> any AccountWorkspaceRefreshRunning
    private let closeAllVaults: @Sendable () async throws -> Void
    private var runtimes: [AccountID: any AccountWorkspaceRefreshRunning] = [:]
    // `cancelAll` is called before account/session mutation has replaced the
    // lifecycle inputs. Keep a fail-closed fence during that interval so an
    // opportunistic callback cannot create a new vault runtime from stale
    // scopes while the old vault is being removed.
    private var runtimeCreationBlockedAccounts = Set<AccountID>()
    // A blocked-account check before `makeRuntime` is not sufficient because
    // opening an encrypted vault suspends. The epoch lets a resuming factory
    // result prove it was created in the same account lifetime.
    private var runtimeCreationEpochs = [AccountID: UInt64]()
    private var isShutDown = false
    private let lifecycleInputs = OrganizationRefreshLifecycleInputs()
    private lazy var lifecycleService = OrganizationRefreshLifecycleService(
        enumerateScopes: { [weak self] in
            guard let self else { throw CancellationError() }
            return await self.lifecycleInputs.scopes()
        },
        activeAccountID: { [weak self] in
            guard let self else { return nil }
            return await self.lifecycleInputs.activeAccount()
        },
        resolveRuntime: { [weak self] accountID in
            guard let self else { throw CancellationError() }
            return try await self.runtime(for: accountID)
        },
        backgroundScheduler: backgroundScheduler
    )

    init(
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        backgroundScheduler: any OrganizationRefreshBackgroundScheduling,
        organizationAIControllers: any OrganizationAIControllerProviding = OrganizationAIControllerRegistry(),
        businessDayPolicyProvider: @escaping @Sendable () -> BusinessDayPolicy = { .init() }
    ) {
        self.backgroundScheduler = backgroundScheduler
        self.organizationAIControllers = organizationAIControllers
        closeAllVaults = { try await vaultRegistry.closeAll() }
        makeRuntime = { accountID in
            guard let vaultKey = try await secretStore.readVaultKey(for: accountID) else {
                throw AccountCredentialReaderError.missingAccessToken
            }
            let vault = try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)
            return AccountOrganizationRefreshRuntime(
                accountID: accountID,
                vault: vault,
                credentialReader: AccountCredentialReader(secretStore: secretStore),
                vaultRegistry: vaultRegistry,
                secretStore: secretStore,
                organizationAIController: await organizationAIControllers.controller(for: vault),
                businessDayPolicyProvider: businessDayPolicyProvider
            )
        }
    }

    init(
        backgroundScheduler: any OrganizationRefreshBackgroundScheduling = DisabledOrganizationRefreshBackgroundScheduler(),
        makeRuntime: @escaping @Sendable (AccountID) async throws -> any AccountWorkspaceRefreshRunning,
        closeAllVaults: @escaping @Sendable () async throws -> Void = {},
        organizationAIControllers: any OrganizationAIControllerProviding = OrganizationAIControllerRegistry()
    ) {
        self.backgroundScheduler = backgroundScheduler
        self.organizationAIControllers = organizationAIControllers
        self.makeRuntime = makeRuntime
        self.closeAllVaults = closeAllVaults
    }

    func select(_ scope: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? {
        try await runtime(for: scope.accountID).select(scope)
    }

    func refresh(
        _ scope: SynchronizationScope,
        priority: AccountOrganizationRefreshPriority
    ) async throws -> AccountOrganizationCoordinatorState? {
        try await runtime(for: scope.accountID).refresh(
            scope,
            priority: priority
        )
    }

    func cancel(_ scope: SynchronizationScope) async throws {
        guard let runtime = runtimes[scope.accountID] else { return }
        try await runtime.cancel(organizationID: scope.organizationID)
    }

    func cancelAll(for accountID: AccountID) async throws {
        runtimeCreationBlockedAccounts.insert(accountID)
        runtimeCreationEpochs[accountID, default: 0] &+= 1
        // Lifecycle retains its own runtime cache. Evict and interrupt that
        // copy too, so a credential replacement/removal cannot later reuse a
        // torn-down runtime or reopen the old vault.
        await lifecycleService.evictRuntime(for: accountID)
        guard let runtime = runtimes.removeValue(forKey: accountID) else {
            await organizationAIControllers.evict(accountID: accountID)
            return
        }
        do {
            try await runtime.cancelAll()
            await organizationAIControllers.evict(accountID: accountID)
        } catch {
            await organizationAIControllers.evict(accountID: accountID)
            throw error
        }
    }

    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        await lifecycleService.stop()
        let active = runtimes
        runtimes.removeAll()
        for runtime in active.values {
            try? await runtime.cancelAll()
        }
        // Settings-owned controllers can outlive a refresh runtime. They
        // retain their account vault and may still be draining a
        // non-cooperative analysis operation, so release them before the
        // registry closes every vault.
        await organizationAIControllers.evictAll()
        try? await closeAllVaults()
    }

    func launch(synchronizationScopes: [SynchronizationScope], activeAccountID: AccountID?) async {
        await updateLifecycleInputs(synchronizationScopes, activeAccountID: activeAccountID)
        await lifecycleService.scheduleOpportunisticBackgroundRefresh()
        _ = try? await lifecycleService.launch()
    }

    func applicationDidBecomeActive(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async {
        await updateLifecycleInputs(synchronizationScopes, activeAccountID: activeAccountID)
        _ = try? await lifecycleService.applicationDidBecomeActive()
    }

    func wake(synchronizationScopes: [SynchronizationScope], activeAccountID: AccountID?) async {
        await updateLifecycleInputs(synchronizationScopes, activeAccountID: activeAccountID)
        _ = try? await lifecycleService.wake()
    }

    func scheduleOpportunisticBackgroundRefresh(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async {
        await updateLifecycleInputs(synchronizationScopes, activeAccountID: activeAccountID)
        await lifecycleService.scheduleOpportunisticBackgroundRefresh()
    }

    func stop() async {
        await lifecycleService.stop()
    }

    private func updateLifecycleInputs(
        _ synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async {
        guard !isShutDown else { return }
        // A new externally supplied lifecycle snapshot is authoritative. If
        // this account survived credential replacement, it may now construct
        // a fresh runtime; removed accounts are absent and remain fenced.
        runtimeCreationBlockedAccounts.subtract(
            Set(synchronizationScopes.map(\.accountID))
        )
        await lifecycleInputs.replace(
            synchronizationScopes: synchronizationScopes,
            activeAccountID: activeAccountID
        )
    }

    private func runtime(for accountID: AccountID) async throws -> any AccountWorkspaceRefreshRunning {
        guard !isShutDown else { throw CancellationError() }
        guard !runtimeCreationBlockedAccounts.contains(accountID) else {
            throw CancellationError()
        }
        if let runtime = runtimes[accountID] { return runtime }
        let expectedEpoch = runtimeCreationEpochs[accountID, default: 0]
        let runtime = try await makeRuntime(accountID)
        guard !isShutDown,
              !runtimeCreationBlockedAccounts.contains(accountID),
              runtimeCreationEpochs[accountID, default: 0] == expectedEpoch
        else {
            try? await runtime.cancelAll()
            throw CancellationError()
        }
        if let existing = runtimes[accountID] {
            try? await runtime.cancelAll()
            return existing
        }
        runtimes[accountID] = runtime
        return runtime
    }
}

actor TriageWorkspaceMutator: WorkspaceMutating {
    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore

    init(vaultRegistry: VaultRegistry, secretStore: KeychainSecretStore) {
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
    }

    func apply(_ action: WorkflowAction, to workItemID: WorkItemID, in scope: SynchronizationScope) async throws {
        try await apply(
            action,
            to: workItemID,
            in: scope,
            expectedAuthorization: nil
        )
    }

    func apply(
        _ action: WorkflowAction,
        to workItemIDs: [WorkItemID],
        in scope: SynchronizationScope
    ) async throws {
        _ = try await applyWorkflowHistory(action, to: workItemIDs, in: scope)
    }

    func applyWorkflowHistory(
        _ action: WorkflowAction,
        to workItemIDs: [WorkItemID],
        in scope: SynchronizationScope
    ) async throws -> WorkflowHistoryTransaction {
        try Task.checkCancellation()
        let vault = try await vault(for: scope.accountID)
        let transaction = try await WorkflowHistoryRepository(vault: vault).apply(
            action,
            to: workItemIDs,
            in: scope
        )
        try Task.checkCancellation()
        try await SearchRepository(vault: vault).rebuild(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
        return transaction
    }

    func undoLatestWorkflow(in scope: SynchronizationScope) async throws -> WorkflowHistoryTransaction {
        try Task.checkCancellation()
        let vault = try await vault(for: scope.accountID)
        let transaction = try await WorkflowHistoryRepository(vault: vault).undoLatest(in: scope)
        try Task.checkCancellation()
        try await SearchRepository(vault: vault).rebuild(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
        return transaction
    }

    func redoLatestWorkflow(in scope: SynchronizationScope) async throws -> WorkflowHistoryTransaction {
        try Task.checkCancellation()
        let vault = try await vault(for: scope.accountID)
        let transaction = try await WorkflowHistoryRepository(vault: vault).redoLatest(in: scope)
        try Task.checkCancellation()
        try await SearchRepository(vault: vault).rebuild(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
        return transaction
    }

    func undoWorkflow(transactionID: String, in scope: SynchronizationScope) async throws -> WorkflowHistoryTransaction {
        try Task.checkCancellation()
        let vault = try await vault(for: scope.accountID)
        let transaction = try await WorkflowHistoryRepository(vault: vault).undo(transactionID, in: scope)
        try Task.checkCancellation()
        try await SearchRepository(vault: vault).rebuild(accountID: scope.accountID, organizationID: scope.organizationID)
        return transaction
    }

    func redoWorkflow(transactionID: String, in scope: SynchronizationScope) async throws -> WorkflowHistoryTransaction {
        try Task.checkCancellation()
        let vault = try await vault(for: scope.accountID)
        let transaction = try await WorkflowHistoryRepository(vault: vault).redo(transactionID, in: scope)
        try Task.checkCancellation()
        try await SearchRepository(vault: vault).rebuild(accountID: scope.accountID, organizationID: scope.organizationID)
        return transaction
    }

    func applyNotificationAction(
        _ action: WorkflowAction,
        to workItemID: WorkItemID,
        in scope: SynchronizationScope,
        expectedAuthorization: NotificationActionAuthorization
    ) async throws {
        try await apply(
            action,
            to: workItemID,
            in: scope,
            expectedAuthorization: expectedAuthorization
        )
    }

    private func apply(
        _ action: WorkflowAction,
        to workItemID: WorkItemID,
        in scope: SynchronizationScope,
        expectedAuthorization: NotificationActionAuthorization?
    ) async throws {
        let vault = try await vault(for: scope.accountID)
        guard let item = try await WorkItemRepository(vault: vault)
            .fetch(accountID: scope.accountID, organizationID: scope.organizationID)
            .first(where: { $0.id == workItemID }) else {
            throw WorkflowRepositoryError.workItemScopeMismatch
        }
        if let expectedAuthorization {
            let route = NotificationRoute(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                workItemID: workItemID,
                actionAuthorization: expectedAuthorization
            )
            guard NotificationActionAuthorizationValidator.matches(route: route, workItem: item) else {
                throw NotificationActionAuthorizationError.staleEvidence
            }
        }
        try Task.checkCancellation()
        _ = try await applyWorkflowHistory(action, to: [item.id], in: scope)
    }

    func completeActionItem(
        _ actionItemID: ActionItemID,
        in workItemID: WorkItemID,
        scope: SynchronizationScope
    ) async throws {
        let vault = try await vault(for: scope.accountID)
        guard let item = try await WorkItemRepository(vault: vault)
            .fetch(accountID: scope.accountID, organizationID: scope.organizationID)
            .first(where: { $0.id == workItemID }),
              let actionItem = item.actionItems.first(where: { $0.id == actionItemID }) else {
            throw WorkflowRepositoryError.workItemScopeMismatch
        }
        try await WorkflowRepository(vault: vault).save(actionItem.completing(at: .now))
        try await SearchRepository(vault: vault).rebuild(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
    }

    func editActionItem(
        _ edit: LocalActionItemEdit,
        actionItemID: ActionItemID,
        in workItemID: WorkItemID,
        expectedUpdatedAt: Date,
        scope: SynchronizationScope
    ) async throws -> ActionItem {
        let vault = try await vault(for: scope.accountID)
        let item = try await WorkItemRepository(vault: vault)
            .fetch(accountID: scope.accountID, organizationID: scope.organizationID)
            .first(where: { $0.id == workItemID })
        let updated = try Self.editedActionItem(
            existing: item?.actionItems.first(where: { $0.id == actionItemID }),
            actionItemID: actionItemID,
            expectedUpdatedAt: expectedUpdatedAt,
            edit: edit,
            now: .now
        )
        try await WorkflowRepository(vault: vault).save(updated)
        try await SearchRepository(vault: vault).rebuild(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
        return updated
    }

    func applyGroupingMutation(
        _ mutation: WorkItemGroupingMutation,
        in scope: SynchronizationScope
    ) async throws -> WorkItemGroupingMutationHistory {
        let vault = try await vault(for: scope.accountID)
        return try await WorkItemGroupingDecisionService(vault: vault)
            .apply(mutation, scope: scope)
    }

    func restoreGroupingDecisions(
        _ decisions: [WorkItemGroupingDecision],
        expectedCurrent: [WorkItemGroupingDecision],
        in scope: SynchronizationScope
    ) async throws {
        let vault = try await vault(for: scope.accountID)
        try await WorkItemGroupingDecisionService(vault: vault).restore(
            decisions,
            expectedCurrent: expectedCurrent,
            scope: scope
        )
    }

    func assignActionItem(
        _ actionItemID: ActionItemID,
        expectedOwnerWorkItemID: WorkItemID,
        visibleWorkItemID: WorkItemID,
        destinationNodeID: GitHubNodeID,
        in scope: SynchronizationScope
    ) async throws {
        let vault = try await vault(for: scope.accountID)
        try await WorkItemGroupingDecisionService(vault: vault).assignActionItem(
            actionItemID,
            expectedOwnerWorkItemID: expectedOwnerWorkItemID,
            visibleWorkItemID: visibleWorkItemID,
            destinationNodeID: destinationNodeID,
            scope: scope
        )
    }

    nonisolated static func editedActionItem(
        existing: ActionItem?,
        actionItemID: ActionItemID,
        expectedUpdatedAt: Date,
        edit: LocalActionItemEdit,
        now: Date
    ) throws -> ActionItem {
        guard let existing,
              existing.id == actionItemID,
              existing.updatedAt == expectedUpdatedAt
        else {
            throw WorkflowRepositoryError.workItemScopeMismatch
        }
        return existing.applying(edit, at: now)
    }

    private func vault(for accountID: AccountID) async throws -> AccountVault {
        guard let vaultKey = try await secretStore.readVaultKey(for: accountID) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        return try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)
    }
}
