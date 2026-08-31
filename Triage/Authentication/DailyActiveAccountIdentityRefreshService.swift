import Foundation

enum DailyActiveAccountIdentityRefreshError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleAccountAuthority
}

struct DailyActiveAccountIdentityRefreshSnapshot: Sendable {
    let account: GitHubAccount
    let organizations: [GitHubOrganization]
    let organizationAccesses: [OrganizationID: OrganizationAccess]
}

enum DailyActiveAccountIdentityRefreshOutcome: Sendable {
    case notDue
    case refreshed(DailyActiveAccountIdentityRefreshSnapshot)
    /// `/user` was authoritative, but organization visibility could not be
    /// revalidated. The returned snapshot deliberately retains every existing
    /// organization row; callers must not treat it as a complete inventory.
    case inventoryUnavailable(DailyActiveAccountIdentityRefreshSnapshot)
    /// The credential authenticated as a different immutable GitHub identity.
    /// The stored profile is retained and the credential is durably revoked.
    case credentialRevoked(GitHubAccount)
}

/// Revalidates one active account on the existing daily capability cadence.
///
/// This service intentionally does not own first connection: `/user` and
/// `/user/orgs` remain unconditional before an account vault exists. Once a
/// vault does exist, the inventory closure is the exact receipt-backed
/// post-account replay service and receives the persisted credential revision.
actor DailyActiveAccountIdentityRefreshService {
    typealias AuthenticatedUserLoading = @Sendable () async throws -> GitHubUserDTO
    typealias OrganizationInventoryLoading = @Sendable (
        AccountID,
        CredentialRevision
    ) async throws -> GitHubOrganizationInventory

    private let vault: AccountVault
    private let loadAuthenticatedUser: AuthenticatedUserLoading
    private let loadOrganizationInventory: OrganizationInventoryLoading
    private let cadence: RefreshCadence
    private let clock: @Sendable () -> Date
    private let newCredentialRevision: @Sendable () -> CredentialRevision

    init(
        vault: AccountVault,
        loadAuthenticatedUser: @escaping AuthenticatedUserLoading,
        loadOrganizationInventory: @escaping OrganizationInventoryLoading,
        cadence: RefreshCadence = .dailyCapabilityProbe,
        clock: @escaping @Sendable () -> Date = Date.init,
        newCredentialRevision: @escaping @Sendable () -> CredentialRevision = {
            CredentialRevision(rawValue: UUID().uuidString.lowercased())!
        }
    ) {
        self.vault = vault
        self.loadAuthenticatedUser = loadAuthenticatedUser
        self.loadOrganizationInventory = loadOrganizationInventory
        self.cadence = cadence
        self.clock = clock
        self.newCredentialRevision = newCredentialRevision
    }

    func refreshIfDue(for requestedAccount: GitHubAccount) async throws -> DailyActiveAccountIdentityRefreshOutcome {
        guard requestedAccount.id == vault.accountID else {
            throw DailyActiveAccountIdentityRefreshError.accountScopeMismatch
        }
        let repository = AccountRepository(vault: vault)
        guard let persistedAccount = try await repository.accounts().first(where: { $0.id == requestedAccount.id }),
              persistedAccount.credentialID == requestedAccount.credentialID
        else {
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        }
        let now = clock()
        guard isDue(account: persistedAccount, at: now) else {
            return .notDue
        }
        let credentialRevision = try await repository.credentialRevision(for: persistedAccount.id)
        let user = try await loadAuthenticatedUser()
        try Task.checkCancellation()
        guard user.id == persistedAccount.githubUserID,
              user.nodeID == persistedAccount.nodeID.rawValue
        else {
            try await requireCurrentCredentialRevision(
                credentialRevision,
                accountID: persistedAccount.id,
                repository: repository
            )
            let revoked = persistedAccount.replacingCredentialStatus(.revoked)
            try await repository.save(revoked, credentialRevision: newCredentialRevision())
            return .credentialRevoked(revoked)
        }

        let refreshed = GitHubAccount(
            id: persistedAccount.id,
            githubUserID: persistedAccount.githubUserID,
            nodeID: persistedAccount.nodeID,
            login: user.login,
            displayName: user.name,
            avatarURL: user.avatarURL,
            authenticationKind: persistedAccount.authenticationKind,
            credentialID: persistedAccount.credentialID,
            credentialStatus: persistedAccount.credentialStatus,
            accessTokenExpiresAt: persistedAccount.accessTokenExpiresAt,
            refreshTokenExpiresAt: persistedAccount.refreshTokenExpiresAt,
            createdAt: persistedAccount.createdAt,
            lastValidatedAt: now
        )
        try await requireCurrentCredentialRevision(
            credentialRevision,
            accountID: persistedAccount.id,
            repository: repository
        )
        try await repository.save(refreshed, credentialRevision: credentialRevision)

        do {
            let inventory = try await loadOrganizationInventory(
                persistedAccount.id,
                credentialRevision
            )
            try Task.checkCancellation()
            try await requireCurrentCredentialRevision(
                credentialRevision,
                accountID: persistedAccount.id,
                repository: repository
            )
            try await repository.reconcilePostCredentialOrganizationInventory(
                try inventory.organizations.map(Self.organization),
                accountID: persistedAccount.id,
                expectedCredentialRevision: credentialRevision,
                observedAt: now
            )
            return .refreshed(try await snapshot(account: refreshed, repository: repository))
        } catch is CancellationError {
            throw CancellationError()
        } catch DailyActiveAccountIdentityRefreshError.staleAccountAuthority {
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        } catch AccountRepositoryError.staleCredentialRevision {
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        } catch {
            // A failed, partial, or receipt-invalid inventory is never removal
            // evidence. Return the current rows so the caller preserves them.
            return .inventoryUnavailable(try await snapshot(account: refreshed, repository: repository))
        }
    }

    private func isDue(account: GitHubAccount, at date: Date) -> Bool {
        guard let lastValidatedAt = account.lastValidatedAt else { return true }
        return date.timeIntervalSince(lastValidatedAt) >= cadence.baseInterval
    }

    private func requireCurrentCredentialRevision(
        _ expected: CredentialRevision,
        accountID: AccountID,
        repository: AccountRepository
    ) async throws {
        guard try await repository.credentialRevision(for: accountID) == expected else {
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        }
    }

    private func snapshot(
        account: GitHubAccount,
        repository: AccountRepository
    ) async throws -> DailyActiveAccountIdentityRefreshSnapshot {
        DailyActiveAccountIdentityRefreshSnapshot(
            account: account,
            organizations: try await repository.organizations(for: account.id),
            organizationAccesses: try await repository.organizationAccesses(for: account.id)
        )
    }

    private static func organization(_ value: GitHubOrganizationDTO) throws -> GitHubOrganization {
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
