import Foundation

enum OAuthCredentialRefreshError: Error, Equatable, Sendable {
    case refreshTokenUnavailable
    case refreshTokenEncodingInvalid
    case vaultKeyUnavailable
    case credentialRollbackFailed
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
        // A provider-issued refresh-token rotation cannot be rolled back after this point.
        var accessTokenWasWritten = false
        do {
            if let replacementRefreshToken = response.refreshToken {
                try await secretStore.write(
                    Data(replacementRefreshToken.value.rawValue.utf8),
                    kind: .oauthRefreshToken,
                    accountID: account.id,
                    credentialID: account.credentialID
                )
            }
            try await secretStore.write(
                Data(response.accessToken.value.rawValue.utf8),
                kind: .oauthAccessToken,
                accountID: account.id,
                credentialID: account.credentialID
            )
            accessTokenWasWritten = true
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
            try await AccountRepository(vault: vault).save(
                refreshed,
                credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!
            )
            return refreshed
        } catch {
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
