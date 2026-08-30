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
        GitHubRequestPriority
    ) async throws -> Void

    private let vault: AccountVault
    private let refreshPipeline: RefreshPipeline

    init(
        vault: AccountVault,
        credentialReader: AccountCredentialReader,
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        rateLimitControllers: GitHubRateLimitControllerRegistry = .shared
    ) {
        self.vault = vault
        refreshPipeline = { account, organization, requestPriority in
            _ = try await OrganizationWorkRefreshService(
                credentialReader: credentialReader,
                vaultRegistry: vaultRegistry,
                secretStore: secretStore,
                rateLimitControllers: rateLimitControllers,
                requestPriority: requestPriority
            ).refresh(account: account, organization: organization)
        }
    }

    init(
        vault: AccountVault,
        refreshPipeline: @escaping RefreshPipeline
    ) {
        self.vault = vault
        self.refreshPipeline = refreshPipeline
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
        try await refreshPipeline(account, organization, request.requestPriority)
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
