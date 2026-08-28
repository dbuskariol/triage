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
        try await coverageRepository.save(
            coverageRecord(
                scope: synchronizationScope,
                streamID: streamID,
                interval: nil,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: attemptedAt
        )
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
        let searchClient = GitHubIssueSearchClient(client: restClient)
        var searchRange: SearchTimeRange?
        do {
            let serverObservedAt = try await searchClient.serverTime()
            let previousHighWater = try await SyncStreamRepository(vault: vault)
                .stream(withID: streamID, accountID: account.id)?
                .highWater
            let incompleteRange = try await coverageRepository.records(
                for: account.id,
                organizationID: organization.id
            ).compactMap { record -> SearchTimeRange? in
                guard record.feature == .roleDiscovery,
                      record.streamID == streamID,
                      record.credentialRevision == synchronizationScope.credentialRevision,
                      record.capabilityRevision == synchronizationScope.capabilityRevision,
                      record.status != .complete,
                      let start = record.intervalStart,
                      let end = record.intervalEnd
                else {
                    return nil
                }
                return SearchTimeRange(start: start, end: end)
            }.max { $0.end < $1.end }
            let range = incompleteRange ?? SearchTimeRange(
                start: previousHighWater ?? Date(timeIntervalSince1970: 0),
                end: serverObservedAt
            )
            searchRange = range
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
            let repositoryIDsByNodeID = Dictionary(
                uniqueKeysWithValues: inventory.map { ($0.nodeID.rawValue, $0.id) }
            )
            let plan = try RoleDiscoveryPlan(
                organizationLogin: organization.login,
                userLogin: account.login,
                now: serverObservedAt
            )
            let discoveryResult = try await RoleDiscoverySynchronizer(
                searchClient: searchClient,
                workItemRepository: WorkItemRepository(vault: vault),
                shardRepository: SyncShardRepository(vault: vault)
            ).synchronize(
                plan: plan,
                accountID: account.id,
                accountNodeID: account.nodeID,
                organizationID: organization.id,
                githubOrganizationID: organization.githubOrganizationID,
                streamID: streamID,
                searchRange: range,
                accessibleRepositoryNames: inventory.map(\.fullName),
                repositoryID: { repositoryIDsByAPIURL[$0.repositoryURL] }
            )
            let graphqlClient = GitHubGraphQLClient(
                credential: token,
                rateLimitController: rateLimitController
            )
            try await GitHubNodeHydrationService(
                client: graphqlClient,
                detailsRepository: GitHubNodeDetailsRepository(vault: vault),
                rawSnapshotRepository: RawAPISnapshotRepository(vault: vault),
                normalizationFailureRepository: NormalizationFailureRepository(vault: vault),
                batchMetricRepository: GitHubHydrationBatchMetricRepository(vault: vault)
            ).hydrate(
                nodeIDs: discoveryResult.candidateNodeIDs,
                accountID: account.id,
                organizationID: organization.id,
                repositoryID: { repository in
                    repositoryIDsByNodeID[repository.id]
                }
            )
            try await coverageRepository.save(
                coverageRecord(
                    scope: synchronizationScope,
                    streamID: streamID,
                    interval: range,
                    status: .complete,
                    lastSuccessfulAt: Date(),
                    failureDetail: nil
                ),
                attemptedAt: attemptedAt
            )
            return discoveryResult.workItemIDs
        } catch let failure as GitHubFailure {
            if let ssoHeader = failure.ssoHeader?.scoped(to: organization.githubOrganizationID) {
                try await coverageRepository.save(
                    coverageRecord(
                        scope: synchronizationScope,
                        streamID: streamID,
                        interval: searchRange,
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
                    interval: searchRange,
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
                    interval: searchRange,
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
                    interval: searchRange,
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
                    interval: searchRange,
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
        interval: SearchTimeRange?,
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
            intervalStart: interval?.start,
            intervalEnd: interval?.end,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: status,
            lastSuccessfulAt: lastSuccessfulAt,
            failureDetail: failureDetail
        )
    }
}
