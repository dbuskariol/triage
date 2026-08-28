import Foundation

actor OrganizationInventoryRefreshService {
    private let credentialReader: AccountCredentialReader
    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore

    init(
        credentialReader: AccountCredentialReader,
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore
    ) {
        self.credentialReader = credentialReader
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
    }

    func refreshRepositories(
        account: GitHubAccount,
        organization: GitHubOrganization,
        rateLimitController: GitHubRateLimitController? = nil,
        requestPriority: GitHubRequestPriority = .selectedOrganizationRefresh
    ) async throws -> [RepositorySummary] {
        let token = try await credentialReader.accessToken(for: account)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(),
            credential: token,
            rateLimitController: rateLimitController,
            requestPriority: requestPriority
        )
        let repositories = try await GitHubIdentityClient(client: client)
            .allRepositories(in: organization.login)
        guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        var summaries: [RepositorySummary] = []
        for remoteRepository in repositories {
            summaries.append(
                try await repository.save(
                    repository: remoteRepository,
                    organizationID: organization.id,
                    accountID: account.id
                )
            )
        }
        return summaries
    }
}
