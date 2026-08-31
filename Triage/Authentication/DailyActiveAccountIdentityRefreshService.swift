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
    typealias OrganizationInventoryValidationLoading = @Sendable (
        AccountID,
        CredentialRevision
    ) async throws -> Date?

    private let vault: AccountVault
    private let loadAuthenticatedUser: AuthenticatedUserLoading
    private let loadOrganizationInventory: OrganizationInventoryLoading
    private let loadOrganizationInventoryValidatedAt: OrganizationInventoryValidationLoading
    private let cadence: RefreshCadence
    private let clock: @Sendable () -> Date
    private let newCredentialRevision: @Sendable () -> CredentialRevision

    init(
        vault: AccountVault,
        loadAuthenticatedUser: @escaping AuthenticatedUserLoading,
        loadOrganizationInventory: @escaping OrganizationInventoryLoading,
        loadOrganizationInventoryValidatedAt: @escaping OrganizationInventoryValidationLoading = { _, _ in nil },
        cadence: RefreshCadence = .dailyCapabilityProbe,
        clock: @escaping @Sendable () -> Date = Date.init,
        newCredentialRevision: @escaping @Sendable () -> CredentialRevision = {
            CredentialRevision(rawValue: UUID().uuidString.lowercased())!
        }
    ) {
        self.vault = vault
        self.loadAuthenticatedUser = loadAuthenticatedUser
        self.loadOrganizationInventory = loadOrganizationInventory
        self.loadOrganizationInventoryValidatedAt = loadOrganizationInventoryValidatedAt
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
        let credentialRevision = try await repository.credentialRevision(for: persistedAccount.id)
        let now = clock()
        let lastInventoryValidatedAt: Date?
        do {
            lastInventoryValidatedAt = try await loadOrganizationInventoryValidatedAt(
                persistedAccount.id,
                credentialRevision
            )
        } catch DailyActiveAccountIdentityRefreshError.staleAccountAuthority {
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        } catch AccountRepositoryError.staleCredentialRevision {
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        } catch PostAccountIdentityReplayReceiptRepositoryError.staleAuthority {
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        } catch {
            // If receipt freshness cannot be read, do not allow a recent
            // identity-only success to suppress visibility recovery.
            lastInventoryValidatedAt = nil
        }
        guard isDue(
            account: persistedAccount,
            lastInventoryValidatedAt: lastInventoryValidatedAt,
            at: now
        ) else {
            return .notDue
        }
        let user: GitHubUserDTO
        do {
            user = try await loadAuthenticatedUser()
        } catch AuthenticatedUserReplayReceiptRepositoryError.immutableIdentityMismatch {
            return try await revoke(
                persistedAccount,
                credentialRevision: credentialRevision,
                repository: repository
            )
        } catch AuthenticatedUserReplayReceiptRepositoryError.staleAuthority {
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        }
        try Task.checkCancellation()
        guard user.id == persistedAccount.githubUserID,
              user.nodeID == persistedAccount.nodeID.rawValue
        else {
            return try await revoke(
                persistedAccount,
                credentialRevision: credentialRevision,
                repository: repository
            )
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
        do {
            try await repository.save(
                refreshed,
                credentialRevision: credentialRevision,
                expectedCredentialRevision: credentialRevision
            )
        } catch AccountRepositoryError.staleCredentialRevision {
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        }

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
        } catch PostAccountIdentityReplayReceiptRepositoryError.staleAuthority {
            // A stale `/user/orgs` receipt is a canceled authority, never an
            // inventory failure that may publish the profile snapshot.
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        } catch {
            // A failed, partial, or receipt-invalid inventory is never removal
            // evidence. Return the current rows so the caller preserves them.
            return .inventoryUnavailable(try await snapshot(account: refreshed, repository: repository))
        }
    }

    private func isDue(
        account: GitHubAccount,
        lastInventoryValidatedAt: Date?,
        at date: Date
    ) -> Bool {
        let identityDue = account.lastValidatedAt.map {
            date.timeIntervalSince($0) >= cadence.baseInterval
        } ?? true
        let inventoryDue = lastInventoryValidatedAt.map {
            date.timeIntervalSince($0) >= cadence.baseInterval
        } ?? true
        return identityDue || inventoryDue
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

    private func revoke(
        _ account: GitHubAccount,
        credentialRevision: CredentialRevision,
        repository: AccountRepository
    ) async throws -> DailyActiveAccountIdentityRefreshOutcome {
        try await requireCurrentCredentialRevision(
            credentialRevision,
            accountID: account.id,
            repository: repository
        )
        let revoked = account.replacingCredentialStatus(.revoked)
        do {
            try await repository.save(
                revoked,
                credentialRevision: newCredentialRevision(),
                expectedCredentialRevision: credentialRevision
            )
        } catch AccountRepositoryError.staleCredentialRevision {
            throw DailyActiveAccountIdentityRefreshError.staleAccountAuthority
        }
        return .credentialRevoked(revoked)
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
