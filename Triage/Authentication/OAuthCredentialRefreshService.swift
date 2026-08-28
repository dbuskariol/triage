import Foundation

enum OAuthCredentialRefreshError: Error, Equatable, Sendable {
    case refreshTokenUnavailable
    case refreshTokenEncodingInvalid
}

actor OAuthCredentialRefreshService {
    private let brokerURL: URL
    private let secretStore: KeychainSecretStore
    private let vaultRegistry: VaultRegistry
    private let clock: @Sendable () -> Date

    init(
        brokerURL: URL,
        secretStore: KeychainSecretStore,
        vaultRegistry: VaultRegistry,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.brokerURL = brokerURL
        self.secretStore = secretStore
        self.vaultRegistry = vaultRegistry
        self.clock = clock
    }

    func refreshIfNeeded(_ account: GitHubAccount) async throws -> GitHubAccount {
        guard account.authenticationKind == .oauth else { return account }
        let now = clock()
        guard CredentialLifecycle.status(for: account, at: now) == .expiring else {
            return account
        }
        guard let data = try await secretStore.read(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: account.credentialID
        ), let refreshToken = String(data: data, encoding: .utf8), !refreshToken.isEmpty else {
            throw OAuthCredentialRefreshError.refreshTokenUnavailable
        }
        let response = try await AuthBrokerClient(baseURL: brokerURL).refresh(
            AuthBrokerRefreshRequest(refreshToken: OAuthRefreshToken(refreshToken))
        )
        try await secretStore.write(
            Data(response.accessToken.value.rawValue.utf8),
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        if let replacementRefreshToken = response.refreshToken {
            try await secretStore.write(
                Data(replacementRefreshToken.value.rawValue.utf8),
                kind: .oauthRefreshToken,
                accountID: account.id,
                credentialID: account.credentialID
            )
        }
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
        guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
            throw OAuthCredentialRefreshError.refreshTokenUnavailable
        }
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        try await AccountRepository(vault: vault).save(
            refreshed,
            credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!
        )
        return refreshed
    }
}
