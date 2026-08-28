import Foundation

enum AccountConnectionError: Error, Equatable, Sendable {
    case invalidGitHubIdentity
    case missingOAuthBroker
}

struct AccountConnectionResult: Sendable {
    let account: GitHubAccount
    let organizations: [GitHubOrganization]
}

actor AccountConnectionService {
    private let brokerURL: URL?
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

    init(secretStore: KeychainSecretStore, vaultRegistry: VaultRegistry) {
        brokerURL = nil
        self.secretStore = secretStore
        self.vaultRegistry = vaultRegistry
    }

    func connectOAuth(
        exchangeRequest: AuthBrokerExchangeRequest
    ) async throws -> AccountConnectionResult {
        guard let brokerURL else {
            throw AccountConnectionError.missingOAuthBroker
        }
        let broker = try AuthBrokerClient(baseURL: brokerURL)
        let tokenResponse = try await broker.exchange(exchangeRequest)
        return try await establishAccount(
            accessToken: tokenResponse.accessToken.value,
            refreshToken: tokenResponse.refreshToken?.value,
            authenticationKind: .oauth,
            accessTokenLifetime: tokenResponse.expiresIn,
            refreshTokenLifetime: tokenResponse.refreshTokenExpiresIn
        )
    }

    func connect(
        personalAccessToken: PersonalAccessToken,
        resourceOwnerOrganization: String? = nil
    ) async throws -> AccountConnectionResult {
        let owner = resourceOwnerOrganization?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try await establishAccount(
            accessToken: personalAccessToken.value,
            refreshToken: nil,
            authenticationKind: personalAccessToken.kind.authenticationKind,
            accessTokenLifetime: nil,
            refreshTokenLifetime: nil,
            resourceOwnerOrganization: personalAccessToken.kind == .fineGrained ? owner : nil
        )
    }

    private func establishAccount(
        accessToken: SecretValue,
        refreshToken: SecretValue?,
        authenticationKind: AuthenticationKind,
        accessTokenLifetime: TimeInterval?,
        refreshTokenLifetime: TimeInterval?,
        resourceOwnerOrganization: String? = nil
    ) async throws -> AccountConnectionResult {
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
            credentialStatus: CredentialLifecycle.status(
                authenticationKind: authenticationKind,
                accessTokenExpiresAt: accessTokenLifetime.map { now.addingTimeInterval($0) },
                refreshTokenExpiresAt: refreshTokenLifetime.map { now.addingTimeInterval($0) },
                at: now
            ),
            accessTokenExpiresAt: accessTokenLifetime.map { now.addingTimeInterval($0) },
            refreshTokenExpiresAt: refreshTokenLifetime.map { now.addingTimeInterval($0) },
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
            let repository = AccountRepository(vault: vault)
            try await repository.save(
                account,
                credentialRevision: CredentialRevision(rawValue: UUID().uuidString.lowercased())!
            )

            let identity = GitHubIdentityClient(client: client)
            let organizationDTOs: [GitHubOrganizationDTO]
            let ssoHeader: GitHubSSOHeader?
            if let resourceOwnerOrganization {
                let response = try await identity.organization(named: resourceOwnerOrganization)
                organizationDTOs = [response.value]
                ssoHeader = response.ssoHeader
            } else {
                let organizationInventory = try await identity.allOrganizations()
                organizationDTOs = organizationInventory.organizations
                ssoHeader = organizationInventory.ssoHeader
            }

            let organizations = try organizationDTOs.map { dto in
                guard let organizationNodeID = GitHubNodeID(rawValue: dto.nodeID),
                      let organizationID = OrganizationID(rawValue: dto.nodeID)
                else {
                    throw AccountConnectionError.invalidGitHubIdentity
                }
                return GitHubOrganization(
                    id: organizationID,
                    githubOrganizationID: dto.id,
                    nodeID: organizationNodeID,
                    login: dto.login,
                    avatarURL: dto.avatarURL
                )
            }
            for organization in organizations {
                let organizationSSOHeader = scopedSSOHeader(
                    for: organization,
                    aggregateHeader: ssoHeader
                )
                try await repository.save(
                    organization,
                    access: OrganizationAccess(
                        accountID: account.id,
                        organizationID: organization.id,
                        state: OrganizationAccessEvaluator.state(
                            statusCode: 200,
                            ssoHeader: organizationSSOHeader
                        ),
                        capabilityRevision: CapabilityRevision(rawValue: UUID().uuidString.lowercased())!,
                        capabilities: GitHubCapability.allCases.map {
                            CapabilityAvailability(capability: $0, status: .unknown, checkedAt: now)
                        },
                        checkedAt: now
                    )
                )
            }
            return AccountConnectionResult(account: account, organizations: organizations)
        } catch {
            try await secretStore.removeAllSecrets(for: accountID)
            try await vaultRegistry.remove(accountID: accountID)
            throw error
        }
    }

    private func scopedSSOHeader(
        for organization: GitHubOrganization,
        aggregateHeader: GitHubSSOHeader?
    ) -> GitHubSSOHeader? {
        guard case let .partialResults(organizationIDs)? = aggregateHeader else {
            return aggregateHeader
        }
        guard organizationIDs.contains(organization.githubOrganizationID) else {
            return nil
        }
        return .partialResults([organization.githubOrganizationID])
    }
}
