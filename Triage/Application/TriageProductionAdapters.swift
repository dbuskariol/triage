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

    func dependencies() -> TriageApplicationDependencies {
        let workspaceCoordinator = TriageWorkspaceCoordinator(
            vaultRegistry: vaultRegistry,
            secretStore: secretStore
        )
        return TriageApplicationDependencies(
            accountSession: TriageAccountSessionService(
                vaultRegistry: vaultRegistry,
                secretStore: secretStore,
                applicationSupportDirectory: applicationSupportDirectory,
                cachesDirectory: cachesDirectory
            ),
            workspaceCoordinator: workspaceCoordinator,
            refreshLifecycle: workspaceCoordinator,
            workspaceObserver: DatabaseWorkspaceObserver(
                vaultRegistry: vaultRegistry,
                secretStore: secretStore
            ),
            workspaceMutator: TriageWorkspaceMutator(
                vaultRegistry: vaultRegistry,
                secretStore: secretStore
            )
        )
    }
}

actor TriageAccountSessionService: AccountSessionServing {
    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore
    private let applicationSupportDirectory: URL
    private let cachesDirectory: URL

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

    func restoreAccounts() async throws -> AccountSessionSnapshot {
        // A journal is the sole durable authorization for recovery. Complete it
        // before restoration so a keyless vault can never reappear as usable.
        _ = try await AccountDataRemovalService(
            vaultRegistry: vaultRegistry,
            secretStore: secretStore,
            applicationSupportDirectory: applicationSupportDirectory,
            cachesDirectory: cachesDirectory
        ).recoverInterruptedRemovals()
        return try await restoredSnapshot()
    }

    func connectOAuth(_ request: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot {
        let configuration = try RuntimeOAuthConfiguration()
        _ = try await AccountConnectionService(
            brokerURL: configuration.brokerURL,
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
        let response = try await AuthBrokerClient(baseURL: configuration.brokerURL).exchange(request)
        let replacement = try await AccountCredentialReplacementService(
            secretStore: secretStore,
            vaultRegistry: vaultRegistry
        ).replace(oauthTokenResponse: response, for: account)
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
            cachesDirectory: cachesDirectory
        ).removeAllPrivateData(for: accountID)
        await GitHubRateLimitControllerRegistry.shared.removeController(for: accountID)
    }

    private func restoredSnapshot(credentialActionNotice: String? = nil) async throws -> AccountSessionSnapshot {
        let result = try await AccountRestorationService(
            secretStore: secretStore,
            vaultRegistry: vaultRegistry
        ).restore()
        return try AccountSessionSnapshot(
            accounts: result.accounts,
            organizationsByAccount: result.organizationsByAccount,
            organizationAccessesByAccount: result.organizationAccessesByAccount,
            accountCapabilitiesByAccount: result.accountCapabilitiesByAccount,
            unavailableAccountIDs: Set(result.unavailableAccountIDs),
            credentialActionNotice: credentialActionNotice
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

actor TriageWorkspaceCoordinator: WorkspaceCoordinating, OrganizationRefreshLifecycleHandling {
    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore
    private var runtimes: [AccountID: AccountOrganizationRefreshRuntime] = [:]
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
        }
    )

    init(vaultRegistry: VaultRegistry, secretStore: KeychainSecretStore) {
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
    }

    func select(_ scope: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? {
        let state = try await runtime(for: scope.accountID).select(organizationID: scope.organizationID)
        return state?.synchronizationScope == scope ? state : nil
    }

    func refresh(
        _ scope: SynchronizationScope,
        priority: AccountOrganizationRefreshPriority
    ) async throws -> AccountOrganizationCoordinatorState? {
        let state = try await runtime(for: scope.accountID).refresh(
            organizationID: scope.organizationID,
            priority: priority
        )
        return state?.synchronizationScope == scope ? state : nil
    }

    func cancel(_ scope: SynchronizationScope) async throws {
        guard let runtime = runtimes[scope.accountID] else { return }
        try await runtime.cancel(organizationID: scope.organizationID)
    }

    func cancelAll(for accountID: AccountID) async throws {
        guard let runtime = runtimes.removeValue(forKey: accountID) else { return }
        try await runtime.cancelAll()
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
        try? await vaultRegistry.closeAll()
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
        await lifecycleInputs.replace(
            synchronizationScopes: synchronizationScopes,
            activeAccountID: activeAccountID
        )
    }

    private func runtime(for accountID: AccountID) async throws -> AccountOrganizationRefreshRuntime {
        guard !isShutDown else { throw CancellationError() }
        if let runtime = runtimes[accountID] { return runtime }
        guard let vaultKey = try await secretStore.readVaultKey(for: accountID) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)
        guard !isShutDown else { throw CancellationError() }
        if let runtime = runtimes[accountID] { return runtime }
        let runtime = AccountOrganizationRefreshRuntime(
            accountID: accountID,
            vault: vault,
            credentialReader: AccountCredentialReader(secretStore: secretStore),
            vaultRegistry: vaultRegistry,
            secretStore: secretStore
        )
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
        let vault = try await vault(for: scope.accountID)
        guard let item = try await WorkItemRepository(vault: vault)
            .fetch(accountID: scope.accountID, organizationID: scope.organizationID)
            .first(where: { $0.id == workItemID }) else {
            throw WorkflowRepositoryError.workItemScopeMismatch
        }
        _ = try await WorkflowActionService(secretStore: secretStore, vaultRegistry: vaultRegistry)
            .apply(action, to: item)
        try await SearchRepository(vault: vault).rebuild(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
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

    private func vault(for accountID: AccountID) async throws -> AccountVault {
        guard let vaultKey = try await secretStore.readVaultKey(for: accountID) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        return try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)
    }
}
