import Foundation

enum AccountConnectionError: Error, Equatable, Sendable {
    case invalidGitHubIdentity
    case missingOAuthBroker
    case missingFineGrainedResourceOwnerOrganization

    var recoveryDescription: String {
        switch self {
        case .invalidGitHubIdentity:
            "Try connecting again."
        case .missingOAuthBroker:
            "Use a build configured with the GitHub sign-in service, or connect with a personal access token."
        case .missingFineGrainedResourceOwnerOrganization:
            "Enter the resource-owner organization selected when you created this fine-grained personal access token."
        }
    }
}

struct AccountConnectionResult: Sendable {
    let account: GitHubAccount
    let organizations: [GitHubOrganization]
    let organizationAccesses: [OrganizationID: OrganizationAccess]
    let accountCapabilities: AccountCapabilitySnapshot
}

actor AccountConnectionService {
    private let brokerURL: URL?
    private let applicationVersion: String?
    private let secretStore: any SecretStore
    private let removeAllSecrets: @Sendable (AccountID) async throws -> Void
    private let vaultRegistry: VaultRegistry

    init(
        brokerURL: URL,
        applicationVersion: String,
        secretStore: KeychainSecretStore,
        vaultRegistry: VaultRegistry
    ) {
        self.brokerURL = brokerURL
        self.applicationVersion = applicationVersion
        self.secretStore = secretStore
        removeAllSecrets = { accountID in
            try await secretStore.removeAllSecrets(for: accountID)
        }
        self.vaultRegistry = vaultRegistry
    }

    init(secretStore: KeychainSecretStore, vaultRegistry: VaultRegistry) {
        brokerURL = nil
        applicationVersion = nil
        self.secretStore = secretStore
        removeAllSecrets = { accountID in
            try await secretStore.removeAllSecrets(for: accountID)
        }
        self.vaultRegistry = vaultRegistry
    }

    /// Keeps the service boundary independently testable without giving tests a
    /// real Keychain. Production construction continues to use the concrete
    /// Keychain-backed initializers above.
    init(
        secretStore: any SecretStore,
        vaultRegistry: VaultRegistry,
        removeAllSecrets: @escaping @Sendable (AccountID) async throws -> Void
    ) {
        brokerURL = nil
        applicationVersion = nil
        self.secretStore = secretStore
        self.removeAllSecrets = removeAllSecrets
        self.vaultRegistry = vaultRegistry
    }

    func connectOAuth(
        exchangeRequest: AuthBrokerExchangeRequest
    ) async throws -> AccountConnectionResult {
        guard let brokerURL, let applicationVersion else {
            throw AccountConnectionError.missingOAuthBroker
        }
        let broker = try AuthBrokerClient(
            baseURL: brokerURL,
            applicationVersion: applicationVersion
        )
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
        let owner = try Self.resourceOwnerOrganization(
            for: personalAccessToken,
            suppliedValue: resourceOwnerOrganization
        )
        return try await establishAccount(
            accessToken: personalAccessToken.value,
            refreshToken: nil,
            authenticationKind: personalAccessToken.kind.authenticationKind,
            accessTokenLifetime: nil,
            refreshTokenLifetime: nil,
            resourceOwnerOrganization: personalAccessToken.kind == .fineGrained ? owner : nil
        )
    }

    /// Fine-grained tokens cannot safely infer their accessible organization
    /// from `/user/orgs`: GitHub may return an empty inventory for a valid
    /// token. Require the explicitly selected resource owner before constructing
    /// a transport, generating a vault key, or writing any credential.
    static func resourceOwnerOrganization(
        for personalAccessToken: PersonalAccessToken,
        suppliedValue: String?
    ) throws -> String? {
        guard personalAccessToken.kind == .fineGrained else { return nil }
        guard let suppliedValue else {
            throw AccountConnectionError.missingFineGrainedResourceOwnerOrganization
        }
        let normalized = suppliedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AccountConnectionError.missingFineGrainedResourceOwnerOrganization
        }
        return normalized
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
            let organizationDiscoverySSOHeader: GitHubSSOHeader?
            if let resourceOwnerOrganization {
                let response = try await identity.organization(named: resourceOwnerOrganization)
                organizationDTOs = [response.value]
                organizationDiscoverySSOHeader = response.ssoHeader
            } else {
                let organizationInventory = try await identity.allOrganizations()
                organizationDTOs = organizationInventory.organizations
                // A required header on /user/orgs has no immutable organization ID. Only
                // partial-results can safely be associated with its affected organizations.
                organizationDiscoverySSOHeader = organizationInventory.partialResultsSSOHeader
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
            var organizationAccesses: [OrganizationID: OrganizationAccess] = [:]
            for organization in organizations {
                let organizationSSOHeader = scopedSSOHeader(
                    for: organization,
                    aggregateHeader: organizationDiscoverySSOHeader
                )
                let access = OrganizationAccess(
                    accountID: account.id,
                    organizationID: organization.id,
                    state: OrganizationAccessEvaluator.state(
                        statusCode: 200,
                        ssoHeader: organizationSSOHeader
                    ),
                    capabilityRevision: CapabilityRevision(rawValue: UUID().uuidString.lowercased())!,
                    capabilities: GitHubCapability.allCases
                        .filter { $0.scope == .organization }
                        .map {
                        CapabilityAvailability(capability: $0, status: .unknown, checkedAt: now)
                        },
                    checkedAt: now
                )
                try await repository.save(
                    organization,
                    access: access
                )
                organizationAccesses[organization.id] = access
            }
            return AccountConnectionResult(
                account: account,
                organizations: organizations,
                organizationAccesses: organizationAccesses,
                accountCapabilities: AccountCapabilitySnapshot(accountID: account.id, capabilities: [], checkedAt: now)
            )
        } catch {
            try await removeAllSecrets(accountID)
            try await vaultRegistry.remove(accountID: accountID)
            throw error
        }
    }

    private func scopedSSOHeader(
        for organization: GitHubOrganization,
        aggregateHeader: GitHubSSOHeader?
    ) -> GitHubSSOHeader? {
        aggregateHeader?.scoped(to: organization.githubOrganizationID)
    }
}
