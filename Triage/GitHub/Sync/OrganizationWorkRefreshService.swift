import Foundation

actor OrganizationWorkRefreshService {
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

    func refresh(
        account: GitHubAccount,
        organization: GitHubOrganization
    ) async throws -> [WorkItemID] {
        let token = try await credentialReader.accessToken(for: account)
        let restClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(),
            credential: token
        )
        let inventory = try await OrganizationInventoryRefreshService(
            credentialReader: credentialReader,
            vaultRegistry: vaultRegistry,
            secretStore: secretStore
        ).refreshRepositories(account: account, organization: organization)
        let repositoryIDsByAPIURL = Dictionary(
            uniqueKeysWithValues: inventory.map {
                (URL(string: "https://api.github.com/repos/\($0.fullName)")!, $0.id)
            }
        )
        guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        let plan = try RoleDiscoveryPlan(
            organizationLogin: organization.login,
            userLogin: account.login,
            now: Date()
        )
        return try await RoleDiscoverySynchronizer(
            searchClient: GitHubIssueSearchClient(client: restClient),
            nodeRepository: GitHubNodeRepository(vault: vault),
            workItemRepository: WorkItemRepository(vault: vault),
            attentionRepository: AttentionReasonRepository(vault: vault)
        ).synchronize(
            plan: plan,
            accountID: account.id,
            organizationID: organization.id,
            repositoryID: { repositoryIDsByAPIURL[$0.repositoryURL] }
        )
    }
}
