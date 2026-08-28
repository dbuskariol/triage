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
        let synchronizationScope = try await AccountRepository(vault: vault).synchronizationScope(
            for: account.id,
            organizationID: organization.id
        )
        let coverageRepository = CoverageRepository(vault: vault)
        let streamID = SyncStreamID(rawValue: "role-discovery-\(organization.id.rawValue)")!
        let attemptedAt = Date()
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
        do {
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
                now: attemptedAt
            )
            let workItemIDs = try await RoleDiscoverySynchronizer(
                searchClient: GitHubIssueSearchClient(client: restClient),
                nodeRepository: GitHubNodeRepository(vault: vault),
                workItemRepository: WorkItemRepository(vault: vault),
                relationRepository: WorkRelationRepository(vault: vault),
                attentionRepository: AttentionReasonRepository(vault: vault),
                rawSnapshotRepository: RawAPISnapshotRepository(vault: vault),
                normalizationFailureRepository: NormalizationFailureRepository(vault: vault)
            ).synchronize(
                plan: plan,
                accountID: account.id,
                accountNodeID: account.nodeID,
                organizationID: organization.id,
                githubOrganizationID: organization.githubOrganizationID,
                repositoryID: { repositoryIDsByAPIURL[$0.repositoryURL] }
            )
            try await coverageRepository.save(
                coverageRecord(
                    scope: synchronizationScope,
                    streamID: streamID,
                    status: .complete,
                    lastSuccessfulAt: Date(),
                    failureDetail: nil
                ),
                attemptedAt: attemptedAt
            )
            return workItemIDs
        } catch let failure as GitHubFailure {
            if let ssoHeader = failure.ssoHeader?.scoped(to: organization.githubOrganizationID) {
                try await coverageRepository.save(
                    coverageRecord(
                        scope: synchronizationScope,
                        streamID: streamID,
                        status: .requiresSSO,
                        lastSuccessfulAt: nil,
                        failureDetail: "GitHub organization SSO authorization is required."
                    ),
                    attemptedAt: attemptedAt
                )
                throw OrganizationRefreshError.ssoRequirement(ssoHeader)
            }
            try await coverageRepository.save(
                coverageRecord(
                    scope: synchronizationScope,
                    streamID: streamID,
                    status: .failed,
                    lastSuccessfulAt: nil,
                    failureDetail: "GitHub request failed: \(failure.kind.rawValue)."
                ),
                attemptedAt: attemptedAt
            )
            throw failure
        } catch let failure as OrganizationRefreshError {
            let status: CoverageStatus = switch failure {
            case .ssoRequirement:
                .requiresSSO
            }
            try await coverageRepository.save(
                coverageRecord(
                    scope: synchronizationScope,
                    streamID: streamID,
                    status: status,
                    lastSuccessfulAt: nil,
                    failureDetail: "GitHub organization SSO authorization is required."
                ),
                attemptedAt: attemptedAt
            )
            throw failure
        } catch is CancellationError {
            try await coverageRepository.save(
                coverageRecord(
                    scope: synchronizationScope,
                    streamID: streamID,
                    status: .partial,
                    lastSuccessfulAt: nil,
                    failureDetail: "Refresh was cancelled before completion."
                ),
                attemptedAt: attemptedAt
            )
            throw CancellationError()
        } catch {
            try await coverageRepository.save(
                coverageRecord(
                    scope: synchronizationScope,
                    streamID: streamID,
                    status: .failed,
                    lastSuccessfulAt: nil,
                    failureDetail: "Refresh failed: \(String(reflecting: type(of: error)))."
                ),
                attemptedAt: attemptedAt
            )
            throw error
        }
    }

    private func coverageRecord(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        status: CoverageStatus,
        lastSuccessfulAt: Date?,
        failureDetail: String?
    ) -> CoverageRecord {
        CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: nil,
            feature: .roleDiscovery,
            streamID: streamID,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: status,
            lastSuccessfulAt: lastSuccessfulAt,
            failureDetail: failureDetail
        )
    }
}
