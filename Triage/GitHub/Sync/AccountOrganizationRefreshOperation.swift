import Foundation

enum AccountOrganizationRefreshOperationError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case missingPersistedAccount
    case missingPersistedOrganization
}

/// Adapts the complete read-only organization synchronization pipeline to the
/// revision-qualified coordinator contract.
///
/// The operation resolves account and organization identities from the
/// encrypted vault for every request. It validates the requested authority
/// before any network work and atomically revalidates authority while reading
/// the exact coverage projection after the pipeline completes. A revision
/// change is cancellation, never a terminal result for the obsolete scope.
struct AccountOrganizationRefreshOperation: AccountOrganizationRefreshOperating {
    typealias RefreshPipeline = @Sendable (
        GitHubAccount,
        GitHubOrganization,
        SynchronizationScope,
        GitHubRequestPriority,
        SynchronizationReconciliationIntent
    ) async throws -> Void
    /// Creates the per-request work-refresh pipeline. Production uses the
    /// default factory below; deterministic acceptance tests may substitute a
    /// bounded local source without changing the source pipeline itself.
    typealias RefreshPipelineFactory = @Sendable (GitHubRequestPriority) -> RefreshPipeline

    private let vault: AccountVault
    private let refreshPipelineFactory: RefreshPipelineFactory

    init(
        vault: AccountVault,
        credentialReader: AccountCredentialReader,
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        rateLimitControllers: GitHubRateLimitControllerRegistry = .shared,
        organizationAIController: OrganizationAIController? = nil,
        businessDayPolicyProvider: @escaping @Sendable () -> BusinessDayPolicy = { .init() }
    ) {
        self.init(
            vault: vault,
            refreshPipelineFactory: { requestPriority in
                { account, organization, synchronizationScope, _, reconciliationIntent in
                    _ = try await OrganizationWorkRefreshService(
                        credentialReader: credentialReader,
                        vaultRegistry: vaultRegistry,
                        secretStore: secretStore,
                        rateLimitControllers: rateLimitControllers,
                        requestPriority: requestPriority,
                        organizationAIController: organizationAIController,
                        businessDayPolicyProvider: businessDayPolicyProvider
                    ).refresh(
                        account: account,
                        organization: organization,
                        synchronizationScope: synchronizationScope,
                        reconciliationIntent: reconciliationIntent
                    )
                }
            }
        )
    }

    init(
        vault: AccountVault,
        refreshPipeline: @escaping RefreshPipeline
    ) {
        self.init(vault: vault, refreshPipelineFactory: { _ in refreshPipeline })
    }

    init(
        vault: AccountVault,
        refreshPipelineFactory: @escaping RefreshPipelineFactory
    ) {
        self.vault = vault
        self.refreshPipelineFactory = refreshPipelineFactory
    }

    func refresh(
        _ request: AccountOrganizationRefreshRequest
    ) async throws -> AccountOrganizationCachedState {
        guard request.scope.accountID == request.synchronizationScope.accountID,
              request.scope.organizationID == request.synchronizationScope.organizationID,
              request.synchronizationScope.accountID == vault.accountID
        else {
            throw AccountOrganizationRefreshOperationError.accountScopeMismatch
        }

        let (account, organization) = try await persistedContext(
            for: request.synchronizationScope
        )
        try Task.checkCancellation()
        let refreshPipeline = refreshPipelineFactory(request.requestPriority)
        try await refreshPipeline(
            account,
            organization,
            request.synchronizationScope,
            request.requestPriority,
            request.reconciliationIntent
        )
        try Task.checkCancellation()
        return try await currentCachedState(for: request.synchronizationScope)
    }

    private func persistedContext(
        for scope: SynchronizationScope
    ) async throws -> (GitHubAccount, GitHubOrganization) {
        try await validateCurrent(scope)
        let repository = AccountRepository(vault: vault)
        guard let account = try await repository.accounts().first(where: { $0.id == scope.accountID }) else {
            throw AccountOrganizationRefreshOperationError.missingPersistedAccount
        }
        guard let organization = try await repository.organizations(for: scope.accountID)
            .first(where: { $0.id == scope.organizationID })
        else {
            throw AccountOrganizationRefreshOperationError.missingPersistedOrganization
        }
        // Account/organization records and their authority revisions can change
        // between actor calls. Recheck immediately before dispatching network work.
        try await validateCurrent(scope)
        return (account, organization)
    }

    private func validateCurrent(_ scope: SynchronizationScope) async throws {
        do {
            let current = try await AccountRepository(vault: vault).synchronizationScope(
                for: scope.accountID,
                organizationID: scope.organizationID
            )
            guard current == scope else {
                throw CancellationError()
            }
        } catch AccountRepositoryError.synchronizationScopeUnavailable {
            throw AccountOrganizationRefreshOperationError.organizationScopeMismatch
        }
    }

    private func currentCachedState(
        for scope: SynchronizationScope
    ) async throws -> AccountOrganizationCachedState {
        do {
            return try await vault.read { database in
                try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
                let coverage = try CoverageRepository.currentRecords(for: scope, in: database)
                return AccountOrganizationCachedState(
                    coverage: coverage,
                    lastSuccessfulSyncAt: coverage.compactMap(\.lastSuccessfulAt).max()
                )
            }
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope {
            throw CancellationError()
        } catch OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw AccountOrganizationRefreshOperationError.organizationScopeMismatch
        }
    }
}
