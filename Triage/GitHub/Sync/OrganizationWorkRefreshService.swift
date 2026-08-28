import Foundation

actor OrganizationWorkRefreshService {
    private let credentialReader: AccountCredentialReader
    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore
    private let rateLimitControllers: GitHubRateLimitControllerRegistry
    private let requestPriority: GitHubRequestPriority

    init(
        credentialReader: AccountCredentialReader,
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        rateLimitControllers: GitHubRateLimitControllerRegistry = .shared,
        requestPriority: GitHubRequestPriority = .selectedOrganizationRefresh
    ) {
        self.credentialReader = credentialReader
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
        self.rateLimitControllers = rateLimitControllers
        self.requestPriority = requestPriority
    }

    func refresh(
        account: GitHubAccount,
        organization: GitHubOrganization
    ) async throws -> [WorkItemID] {
        let token = try await credentialReader.accessToken(for: account)
        guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        let rateLimitController = try await rateLimitControllers.controller(
            for: account.id,
            vault: vault
        )
        let restClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(),
            credential: token,
            rateLimitController: rateLimitController,
            requestPriority: requestPriority
        )
        let inventory = try await OrganizationInventoryRefreshService(
            credentialReader: credentialReader,
            vaultRegistry: vaultRegistry,
            secretStore: secretStore
        ).refreshRepositories(
            account: account,
            organization: organization,
            rateLimitController: rateLimitController,
            requestPriority: requestPriority
        )
        let repositoryIDsByAPIURL = Dictionary(
            uniqueKeysWithValues: inventory.map {
                (URL(string: "https://api.github.com/repos/\($0.fullName)")!, $0.id)
            }
        )
        let plan = try RoleDiscoveryPlan(
            organizationLogin: organization.login,
            userLogin: account.login,
            now: Date()
        )
        do {
            return try await RoleDiscoverySynchronizer(
                searchClient: GitHubIssueSearchClient(client: restClient),
                nodeRepository: GitHubNodeRepository(vault: vault),
                workItemRepository: WorkItemRepository(vault: vault),
                relationRepository: WorkRelationRepository(vault: vault),
                attentionRepository: AttentionReasonRepository(vault: vault)
            ).synchronize(
                plan: plan,
                accountID: account.id,
                accountNodeID: account.nodeID,
                organizationID: organization.id,
                githubOrganizationID: organization.githubOrganizationID,
                repositoryID: { repositoryIDsByAPIURL[$0.repositoryURL] }
            )
        } catch let failure as GitHubFailure {
            if let ssoHeader = failure.ssoHeader?.scoped(to: organization.githubOrganizationID) {
                throw OrganizationRefreshError.ssoRequirement(ssoHeader)
            }
            throw failure
        }
    }
}
