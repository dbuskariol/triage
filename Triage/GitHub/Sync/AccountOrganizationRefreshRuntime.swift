import Foundation

enum AccountOrganizationRefreshRuntimeError: Error, Equatable, Sendable {
    case tearingDown
}

/// Owns the durable synchronization composition for exactly one encrypted
/// account vault. UI and application lifecycle code interact with this actor;
/// views never construct repositories or GitHub clients.
actor AccountOrganizationRefreshRuntime {
    typealias ScopeResolver = @Sendable (
        AccountID,
        OrganizationID
    ) async throws -> SynchronizationScope

    private enum Lifecycle: Equatable {
        case active
        case tearingDown
        case tornDown
    }

    private let accountID: AccountID
    private let coordinator: AccountOrganizationCoordinator
    private let resolveScope: ScopeResolver
    private var knownScopes: [OrganizationID: SynchronizationScope] = [:]
    private var lifecycle = Lifecycle.active
    private var teardownTask: Task<Void, Error>?

    init(
        accountID: AccountID,
        vault: AccountVault,
        refreshOperation: any AccountOrganizationRefreshOperating,
        scopeResolver: ScopeResolver? = nil,
        activateCachedState: @escaping AccountOrganizationCoordinator.CachedStateActivation = { _, _ in }
    ) {
        self.accountID = accountID
        resolveScope = scopeResolver ?? { accountID, organizationID in
            try await AccountRepository(vault: vault).synchronizationScope(
                for: accountID,
                organizationID: organizationID
            )
        }
        let durableStateRepository = AccountOrganizationDurableStateRepository(vault: vault)
        coordinator = AccountOrganizationCoordinator(
            stateStore: durableStateRepository,
            scheduleStore: OrganizationSchedulerStateRepository(vault: vault),
            finalizer: durableStateRepository,
            refreshOperation: refreshOperation,
            activateCachedState: activateCachedState
        )
    }

    init(
        accountID: AccountID,
        vault: AccountVault,
        credentialReader: AccountCredentialReader,
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        rateLimitControllers: GitHubRateLimitControllerRegistry = .shared,
        organizationAIController: OrganizationAIController? = nil,
        businessDayPolicyProvider: @escaping @Sendable () -> BusinessDayPolicy = { .init() },
        activateCachedState: @escaping AccountOrganizationCoordinator.CachedStateActivation = { _, _ in }
    ) {
        self.accountID = accountID
        resolveScope = { accountID, organizationID in
            try await AccountRepository(vault: vault).synchronizationScope(
                for: accountID,
                organizationID: organizationID
            )
        }
        let durableStateRepository = AccountOrganizationDurableStateRepository(vault: vault)
        coordinator = AccountOrganizationCoordinator(
            stateStore: durableStateRepository,
            scheduleStore: OrganizationSchedulerStateRepository(vault: vault),
            finalizer: durableStateRepository,
            refreshOperation: AccountOrganizationRefreshOperation(
                vault: vault,
                credentialReader: credentialReader,
                vaultRegistry: vaultRegistry,
                secretStore: secretStore,
                rateLimitControllers: rateLimitControllers,
                organizationAIController: organizationAIController,
                businessDayPolicyProvider: businessDayPolicyProvider
            ),
            activateCachedState: activateCachedState
        )
    }

    func select(
        organizationID: OrganizationID
    ) async throws -> AccountOrganizationCoordinatorState? {
        try ensureActive()
        let scope = try await currentScope(for: organizationID)
        return try await runAndWait(for: scope) {
            try await self.coordinator.select(scope)
        }
    }

    /// A caller that already holds a revision-qualified scope must never cause
    /// work for a newer authority revision merely because the account and
    /// organization identifiers still match.
    func select(
        _ expectedScope: SynchronizationScope
    ) async throws -> AccountOrganizationCoordinatorState? {
        try ensureActive()
        guard expectedScope.accountID == accountID else {
            throw CancellationError()
        }
        let currentScope = try await currentScope(for: expectedScope.organizationID)
        guard currentScope == expectedScope else {
            throw CancellationError()
        }
        return try await runAndWait(for: expectedScope) {
            try await self.coordinator.select(expectedScope)
        }
    }

    func refresh(
        organizationID: OrganizationID,
        priority: AccountOrganizationRefreshPriority
    ) async throws -> AccountOrganizationCoordinatorState? {
        try ensureActive()
        let scope = try await currentScope(for: organizationID)
        return try await runAndWait(for: scope) {
            try await self.coordinator.refresh(scope, priority: priority)
        }
    }

    /// See `select(_:)`: scope authority is an input fence, not only a result
    /// filter. This check precedes every dispatch to the coordinator.
    func refresh(
        _ expectedScope: SynchronizationScope,
        priority: AccountOrganizationRefreshPriority
    ) async throws -> AccountOrganizationCoordinatorState? {
        try ensureActive()
        guard expectedScope.accountID == accountID else {
            throw CancellationError()
        }
        let currentScope = try await currentScope(for: expectedScope.organizationID)
        guard currentScope == expectedScope else {
            throw CancellationError()
        }
        return try await runAndWait(for: expectedScope) {
            try await self.coordinator.refresh(expectedScope, priority: priority)
        }
    }

    func state(
        organizationID: OrganizationID
    ) async throws -> AccountOrganizationCoordinatorState? {
        try ensureActive()
        let scope = try await currentScope(for: organizationID)
        return await coordinator.state(for: scope)
    }

    /// Enters the coordinator's durable lifecycle scheduling path for every
    /// current organization scope owned by this account. This deliberately
    /// does not wait for a refresh to finish: the coordinator owns its
    /// single-flight tasks and decides whether incremental or daily full
    /// reconciliation work is due.
    func applicationDidBecomeActive(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async throws {
        try ensureActive()
        var currentScopesByOrganization: [OrganizationID: SynchronizationScope] = [:]
        for requestedScope in synchronizationScopes where requestedScope.accountID == accountID {
            let currentScope = try await currentScope(for: requestedScope.organizationID)
            guard currentScope == requestedScope else {
                throw CancellationError()
            }
            currentScopesByOrganization[currentScope.organizationID] = currentScope
        }
        try ensureActive()
        try await coordinator.applicationDidBecomeActive(
            synchronizationScopes: currentScopesByOrganization.values.sorted {
                $0.organizationID.rawValue < $1.organizationID.rawValue
            },
            activeAccountID: activeAccountID
        )
    }

    /// Wakes force an overlapping incremental pass at foreground priority,
    /// while retaining the same vault-backed authority revalidation used by
    /// ordinary lifecycle scheduling.
    func wake(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async throws {
        try ensureActive()
        var currentScopesByOrganization: [OrganizationID: SynchronizationScope] = [:]
        for requestedScope in synchronizationScopes where requestedScope.accountID == accountID {
            let currentScope = try await currentScope(for: requestedScope.organizationID)
            guard currentScope == requestedScope else {
                throw CancellationError()
            }
            currentScopesByOrganization[currentScope.organizationID] = currentScope
        }
        try ensureActive()
        try await coordinator.applicationDidWake(
            synchronizationScopes: currentScopesByOrganization.values.sorted {
                $0.organizationID.rawValue < $1.organizationID.rawValue
            },
            activeAccountID: activeAccountID
        )
    }

    func cancel(organizationID: OrganizationID) async throws {
        if let teardownTask {
            return try await teardownTask.value
        }
        let scope: SynchronizationScope
        if let knownScope = knownScopes[organizationID] {
            scope = knownScope
        } else {
            scope = try await currentScope(for: organizationID)
        }
        try await coordinator.cancelRefresh(
            for: AccountOrganizationScope(
                accountID: scope.accountID,
                organizationID: scope.organizationID
            )
        )
    }

    /// Cancels and durably finalizes every scope this account runtime has
    /// activated. All cancellations are attempted before the first error is
    /// returned so account teardown cannot leave sibling work running. The
    /// terminal gate is set before the first suspension, so no new scope can
    /// enter while a vault is being closed or removed.
    func cancelAll() async throws {
        if let teardownTask {
            return try await teardownTask.value
        }
        lifecycle = .tearingDown
        let scopes = knownScopes.values.sorted {
            $0.organizationID.rawValue < $1.organizationID.rawValue
        }
        let coordinator = self.coordinator
        let task = Task {
            var firstError: Error?
            for scope in scopes {
                do {
                    try await coordinator.cancelRefresh(
                        for: AccountOrganizationScope(
                            accountID: scope.accountID,
                            organizationID: scope.organizationID
                        )
                    )
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
            if let firstError {
                throw firstError
            }
        }
        teardownTask = task
        do {
            try await task.value
            lifecycle = .tornDown
        } catch {
            lifecycle = .tornDown
            throw error
        }
    }

    private func currentScope(
        for organizationID: OrganizationID
    ) async throws -> SynchronizationScope {
        try ensureActive()
        let scope = try await resolveScope(accountID, organizationID)
        try ensureActive()
        knownScopes[organizationID] = scope
        return scope
    }

    private func runAndWait(
        for scope: SynchronizationScope,
        start: @escaping @Sendable () async throws -> Void
    ) async throws -> AccountOrganizationCoordinatorState? {
        try ensureActive()
        let accountOrganizationScope = AccountOrganizationScope(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
        do {
            try await start()
            return try await coordinator.waitForRefreshCompletion(for: scope)
        } catch is CancellationError {
            try await coordinator.cancelRefresh(for: accountOrganizationScope)
            throw CancellationError()
        }
    }

    private func ensureActive() throws {
        guard lifecycle == .active else {
            throw AccountOrganizationRefreshRuntimeError.tearingDown
        }
    }
}
