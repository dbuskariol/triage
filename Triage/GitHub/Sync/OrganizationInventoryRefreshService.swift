import Foundation

enum OrganizationRefreshError: Error, Equatable, Sendable {
    case ssoRequirement(GitHubSSOHeader)
}

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
        let inventory: GitHubRepositoryInventory
        do {
            inventory = try await GitHubIdentityClient(client: client)
                .allRepositories(in: organization.login)
        } catch let failure as GitHubFailure {
            if let ssoHeader = failure.ssoHeader?.scoped(to: organization.githubOrganizationID) {
                throw OrganizationRefreshError.ssoRequirement(ssoHeader)
            }
            throw failure
        }
        if let ssoHeader = inventory.ssoHeader?.scoped(to: organization.githubOrganizationID) {
            throw OrganizationRefreshError.ssoRequirement(ssoHeader)
        }
        guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        var summaries: [RepositorySummary] = []
        for remoteRepository in inventory.repositories {
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
