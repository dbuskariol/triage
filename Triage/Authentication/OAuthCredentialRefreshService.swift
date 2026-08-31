import Foundation

enum OAuthCredentialRefreshError: Error, Equatable, Sendable {
    case refreshTokenUnavailable
    case refreshTokenEncodingInvalid
    case vaultKeyUnavailable
    case credentialRollbackFailed
    case staleAccountAuthority
}

/// Serializes the short local mutation phase across independently constructed
/// refresh services. Network refreshes remain concurrent; only the writes
/// sharing one Keychain credential identity and their revision-checked vault
/// commit are fenced together.
private actor OAuthCredentialRefreshMutationCoordinator {
    struct Key: Hashable, Sendable {
        let accountID: AccountID
        let credentialID: CredentialID
    }

    static let shared = OAuthCredentialRefreshMutationCoordinator()

    private var locked = Set<Key>()
    private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: Key) async {
        guard !locked.contains(key) else {
            await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
            return
        }
        locked.insert(key)
    }

    func release(_ key: Key) {
        if var queued = waiters[key], !queued.isEmpty {
            let continuation = queued.removeFirst()
            waiters[key] = queued.isEmpty ? nil : queued
            continuation.resume()
            return
        }
        locked.remove(key)
    }
}

actor OAuthCredentialRefreshService {
    private let brokerURL: URL
    private let secretStore: any SecretStore
    private let vaultRegistry: VaultRegistry
    private let clock: @Sendable () -> Date
    private let broker: (any OAuthTokenRefreshing)?

    init(
        brokerURL: URL,
        secretStore: any SecretStore,
        vaultRegistry: VaultRegistry,
        clock: @escaping @Sendable () -> Date = Date.init,
        broker: (any OAuthTokenRefreshing)? = nil
    ) throws {
        try AuthBrokerClient.validate(baseURL: brokerURL)
        self.brokerURL = brokerURL
        self.secretStore = secretStore
        self.vaultRegistry = vaultRegistry
        self.clock = clock
        self.broker = broker
    }

    func refreshIfNeeded(_ account: GitHubAccount) async throws -> GitHubAccount {
        guard account.authenticationKind == .oauth else { return account }
        let now = clock()
        guard CredentialLifecycle.status(for: account, at: now) == .expiring else {
            return account
        }
        try Task.checkCancellation()
        guard let data = try await secretStore.read(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: account.credentialID
        ) else {
            throw OAuthCredentialRefreshError.refreshTokenUnavailable
        }
        guard let refreshToken = String(data: data, encoding: .utf8) else {
            throw OAuthCredentialRefreshError.refreshTokenEncodingInvalid
        }
        guard !refreshToken.isEmpty else {
            throw OAuthCredentialRefreshError.refreshTokenUnavailable
        }
        let previousAccessToken = try await secretStore.read(
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        guard let vaultKeyData = try await secretStore.read(
            kind: .vaultKey,
            accountID: account.id,
            credentialID: nil
        ) else {
            throw OAuthCredentialRefreshError.vaultKeyUnavailable
        }
        let vaultKey = try VaultKey(data: vaultKeyData)
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        let accountRepository = AccountRepository(vault: vault)
        let expectedCredentialRevision = try await validateCurrentAuthority(
            for: account,
            repository: accountRepository
        )
        let refreshClient: any OAuthTokenRefreshing
        if let broker {
            refreshClient = broker
        } else {
            refreshClient = try AuthBrokerClient(baseURL: brokerURL)
        }
        let response = try await refreshClient.refresh(
            AuthBrokerRefreshRequest(refreshToken: OAuthRefreshToken(refreshToken))
        )
        try Task.checkCancellation()
        let mutationKey = OAuthCredentialRefreshMutationCoordinator.Key(
            accountID: account.id,
            credentialID: account.credentialID
        )
        await OAuthCredentialRefreshMutationCoordinator.shared.acquire(mutationKey)
        // A provider-issued refresh-token rotation cannot be rolled back after this point.
        do {
            // `acquire` can resume a task that was cancelled while queued.
            // Release the handoff without touching either credential store.
            try Task.checkCancellation()
            let refreshed = try await commit(
                response: response,
                account: account,
                now: now,
                previousAccessToken: previousAccessToken,
                expectedCredentialRevision: expectedCredentialRevision,
                repository: accountRepository
            )
            await OAuthCredentialRefreshMutationCoordinator.shared.release(mutationKey)
            return refreshed
        } catch {
            await OAuthCredentialRefreshMutationCoordinator.shared.release(mutationKey)
            throw error
        }
    }

    private func commit(
        response: AuthBrokerTokenResponse,
        account: GitHubAccount,
        now: Date,
        previousAccessToken: Data?,
        expectedCredentialRevision: CredentialRevision,
        repository: AccountRepository
    ) async throws -> GitHubAccount {
        try Task.checkCancellation()
        guard try await validateCurrentAuthority(for: account, repository: repository)
            == expectedCredentialRevision
        else {
            throw OAuthCredentialRefreshError.staleAccountAuthority
        }

        var accessTokenWasWritten = false
        var refreshTokenWasWritten = false
        do {
            if let replacementRefreshToken = response.refreshToken {
                try await secretStore.write(
                    Data(replacementRefreshToken.value.rawValue.utf8),
                    kind: .oauthRefreshToken,
                    accountID: account.id,
                    credentialID: account.credentialID
                )
                refreshTokenWasWritten = true
                try Task.checkCancellation()
            }
            try await secretStore.write(
                Data(response.accessToken.value.rawValue.utf8),
                kind: .oauthAccessToken,
                accountID: account.id,
                credentialID: account.credentialID
            )
            accessTokenWasWritten = true
            try Task.checkCancellation()
            let accessTokenExpiresAt = response.expiresIn.map { now.addingTimeInterval($0) }
            let refreshTokenExpiresAt = response.refreshTokenExpiresIn.map { now.addingTimeInterval($0) }
                ?? account.refreshTokenExpiresAt
            let refreshed = account.replacingCredentialExpiration(
                accessTokenExpiresAt: accessTokenExpiresAt,
                refreshTokenExpiresAt: refreshTokenExpiresAt,
                status: CredentialLifecycle.status(
                    authenticationKind: account.authenticationKind,
                    accessTokenExpiresAt: accessTokenExpiresAt,
                    refreshTokenExpiresAt: refreshTokenExpiresAt,
                    at: now
                ),
                validatedAt: now
            )
            try await repository.save(
                refreshed,
                credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!,
                expectedCredentialRevision: expectedCredentialRevision
            )
            return refreshed
        } catch AccountRepositoryError.staleCredentialRevision {
            // The account was replaced or removed while the broker request was
            // in flight. Never restore or recreate old secrets after that
            // boundary; remove any staged old-credential values instead.
            await discardStagedTokens(
                accessTokenWasWritten: accessTokenWasWritten,
                refreshTokenWasWritten: refreshTokenWasWritten,
                for: account
            )
            throw OAuthCredentialRefreshError.staleAccountAuthority
        } catch {
            guard let currentRevision = try? await validateCurrentAuthority(
                for: account,
                repository: repository
            ), currentRevision == expectedCredentialRevision
            else {
                // A removal/replacement may race a local secret-store error.
                // Rollback is unsafe until current authority is proven.
                await discardStagedTokens(
                    accessTokenWasWritten: accessTokenWasWritten,
                    refreshTokenWasWritten: refreshTokenWasWritten,
                    for: account
                )
                throw OAuthCredentialRefreshError.staleAccountAuthority
            }
            do {
                // Do not restore a rotated refresh token: providers may revoke its predecessor.
                if accessTokenWasWritten {
                    try await restore(
                        previousAccessToken,
                        kind: .oauthAccessToken,
                        for: account
                    )
                }
            } catch {
                throw OAuthCredentialRefreshError.credentialRollbackFailed
            }
            throw error
        }
    }

    private func validateCurrentAuthority(
        for account: GitHubAccount,
        repository: AccountRepository
    ) async throws -> CredentialRevision {
        guard let persisted = try await repository.accounts().first(where: { $0.id == account.id }),
              persisted.credentialID == account.credentialID,
              persisted.authenticationKind == account.authenticationKind
        else {
            throw OAuthCredentialRefreshError.staleAccountAuthority
        }
        return try await repository.credentialRevision(for: account.id)
    }

    private func discardStagedTokens(
        accessTokenWasWritten: Bool,
        refreshTokenWasWritten: Bool,
        for account: GitHubAccount
    ) async {
        if accessTokenWasWritten {
            try? await secretStore.remove(
                kind: .oauthAccessToken,
                accountID: account.id,
                credentialID: account.credentialID
            )
        }
        if refreshTokenWasWritten {
            try? await secretStore.remove(
                kind: .oauthRefreshToken,
                accountID: account.id,
                credentialID: account.credentialID
            )
        }
    }

    private func restore(
        _ value: Data?,
        kind: TriageSecretKind,
        for account: GitHubAccount
    ) async throws {
        if let value {
            try await secretStore.write(
                value,
                kind: kind,
                accountID: account.id,
                credentialID: account.credentialID
            )
        } else {
            try await secretStore.remove(
                kind: kind,
                accountID: account.id,
                credentialID: account.credentialID
            )
        }
    }
}
