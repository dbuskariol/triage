import Foundation

enum OrganizationRefreshError: Error, Equatable, Sendable {
    case ssoRequirement(GitHubSSOHeader)
}

struct OrganizationInventoryRefreshResult: Sendable {
    let repositories: [RepositorySummary]
    let teams: [TeamInventorySummary]
    let repositoryCoverage: CoverageRecord
    let teamCoverage: CoverageRecord
}

enum OrganizationInventoryRefreshCadence {
    static let overlap: TimeInterval = 5 * 60
    static let fullReconciliationInterval: TimeInterval = 24 * 60 * 60
}

actor OrganizationInventoryRefreshService {
    private let credentialReader: AccountCredentialReader
    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore
    private let clock: @Sendable () -> Date

    init(
        credentialReader: AccountCredentialReader,
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialReader = credentialReader
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
        self.clock = clock
    }

    /// Reconciles the complete authoritative repository inventory. Call `refreshInventory`
    /// when team inventory and current-account membership visibility are also required.
    func refreshRepositories(
        account: GitHubAccount,
        organization: GitHubOrganization,
        rateLimitController: GitHubRateLimitController? = nil,
        requestPriority: GitHubRequestPriority = .selectedOrganizationRefresh
    ) async throws -> [RepositorySummary] {
        let context = try await context(for: account, organization: organization)
        let observedAt = clock()
        let client = try await repositoryTeamClient(
            for: account,
            rateLimitController: rateLimitController,
            requestPriority: requestPriority
        )
        return try await refreshRepositories(
            with: client,
            context: context,
            observedAt: observedAt
        ).summaries
    }

    /// Reconciles repositories, teams, and the authenticated account's visibility in every team.
    func refreshInventory(
        account: GitHubAccount,
        organization: GitHubOrganization,
        rateLimitController: GitHubRateLimitController? = nil,
        requestPriority: GitHubRequestPriority = .selectedOrganizationRefresh
    ) async throws -> OrganizationInventoryRefreshResult {
        let context = try await context(for: account, organization: organization)
        let observedAt = clock()
        let client = try await repositoryTeamClient(
            for: account,
            rateLimitController: rateLimitController,
            requestPriority: requestPriority
        )
        let repositories = try await refreshRepositories(
            with: client,
            context: context,
            observedAt: observedAt
        )
        let teams = try await refreshTeams(
            with: client,
            context: context,
            accountLogin: account.login,
            observedAt: observedAt
        )
        return OrganizationInventoryRefreshResult(
            repositories: repositories.summaries,
            teams: teams.summaries,
            repositoryCoverage: repositories.coverage,
            teamCoverage: teams.coverage
        )
    }

    private func refreshRepositories(
        with client: GitHubRepositoryTeamClient,
        context: Context,
        observedAt: Date
    ) async throws -> (summaries: [RepositorySummary], coverage: CoverageRecord) {
        do {
            let eTag = try await context.repositoryInventory.cachedETag(
                accountID: context.account.id,
                organization: context.organization,
                fullReconciliationCutoff: observedAt.addingTimeInterval(
                    -OrganizationInventoryRefreshCadence.fullReconciliationInterval
                )
            )
            let fetched = try await client.fetchRepositories(
                in: context.organization.login,
                eTag: eTag
            )
            let summaries: [RepositorySummary]
            switch fetched {
            case let .modified(inventory):
                try throwForSSORequirement(
                    in: inventory.ssoHeader,
                    githubOrganizationID: context.organization.githubOrganizationID
                )
                summaries = try await context.repositoryInventory.writeTransaction(
                    accountID: context.account.id
                ) { database in
                    for page in inventory.pages {
                        try RawAPISnapshotRepository.save(
                            RawAPISnapshot(
                                id: RawAPISnapshotID.make(),
                                accountID: context.account.id,
                                githubNodeID: nil,
                                endpoint: page.endpoint,
                                eTag: page.page.etag,
                                parserVersion: 1,
                                observedAt: observedAt,
                                payload: page.page.payload
                            ),
                            in: database
                        )
                    }
                    return try RepositoryInventoryRepository.replace(
                        inventory.values,
                        accountID: context.account.id,
                        organization: context.organization,
                        observedAt: observedAt,
                        in: database
                    )
                }
            case .notModified:
                summaries = try await context.repositoryInventory.repositories(
                    accountID: context.account.id,
                    organization: context.organization
                )
            }
            let coverage = completeCoverage(
                feature: .repositories,
                context: context,
                observedAt: observedAt
            )
            try await context.coverage.save(coverage, attemptedAt: observedAt)
            return (summaries, coverage)
        } catch {
            let reportedError: Error = ssoRequirement(
                for: error,
                githubOrganizationID: context.organization.githubOrganizationID
            ) ?? error
            try await recordFailure(
                reportedError,
                feature: .repositories,
                context: context,
                observedAt: observedAt
            )
            throw reportedError
        }
    }

    private func refreshTeams(
        with client: GitHubRepositoryTeamClient,
        context: Context,
        accountLogin: String,
        observedAt: Date
    ) async throws -> (summaries: [TeamInventorySummary], coverage: CoverageRecord) {
        do {
            let eTag = try await context.teamInventory.cachedETag(
                accountID: context.account.id,
                organization: context.organization,
                fullReconciliationCutoff: observedAt.addingTimeInterval(
                    -OrganizationInventoryRefreshCadence.fullReconciliationInterval
                )
            )
            let fetched = try await client.fetchTeams(in: context.organization.login, eTag: eTag)
            let teams: [TeamInventorySummary]
            switch fetched {
            case let .modified(inventory):
                try throwForSSORequirement(
                    in: inventory.ssoHeader,
                    githubOrganizationID: context.organization.githubOrganizationID
                )
                try await context.teamInventory.writeTransaction(accountID: context.account.id) { database in
                    for page in inventory.pages {
                        try RawAPISnapshotRepository.save(
                            RawAPISnapshot(
                                id: RawAPISnapshotID.make(),
                                accountID: context.account.id,
                                githubNodeID: nil,
                                endpoint: page.endpoint,
                                eTag: page.page.etag,
                                parserVersion: 1,
                                observedAt: observedAt,
                                payload: page.page.payload
                            ),
                            in: database
                        )
                    }
                    _ = try TeamInventoryRepository.replaceTeams(
                        inventory.values,
                        accountID: context.account.id,
                        organization: context.organization,
                        observedAt: observedAt,
                        in: database
                    )
                }
                teams = try await context.teamInventory.teams(
                    accountID: context.account.id,
                    organization: context.organization
                )
            case .notModified:
                teams = try await context.teamInventory.teams(
                    accountID: context.account.id,
                    organization: context.organization
                )
            }
            var memberships = [TeamMembershipObservation]()
            var membershipSnapshots = [RawAPISnapshot]()
            for team in teams {
                try Task.checkCancellation()
                let membership = try await client.membership(
                    in: context.organization.login,
                    teamSlug: team.slug,
                    accountLogin: accountLogin
                )
                guard case .unknown = membership else {
                    if case let .member(response) = membership {
                        membershipSnapshots.append(
                            RawAPISnapshot(
                                id: RawAPISnapshotID.make(),
                                accountID: context.account.id,
                                githubNodeID: nil,
                                endpoint: "/orgs/\(context.organization.login)/teams/\(team.slug)/memberships/\(accountLogin)",
                                eTag: response.etag,
                                parserVersion: 1,
                                observedAt: observedAt,
                                payload: response.payload
                            )
                        )
                    }
                    memberships.append(TeamMembershipObservation(teamID: team.id, membership: membership))
                    continue
                }
                throw GitHubRepositoryTeamClientError.ambiguousMembershipVisibility
            }
            let preparedMemberships = memberships
            let preparedMembershipSnapshots = membershipSnapshots
            let summaries = try await context.teamInventory.writeTransaction(
                accountID: context.account.id
            ) { database in
                for snapshot in preparedMembershipSnapshots {
                    try RawAPISnapshotRepository.save(snapshot, in: database)
                }
                return try TeamInventoryRepository.replaceMemberships(
                    memberships: preparedMemberships,
                    accountID: context.account.id,
                    organization: context.organization,
                    observedAt: observedAt,
                    in: database
                )
            }
            let coverage = completeCoverage(
                feature: .teams,
                context: context,
                observedAt: observedAt
            )
            try await context.coverage.save(coverage, attemptedAt: observedAt)
            return (summaries, coverage)
        } catch {
            let reportedError: Error = ssoRequirement(
                for: error,
                githubOrganizationID: context.organization.githubOrganizationID
            ) ?? error
            try await recordFailure(
                reportedError,
                feature: .teams,
                context: context,
                observedAt: observedAt
            )
            throw reportedError
        }
    }

    private func context(
        for account: GitHubAccount,
        organization: GitHubOrganization
    ) async throws -> Context {
        guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        let accountRepository = AccountRepository(vault: vault)
        guard (try await accountRepository.accounts()).contains(where: {
            $0.id == account.id
                && $0.githubUserID == account.githubUserID
                && $0.nodeID == account.nodeID
                && $0.login.caseInsensitiveCompare(account.login) == .orderedSame
        }) else {
            throw RepositoryInventoryRepositoryError.accountScopeMismatch
        }
        guard (try await accountRepository.organizations(for: account.id)).contains(where: {
            $0.id == organization.id
                && $0.githubOrganizationID == organization.githubOrganizationID
                && $0.login.caseInsensitiveCompare(organization.login) == .orderedSame
        }) else {
            throw RepositoryInventoryRepositoryError.organizationScopeMismatch
        }
        let synchronizationScope = try await accountRepository.synchronizationScope(
            for: account.id,
            organizationID: organization.id
        )
        return Context(
            account: account,
            organization: organization,
            synchronizationScope: synchronizationScope,
            repositoryInventory: RepositoryInventoryRepository(vault: vault),
            teamInventory: TeamInventoryRepository(vault: vault),
            coverage: CoverageRepository(vault: vault)
        )
    }

    private func repositoryTeamClient(
        for account: GitHubAccount,
        rateLimitController: GitHubRateLimitController?,
        requestPriority: GitHubRequestPriority
    ) async throws -> GitHubRepositoryTeamClient {
        let token = try await credentialReader.accessToken(for: account)
        return GitHubRepositoryTeamClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(),
                credential: token,
                rateLimitController: rateLimitController,
                requestPriority: requestPriority
            )
        )
    }

    private func completeCoverage(
        feature: CoverageFeature,
        context: Context,
        observedAt: Date
    ) -> CoverageRecord {
        CoverageRecord(
            accountID: context.account.id,
            organizationID: context.organization.id,
            repositoryID: nil,
            feature: feature,
            streamID: streamID(for: feature, organizationID: context.organization.id),
            intervalStart: observedAt.addingTimeInterval(-OrganizationInventoryRefreshCadence.overlap),
            intervalEnd: observedAt,
            credentialRevision: context.synchronizationScope.credentialRevision,
            capabilityRevision: context.synchronizationScope.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: observedAt,
            failureDetail: nil
        )
    }

    private func recordFailure(
        _ error: Error,
        feature: CoverageFeature,
        context: Context,
        observedAt: Date
    ) async throws {
        let failure = CoverageRecord(
            accountID: context.account.id,
            organizationID: context.organization.id,
            repositoryID: nil,
            feature: feature,
            streamID: streamID(for: feature, organizationID: context.organization.id),
            intervalStart: observedAt.addingTimeInterval(-OrganizationInventoryRefreshCadence.overlap),
            intervalEnd: observedAt,
            credentialRevision: context.synchronizationScope.credentialRevision,
            capabilityRevision: context.synchronizationScope.capabilityRevision,
            status: Self.coverageStatus(for: error),
            lastSuccessfulAt: nil,
            failureDetail: redactedFailureDetail(for: error)
        )
        try await context.coverage.save(failure, attemptedAt: observedAt)
    }

    private func throwForSSORequirement(
        in header: GitHubSSOHeader?,
        githubOrganizationID: UInt64
    ) throws {
        if let requirement = header?.scoped(to: githubOrganizationID) {
            throw OrganizationRefreshError.ssoRequirement(requirement)
        }
    }

    private func ssoRequirement(
        for error: Error,
        githubOrganizationID: UInt64
    ) -> OrganizationRefreshError? {
        guard let failure = error as? GitHubFailure,
              let header = failure.ssoHeader?.scoped(to: githubOrganizationID)
        else {
            return nil
        }
        return .ssoRequirement(header)
    }

    private func streamID(for feature: CoverageFeature, organizationID: OrganizationID) -> SyncStreamID {
        SyncStreamID(rawValue: "inventory-\(feature.rawValue)-\(organizationID.rawValue)")!
    }

    nonisolated static func coverageStatus(for error: Error) -> CoverageStatus {
        if let refreshError = error as? OrganizationRefreshError,
           case .ssoRequirement = refreshError {
            return .requiresSSO
        }
        if let clientError = error as? GitHubRepositoryTeamClientError,
           clientError == .ambiguousMembershipVisibility {
            return .partial
        }
        guard let failure = error as? GitHubFailure else {
            return .failed
        }
        return failure.accessRestriction == nil ? .failed : .requiresApproval
    }

    private func redactedFailureDetail(for error: Error) -> String {
        if error is CancellationError {
            return "Inventory refresh was cancelled before authoritative pagination completed."
        }
        if let failure = error as? GitHubFailure {
            return "GitHub inventory request failed with HTTP \(failure.statusCode) (\(failure.kind.rawValue))."
        }
        switch error {
        case let error as GitHubRepositoryTeamClientError
            where error == .ambiguousMembershipVisibility:
            return "GitHub did not confirm team membership visibility. Check organization team visibility and token Members access."
        case is GitHubRepositoryTeamClientError:
            return "GitHub inventory response did not satisfy local validation."
        case is RepositoryInventoryRepositoryError, is TeamInventoryRepositoryError:
            return "GitHub inventory could not be reconciled into the selected organization scope."
        default:
            return "GitHub inventory refresh did not complete."
        }
    }

    private struct Context: Sendable {
        let account: GitHubAccount
        let organization: GitHubOrganization
        let synchronizationScope: SynchronizationScope
        let repositoryInventory: RepositoryInventoryRepository
        let teamInventory: TeamInventoryRepository
        let coverage: CoverageRepository
    }
}
