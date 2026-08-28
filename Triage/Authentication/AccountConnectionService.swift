import Foundation

enum AccountConnectionError: Error, Equatable, Sendable {
    case invalidGitHubIdentity
}

actor AccountConnectionService {
    private let brokerURL: URL
    private let secretStore: KeychainSecretStore
    private let vaultRegistry: VaultRegistry

    init(
        brokerURL: URL,
        secretStore: KeychainSecretStore,
        vaultRegistry: VaultRegistry
    ) {
        self.brokerURL = brokerURL
        self.secretStore = secretStore
        self.vaultRegistry = vaultRegistry
    }

    func connectOAuth(
        exchangeRequest: AuthBrokerExchangeRequest
    ) async throws -> GitHubAccount {
        let broker = try AuthBrokerClient(baseURL: brokerURL)
        let tokenResponse = try await broker.exchange(exchangeRequest)
        return try await establishAccount(
            accessToken: tokenResponse.accessToken.value,
            refreshToken: tokenResponse.refreshToken?.value,
            authenticationKind: .oauth
        )
    }

    func connect(personalAccessToken: PersonalAccessToken) async throws -> GitHubAccount {
        try await establishAccount(
            accessToken: personalAccessToken.value,
            refreshToken: nil,
            authenticationKind: personalAccessToken.kind.authenticationKind
        )
    }

    private func establishAccount(
        accessToken: SecretValue,
        refreshToken: SecretValue?,
        authenticationKind: AuthenticationKind
    ) async throws -> GitHubAccount {
        let transport = try GitHubRESTTransport()
        let client = GitHubRESTClient(transport: transport, credential: accessToken)
        let user = try await GitHubIdentityClient(client: client).authenticatedUser().value
        guard let nodeID = GitHubNodeID(rawValue: user.nodeID) else {
            throw AccountConnectionError.invalidGitHubIdentity
        }

        let accountID = AccountID.make()
        let credentialID = CredentialID.make()
        let now = Date()
        let account = GitHubAccount(
            id: accountID,
            githubUserID: user.id,
            nodeID: nodeID,
            login: user.login,
            displayName: user.name,
            avatarURL: user.avatarURL,
            authenticationKind: authenticationKind,
            credentialID: credentialID,
            credentialStatus: .active,
            createdAt: now,
            lastValidatedAt: now
        )
        let vaultKey = try VaultKey.generate()
        let vault = try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)

        do {
            try await secretStore.write(
                vaultKey.data,
                kind: .vaultKey,
                accountID: accountID,
                credentialID: nil
            )
            try await secretStore.write(
                Data(accessToken.rawValue.utf8),
                kind: authenticationKind == .oauth ? .oauthAccessToken : .personalAccessToken,
                accountID: accountID,
                credentialID: credentialID
            )
            if let refreshToken {
                try await secretStore.write(
                    Data(refreshToken.rawValue.utf8),
                    kind: .oauthRefreshToken,
                    accountID: accountID,
                    credentialID: credentialID
                )
            }
            try await AccountRepository(vault: vault).save(
                account,
                credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!
            )
        } catch {
            try await secretStore.removeAllSecrets(for: accountID)
            try await vaultRegistry.remove(accountID: accountID)
            throw error
        }
        return account
    }
}
