import CryptoKit
import Foundation
import GRDB

enum OrganizationRefreshError: Error, Equatable, Sendable {
    case ssoRequirement(GitHubSSOHeader)
}

enum OrganizationInventoryRefreshFailure: Equatable, Sendable {
    case ssoRequired(GitHubSSOHeader)
    case approvalRequired
    case authenticationRequired
    case rateLimited(retryAt: Date?)
    case unavailableOrPermission
    case partial
    case failed
}

enum OrganizationInventoryRefreshOutcome<Summary: Sendable>: Sendable {
    case success(summaries: [Summary], coverage: CoverageRecord)
    case failure(OrganizationInventoryRefreshFailure, coverage: CoverageRecord)
}

struct OrganizationInventoryRefreshResult: Sendable {
    let repositories: OrganizationInventoryRefreshOutcome<RepositorySummary>
    let teams: OrganizationInventoryRefreshOutcome<TeamInventorySummary>
}

enum OrganizationInventoryRefreshCadence {
    static let fullReconciliationInterval: TimeInterval = 24 * 60 * 60
}

actor OrganizationInventoryRefreshService {
    private let vaultRegistry: VaultRegistry
    private let vaultKeyReader: @Sendable (AccountID) async throws -> VaultKey?
    private let repositoryTeamClientFactory: @Sendable (
        GitHubAccount,
        GitHubRateLimitController?,
        GitHubRequestPriority
    ) async throws -> GitHubRepositoryTeamClient
    private let clock: @Sendable () -> Date

    init(
        credentialReader: AccountCredentialReader,
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.vaultRegistry = vaultRegistry
        vaultKeyReader = { accountID in
            try await secretStore.readVaultKey(for: accountID)
        }
        repositoryTeamClientFactory = { account, rateLimitController, requestPriority in
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
        self.clock = clock
    }

    init(
        vaultRegistry: VaultRegistry,
        vaultKeyReader: @escaping @Sendable (AccountID) async throws -> VaultKey?,
        repositoryTeamClientFactory: @escaping @Sendable (
            GitHubAccount,
            GitHubRateLimitController?,
            GitHubRequestPriority
        ) async throws -> GitHubRepositoryTeamClient,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.vaultRegistry = vaultRegistry
        self.vaultKeyReader = vaultKeyReader
        self.repositoryTeamClientFactory = repositoryTeamClientFactory
        self.clock = clock
    }

    /// Reconciles the complete authoritative repository inventory. Call `refreshInventory`
    /// when team inventory and current-account membership visibility are also required.
    func refreshRepositories(
        account: GitHubAccount,
        organization: GitHubOrganization,
        synchronizationScope: SynchronizationScope,
        rateLimitController: GitHubRateLimitController? = nil,
        requestPriority: GitHubRequestPriority = .selectedOrganizationRefresh,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) async throws -> [RepositorySummary] {
        let context = try await context(
            for: account,
            organization: organization,
            synchronizationScope: synchronizationScope
        )
        let observedAt = clock()
        try await validateCurrentScope(context)
        let client = try await repositoryTeamClient(
            for: account,
            rateLimitController: rateLimitController,
            requestPriority: requestPriority
        )
        try await validateCurrentScope(context)
        try Task.checkCancellation()
        do {
            let result = try await reconcileRepositories(
                with: client,
                context: context,
                observedAt: observedAt,
                reconciliationIntent: reconciliationIntent
            )
            return result.summaries
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reportedError = reportedError(for: error, context: context)
            _ = try await recordFailure(
                reportedError,
                feature: .repositories,
                context: context,
                observedAt: observedAt
            )
            throw reportedError
        }
    }

    /// Reconciles repositories, teams, and the authenticated account's visibility in every team.
    func refreshInventory(
        account: GitHubAccount,
        organization: GitHubOrganization,
        synchronizationScope: SynchronizationScope,
        rateLimitController: GitHubRateLimitController? = nil,
        requestPriority: GitHubRequestPriority = .selectedOrganizationRefresh,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) async throws -> OrganizationInventoryRefreshResult {
        let context = try await context(
            for: account,
            organization: organization,
            synchronizationScope: synchronizationScope
        )
        let observedAt = clock()
        try await validateCurrentScope(context)
        let client = try await repositoryTeamClient(
            for: account,
            rateLimitController: rateLimitController,
            requestPriority: requestPriority
        )
        try await validateCurrentScope(context)
        try Task.checkCancellation()
        let repositories = try await refreshRepositoriesOutcome(
            with: client,
            context: context,
            observedAt: observedAt,
            reconciliationIntent: reconciliationIntent
        )
        try Task.checkCancellation()
        let teams = try await refreshTeamsOutcome(
            with: client,
            context: context,
            accountLogin: account.login,
            observedAt: observedAt
        )
        return OrganizationInventoryRefreshResult(repositories: repositories, teams: teams)
    }

    private func refreshRepositoriesOutcome(
        with client: GitHubRepositoryTeamClient,
        context: Context,
        observedAt: Date,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) async throws -> OrganizationInventoryRefreshOutcome<RepositorySummary> {
        do {
            let result = try await reconcileRepositories(
                with: client,
                context: context,
                observedAt: observedAt,
                reconciliationIntent: reconciliationIntent
            )
            return .success(summaries: result.summaries, coverage: result.coverage)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reportedError = reportedError(for: error, context: context)
            let coverage = try await recordFailure(
                reportedError,
                feature: .repositories,
                context: context,
                observedAt: observedAt
            )
            return .failure(
                Self.failureClassification(for: reportedError, observedAt: observedAt),
                coverage: coverage
            )
        }
    }

    private func refreshTeamsOutcome(
        with client: GitHubRepositoryTeamClient,
        context: Context,
        accountLogin: String,
        observedAt: Date
    ) async throws -> OrganizationInventoryRefreshOutcome<TeamInventorySummary> {
        try await saveCoverage(
            partialCoverage(feature: .teams, context: context, observedAt: observedAt),
            context: context,
            attemptedAt: observedAt
        )
        do {
            let result = try await reconcileTeams(
                with: client,
                context: context,
                accountLogin: accountLogin,
                observedAt: observedAt
            )
            return .success(summaries: result.summaries, coverage: result.coverage)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reportedError = reportedError(for: error, context: context)
            let coverage = try await recordFailure(
                reportedError,
                feature: .teams,
                context: context,
                observedAt: observedAt
            )
            return .failure(
                Self.failureClassification(for: reportedError, observedAt: observedAt),
                coverage: coverage
            )
        }
    }

    private func reconcileRepositories(
        with client: GitHubRepositoryTeamClient,
        context: Context,
        observedAt: Date,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) async throws -> (summaries: [RepositorySummary], coverage: CoverageRecord) {
        let conditionalIdentity = conditionalRequestIdentity(
            feature: .repositories,
            requestKey: "GET /orgs/\(context.organization.login)/repos?type=all&per_page=100",
            context: context
        )
        let validator = try await context.conditionalRequests.validator(for: conditionalIdentity)
        try await validateCurrentScope(context)
        let requestValidators: GitHubHTTPValidators? = switch reconciliationIntent {
        case .incremental:
            try currentHTTPValidators(from: validator, observedAt: observedAt)
        case .fullReconciliation:
            nil
        }
        // A conditional attempt keeps the last completed coverage row intact
        // because that row is part of the local 304 replay authority. The
        // account/organization coordinator publishes `.refreshing` while the
        // request is in flight. Unconditional work has no replay authority and
        // records the incomplete attempt before leaving the vault.
        if requestValidators == nil {
            try await saveCoverage(
                partialCoverage(feature: .repositories, context: context, observedAt: observedAt),
                context: context,
                attemptedAt: observedAt
            )
        }
        var fetched = try await fetchRepositories(
            with: client,
            in: context.organization.login,
            validators: requestValidators
        )
        try await validateCurrentScope(context)
        try Task.checkCancellation()
        if case let .notModified(ssoHeader) = fetched {
            try throwForSSORequirement(
                in: ssoHeader,
                githubOrganizationID: context.organization.githubOrganizationID
            )
            if requestValidators != nil, let validator {
                do {
                    let replay = try await context.repositoryInventory.writeTransaction(
                        accountID: context.account.id
                    ) { database in
                        try Self.validateCurrentScope(
                            context.synchronizationScope,
                            account: context.account,
                            organization: context.organization,
                            in: database
                        )
                        return try RepositoryInventoryReplayReceiptRepository
                            .validatedNotModifiedReceipt(
                                for: validator,
                                organization: context.organization,
                                validatedAt: observedAt,
                                expectedAccountID: context.account.id,
                                in: database
                            )
                    }
                    if let replay {
                        try await validateCurrentScope(context)
                        return (replay.summaries, replay.coverage)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch is RepositoryInventoryReplayReceiptRepositoryError {
                    // The validator remains an HTTP optimization only. Missing or
                    // invalid local replay authority requires one unconditional fetch.
                }
            }
            try await validateCurrentScope(context)
            if requestValidators != nil {
                try await saveCoverage(
                    partialCoverage(feature: .repositories, context: context, observedAt: observedAt),
                    context: context,
                    attemptedAt: observedAt
                )
            }
            fetched = try await fetchRepositories(
                with: client,
                in: context.organization.login,
                validators: nil
            )
            try await validateCurrentScope(context)
            try Task.checkCancellation()
            if case let .notModified(ssoHeader) = fetched {
                try throwForSSORequirement(
                    in: ssoHeader,
                    githubOrganizationID: context.organization.githubOrganizationID
                )
                throw GitHubRepositoryTeamClientError.notModifiedWithoutCachedState
            }
        }
        let coverage = completeCoverage(feature: .repositories, context: context, observedAt: observedAt)
        switch fetched {
        case let .modified(inventory):
            try throwForSSORequirement(
                in: inventory.ssoHeader,
                githubOrganizationID: context.organization.githubOrganizationID
            )
            let preparedPages = try Self.prepareRepositoryPages(
                inventory.pages,
                context: context,
                observedAt: observedAt
            )
            guard let rootPage = preparedPages.first else {
                throw GitHubRepositoryTeamClientError.invalidRepository
            }
            let sourceRevision = Self.repositorySourceRevision(for: preparedPages)
            let responseValidator = Self.conditionalValidator(
                eTag: inventory.pages.first?.page.etag,
                lastModified: inventory.pages.first?.page.lastModified,
                identity: conditionalIdentity,
                observedAt: observedAt
            )
            try Task.checkCancellation()
            let summaries = try await context.repositoryInventory.writeTransaction(
                accountID: context.account.id
            ) { database in
                try Task.checkCancellation()
                try Self.validateCurrentScope(
                    context.synchronizationScope,
                    account: context.account,
                    organization: context.organization,
                    in: database
                )
                try Self.validateRepositoryAggregateReplay(
                    preparedPages,
                    context: context,
                    observedAt: observedAt,
                    in: database
                )
                for page in preparedPages {
                    try Task.checkCancellation()
                    try RawAPISnapshotRepository.save(page.snapshot, in: database)
                }
                let reconciliation = try RepositoryInventoryRepository.reconcile(
                    inventory.values,
                    accountID: context.account.id,
                    organization: context.organization,
                    observedAt: observedAt,
                    reconciliationIntent: reconciliationIntent,
                    in: database
                )
                try CoverageRepository.save(
                    coverage,
                    attemptedAt: observedAt,
                    expectedAccountID: context.account.id,
                    in: database
                )
                for repositoryID in reconciliation.returnedRepositoryIDs {
                    try Task.checkCancellation()
                    guard let page = preparedPages.first(where: {
                        $0.repositoryIDs.contains(repositoryID)
                    }),
                    let sourceNodeID = GitHubNodeID(rawValue: repositoryID.rawValue)
                    else {
                        throw GitHubRepositoryTeamClientError.invalidRepository
                    }
                    try CoverageRepository.save(
                        Self.repositoryAccessCoverage(
                            repositoryID: repositoryID,
                            status: .complete,
                            lastSuccessfulAt: observedAt,
                            failureDetail: nil,
                            context: context
                        ),
                        attemptedAt: observedAt,
                        expectedAccountID: context.account.id,
                        in: database
                    )
                    _ = try SourceAccessObservationRepository.record(
                        SourceAccessObservation(
                            id: Self.repositoryAccessObservationID(
                                repositoryID: repositoryID,
                                sourceRevision: sourceRevision,
                                rawSnapshotID: page.snapshot.id,
                                result: .accessible,
                                authority: Self.sourceAuthority(for: reconciliationIntent),
                                observedAt: observedAt,
                                context: context
                            ),
                            scope: context.synchronizationScope,
                            feature: .repositories,
                            streamID: conditionalIdentity.streamID,
                            target: .repository(repositoryID),
                            source: .endpoint(page.endpoint),
                            sourceNodeID: sourceNodeID,
                            sourceEventID: nil,
                            sourceRevision: sourceRevision,
                            rawSnapshotID: page.snapshot.id,
                            result: .accessible,
                            reason: .directResponse,
                            authority: Self.sourceAuthority(for: reconciliationIntent),
                            confirmation: .confirmed,
                            observedAt: observedAt
                        ),
                        expectedAccountID: context.account.id,
                        in: database
                    )
                }
                for repositoryID in reconciliation.omittedRepositoryIDs {
                    try Task.checkCancellation()
                    try CoverageRepository.save(
                        Self.repositoryAccessCoverage(
                            repositoryID: repositoryID,
                            status: .unknown,
                            lastSuccessfulAt: nil,
                            failureDetail: "Repository visibility was omitted from the latest complete inventory response.",
                            context: context
                        ),
                        attemptedAt: observedAt,
                        expectedAccountID: context.account.id,
                        in: database
                    )
                    _ = try SourceAccessObservationRepository.record(
                        SourceAccessObservation(
                            id: Self.repositoryAccessObservationID(
                                repositoryID: repositoryID,
                                sourceRevision: sourceRevision,
                                rawSnapshotID: nil,
                                result: .unknown,
                                authority: Self.sourceAuthority(for: reconciliationIntent),
                                observedAt: observedAt,
                                context: context
                            ),
                            scope: context.synchronizationScope,
                            feature: .repositories,
                            streamID: conditionalIdentity.streamID,
                            target: .repository(repositoryID),
                            source: .endpoint(rootPage.endpoint),
                            sourceNodeID: nil,
                            sourceEventID: nil,
                            sourceRevision: sourceRevision,
                            rawSnapshotID: nil,
                            result: .unknown,
                            reason: .inventoryOmission,
                            authority: Self.sourceAuthority(for: reconciliationIntent),
                            confirmation: .provisional,
                            observedAt: observedAt
                        ),
                        expectedAccountID: context.account.id,
                        in: database
                    )
                }
                try Self.persistConditionalValidator(
                    eTag: inventory.pages.first?.page.etag,
                    lastModified: inventory.pages.first?.page.lastModified,
                    identity: conditionalIdentity,
                    observedAt: observedAt,
                    expectedAccountID: context.account.id,
                    in: database
                )
                try RepositoryInventoryReplayReceiptRepository.replaceModifiedResponseReceipt(
                    RepositoryInventoryReplayReceiptInput(
                        identity: conditionalIdentity,
                        validator: responseValidator,
                        rawSourceRevision: sourceRevision,
                        pages: preparedPages.map { page in
                            RepositoryInventoryReplayReceiptPage(
                                pageIndex: page.pageIndex,
                                rawSnapshotID: page.snapshot.id,
                                endpoint: page.endpoint,
                                linkHeader: page.linkHeader,
                                nextEndpoint: page.nextEndpoint
                            )
                        },
                        normalizedCommittedAt: observedAt
                    ),
                    organization: context.organization,
                    expectedAccountID: context.account.id,
                    in: database
                )
                return reconciliation.summaries
            }
            let committed = try await committedCoverage(coverage, context: context)
            try await validateCurrentScope(context)
            return (summaries, committed)
        case .notModified:
            throw GitHubRepositoryTeamClientError.notModifiedWithoutCachedState
        }
    }

    private func reconcileTeams(
        with client: GitHubRepositoryTeamClient,
        context: Context,
        accountLogin: String,
        observedAt: Date
    ) async throws -> (summaries: [TeamInventorySummary], coverage: CoverageRecord) {
        let conditionalIdentity = conditionalRequestIdentity(
            feature: .teams,
            requestKey: "GET /orgs/\(context.organization.login)/teams?per_page=100",
            context: context
        )
        let validator = try await context.conditionalRequests.validator(for: conditionalIdentity)
        try await validateCurrentScope(context)
        let requestValidators = try currentHTTPValidators(from: validator, observedAt: observedAt)
        let fetched = try await client.fetchTeams(
            in: context.organization.login,
            validators: requestValidators
        )
        try await validateCurrentScope(context)
        try Task.checkCancellation()
        let updatedTeams: [GitHubTeamDTO]?
        let teamPages: [GitHubRepositoryTeamPage<GitHubTeamDTO>]
        let membershipTargets: [TeamMembershipTarget]
        switch fetched {
        case let .modified(inventory):
            try throwForSSORequirement(
                in: inventory.ssoHeader,
                githubOrganizationID: context.organization.githubOrganizationID
            )
            updatedTeams = inventory.values
            teamPages = inventory.pages
            membershipTargets = try inventory.values.map { team in
                guard let teamID = TeamID(rawValue: team.nodeID) else {
                    throw GitHubRepositoryTeamClientError.invalidTeam
                }
                return TeamMembershipTarget(id: teamID, slug: team.slug)
            }
        case let .notModified(ssoHeader):
            try throwForSSORequirement(
                in: ssoHeader,
                githubOrganizationID: context.organization.githubOrganizationID
            )
            guard requestValidators != nil else {
                throw GitHubRepositoryTeamClientError.notModifiedWithoutCachedState
            }
            updatedTeams = nil
            teamPages = []
            let cachedTeams = try await context.teamInventory.teams(
                accountID: context.account.id,
                organization: context.organization
            )
            try await validateCurrentScope(context)
            membershipTargets = cachedTeams.map { TeamMembershipTarget(id: $0.id, slug: $0.slug) }
        }
        var memberships = [TeamMembershipObservation]()
        var membershipSnapshots = [RawAPISnapshot]()
        for team in membershipTargets {
            try Task.checkCancellation()
            try await validateCurrentScope(context)
            let membership = try await client.membership(
                in: context.organization.login,
                teamSlug: team.slug,
                accountLogin: accountLogin
            )
            try await validateCurrentScope(context)
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
        let preparedTeamPages = teamPages
        let preparedUpdatedTeams = updatedTeams
        let coverage = completeCoverage(feature: .teams, context: context, observedAt: observedAt)
        try Task.checkCancellation()
        let summaries = try await context.teamInventory.writeTransaction(accountID: context.account.id) { database in
            try Self.validateCurrentScope(
                context.synchronizationScope,
                account: context.account,
                organization: context.organization,
                in: database
            )
            for page in preparedTeamPages {
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
            for snapshot in preparedMembershipSnapshots {
                try RawAPISnapshotRepository.save(snapshot, in: database)
            }
            let summaries: [TeamInventorySummary]
            if let preparedUpdatedTeams {
                summaries = try TeamInventoryRepository.replace(
                    teams: preparedUpdatedTeams,
                    memberships: preparedMemberships,
                    accountID: context.account.id,
                    organization: context.organization,
                    observedAt: observedAt,
                    in: database
                )
            } else {
                summaries = try TeamInventoryRepository.replaceMemberships(
                    memberships: preparedMemberships,
                    accountID: context.account.id,
                    organization: context.organization,
                    observedAt: observedAt,
                    in: database
                )
            }
            try CoverageRepository.save(
                coverage,
                attemptedAt: observedAt,
                expectedAccountID: context.account.id,
                in: database
            )
            if preparedUpdatedTeams != nil {
                try Self.persistConditionalValidator(
                    eTag: preparedTeamPages.first?.page.etag,
                    lastModified: preparedTeamPages.first?.page.lastModified,
                    identity: conditionalIdentity,
                    observedAt: observedAt,
                    expectedAccountID: context.account.id,
                    in: database
                )
            }
            return summaries
        }
        let committed = try await committedCoverage(coverage, context: context)
        try await validateCurrentScope(context)
        return (summaries, committed)
    }

    private func context(
        for account: GitHubAccount,
        organization: GitHubOrganization,
        synchronizationScope: SynchronizationScope
    ) async throws -> Context {
        guard synchronizationScope.accountID == account.id else {
            throw RepositoryInventoryRepositoryError.accountScopeMismatch
        }
        guard synchronizationScope.organizationID == organization.id else {
            throw RepositoryInventoryRepositoryError.organizationScopeMismatch
        }
        guard let vaultKey = try await vaultKeyReader(account.id) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        try await vault.read { database in
            try Self.validateCurrentScope(
                synchronizationScope,
                account: account,
                organization: organization,
                in: database
            )
        }
        return Context(
            account: account,
            organization: organization,
            synchronizationScope: synchronizationScope,
            vault: vault,
            repositoryInventory: RepositoryInventoryRepository(vault: vault),
            teamInventory: TeamInventoryRepository(vault: vault),
            coverage: CoverageRepository(vault: vault),
            conditionalRequests: ConditionalRequestCacheRepository(vault: vault)
        )
    }

    private func validateCurrentScope(_ context: Context) async throws {
        try await context.vault.read { database in
            try Self.validateCurrentScope(
                context.synchronizationScope,
                account: context.account,
                organization: context.organization,
                in: database
            )
        }
    }

    private nonisolated static func validateCurrentScope(
        _ synchronizationScope: SynchronizationScope,
        account: GitHubAccount,
        organization: GitHubOrganization,
        in database: Database
    ) throws {
        guard synchronizationScope.accountID == account.id else {
            throw RepositoryInventoryRepositoryError.accountScopeMismatch
        }
        guard synchronizationScope.organizationID == organization.id else {
            throw RepositoryInventoryRepositoryError.organizationScopeMismatch
        }
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT accounts.github_user_id AS account_github_id,
                       accounts.github_node_id AS account_node_id,
                       accounts.login AS account_login,
                       accounts.credential_revision,
                       organizations.github_organization_id AS organization_github_id,
                       organizations.github_node_id AS organization_node_id,
                       organizations.login AS organization_login,
                       account_organizations.capability_revision
                FROM accounts
                JOIN account_organizations
                  ON account_organizations.account_id = accounts.id
                JOIN organizations
                  ON organizations.id = account_organizations.organization_id
                WHERE accounts.id = ?
                  AND account_organizations.organization_id = ?
                  AND accounts.disabled_at_ms IS NULL
                """,
            arguments: [account.id.rawValue, organization.id.rawValue]
        ) else {
            throw CancellationError()
        }
        let accountGitHubIDValue = try row.decode(String.self, forColumn: "account_github_id")
        let accountNodeID = try row.decode(String.self, forColumn: "account_node_id")
        let accountLogin = try row.decode(String.self, forColumn: "account_login")
        guard let accountGitHubID = UInt64(accountGitHubIDValue),
              String(accountGitHubID) == accountGitHubIDValue,
              accountGitHubID == account.githubUserID,
              accountNodeID == account.nodeID.rawValue,
              accountLogin.caseInsensitiveCompare(account.login) == .orderedSame
        else {
            throw RepositoryInventoryRepositoryError.accountScopeMismatch
        }
        let organizationGitHubIDValue = try row.decode(String.self, forColumn: "organization_github_id")
        let organizationNodeID = try row.decode(String.self, forColumn: "organization_node_id")
        let organizationLogin = try row.decode(String.self, forColumn: "organization_login")
        guard let organizationGitHubID = UInt64(organizationGitHubIDValue),
              String(organizationGitHubID) == organizationGitHubIDValue,
              organizationGitHubID == organization.githubOrganizationID,
              organizationNodeID == organization.nodeID.rawValue,
              organizationLogin.caseInsensitiveCompare(organization.login) == .orderedSame
        else {
            throw RepositoryInventoryRepositoryError.organizationScopeMismatch
        }
        let credentialRevision = try row.decode(String.self, forColumn: "credential_revision")
        let capabilityRevision = try row.decode(String.self, forColumn: "capability_revision")
        guard credentialRevision == synchronizationScope.credentialRevision.rawValue,
              capabilityRevision == synchronizationScope.capabilityRevision.rawValue
        else {
            throw CancellationError()
        }
    }

    private func repositoryTeamClient(
        for account: GitHubAccount,
        rateLimitController: GitHubRateLimitController?,
        requestPriority: GitHubRequestPriority
    ) async throws -> GitHubRepositoryTeamClient {
        try await repositoryTeamClientFactory(account, rateLimitController, requestPriority)
    }

    private func fetchRepositories(
        with client: GitHubRepositoryTeamClient,
        in organization: String,
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubRepositoryTeamFetch<GitHubRepositoryDTO> {
        do {
            return try await client.fetchRepositories(
                in: organization,
                validators: validators
            )
        } catch GitHubRepositoryTeamClientError.notModifiedWithoutCachedState {
            // The REST inventory client rejects a 304 without a sent validator.
            // At this coordination layer it is still the first response, so the
            // protocol requires exactly one explicit unconditional retry.
            return .notModified(ssoHeader: nil)
        }
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
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: context.synchronizationScope.credentialRevision,
            capabilityRevision: context.synchronizationScope.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: observedAt,
            failureDetail: nil
        )
    }

    private func partialCoverage(
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
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: context.synchronizationScope.credentialRevision,
            capabilityRevision: context.synchronizationScope.capabilityRevision,
            status: .partial,
            lastSuccessfulAt: nil,
            failureDetail: nil
        )
    }

    private func recordFailure(
        _ error: Error,
        feature: CoverageFeature,
        context: Context,
        observedAt: Date
    ) async throws -> CoverageRecord {
        let failure = CoverageRecord(
            accountID: context.account.id,
            organizationID: context.organization.id,
            repositoryID: nil,
            feature: feature,
            streamID: streamID(for: feature, organizationID: context.organization.id),
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: context.synchronizationScope.credentialRevision,
            capabilityRevision: context.synchronizationScope.capabilityRevision,
            status: Self.coverageStatus(for: error),
            lastSuccessfulAt: nil,
            failureDetail: redactedFailureDetail(for: error)
        )
        return try await commitCoverage(failure, context: context, attemptedAt: observedAt)
    }

    private func commitCoverage(
        _ coverage: CoverageRecord,
        context: Context,
        attemptedAt: Date
    ) async throws -> CoverageRecord {
        try await saveCoverage(coverage, context: context, attemptedAt: attemptedAt)
        return try await committedCoverage(coverage, context: context)
    }

    private func saveCoverage(
        _ coverage: CoverageRecord,
        context: Context,
        attemptedAt: Date
    ) async throws {
        try await context.repositoryInventory.writeTransaction(
            accountID: context.account.id
        ) { database in
            try Self.validateCurrentScope(
                context.synchronizationScope,
                account: context.account,
                organization: context.organization,
                in: database
            )
            try CoverageRepository.save(
                coverage,
                attemptedAt: attemptedAt,
                expectedAccountID: context.account.id,
                in: database
            )
        }
    }

    private func committedCoverage(
        _ coverage: CoverageRecord,
        context: Context
    ) async throws -> CoverageRecord {
        let records = try await context.coverage.records(
            for: context.account.id,
            organizationID: context.organization.id
        )
        try await validateCurrentScope(context)
        guard let committed = records.filter({
            $0.feature == coverage.feature
                && $0.streamID == coverage.streamID
                && $0.credentialRevision == coverage.credentialRevision
                && $0.capabilityRevision == coverage.capabilityRevision
                && Self.coverageMilliseconds($0.intervalStart) == Self.coverageMilliseconds(coverage.intervalStart)
                && Self.coverageMilliseconds($0.intervalEnd) == Self.coverageMilliseconds(coverage.intervalEnd)
        }).first else {
            throw CoverageRepositoryError.invalidPersistedData
        }
        return committed
    }

    private nonisolated static func coverageMilliseconds(_ date: Date?) -> Int64? {
        date.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
    }

    private func throwForSSORequirement(
        in header: GitHubSSOHeader?,
        githubOrganizationID: UInt64
    ) throws {
        guard let requirement = header?.scoped(to: githubOrganizationID) else {
            return
        }
        switch requirement {
        case .authorizationRequired:
            throw OrganizationRefreshError.ssoRequirement(requirement)
        case .partialResults, .malformed:
            throw GitHubRepositoryTeamClientError.partialResults
        }
    }

    private func ssoRequirement(
        for error: Error,
        githubOrganizationID: UInt64
    ) -> OrganizationRefreshError? {
        guard let failure = error as? GitHubFailure,
              let header = failure.ssoHeader?.scoped(to: githubOrganizationID),
              case .authorizationRequired = header
        else {
            return nil
        }
        return .ssoRequirement(header)
    }

    private func reportedError(for error: Error, context: Context) -> Error {
        if let requirement = ssoRequirement(
            for: error,
            githubOrganizationID: context.organization.githubOrganizationID
        ) {
            return requirement
        }
        if let failure = error as? GitHubFailure,
           let header = failure.ssoHeader?.scoped(
               to: context.organization.githubOrganizationID
           ) {
            switch header {
            case .authorizationRequired:
                break
            case .partialResults, .malformed:
                return GitHubRepositoryTeamClientError.partialResults
            }
        }
        return error
    }

    private func streamID(for feature: CoverageFeature, organizationID: OrganizationID) -> SyncStreamID {
        SyncStreamID(rawValue: "inventory-\(feature.rawValue)-\(organizationID.rawValue)")!
    }

    private func conditionalRequestIdentity(
        feature: CoverageFeature,
        requestKey: String,
        context: Context
    ) -> ConditionalRequestIdentity {
        ConditionalRequestIdentity(
            scope: context.synchronizationScope,
            feature: feature,
            streamID: streamID(for: feature, organizationID: context.organization.id),
            requestKey: requestKey
        )
    }

    private func currentHTTPValidators(
        from validator: ConditionalRequestValidator?,
        observedAt: Date
    ) throws -> GitHubHTTPValidators? {
        guard let validator,
              validator.observedAt <= observedAt
        else {
            return nil
        }
        return try GitHubHTTPValidators(
            eTag: validator.eTag,
            lastModified: validator.lastModified
        )
    }

    private nonisolated static func persistConditionalValidator(
        eTag: String?,
        lastModified: String?,
        identity: ConditionalRequestIdentity,
        observedAt: Date,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        if let validator = conditionalValidator(
            eTag: eTag,
            lastModified: lastModified,
            identity: identity,
            observedAt: observedAt
        ) {
            try ConditionalRequestCacheRepository.save(
                validator,
                expectedAccountID: expectedAccountID,
                in: database
            )
        } else {
            try ConditionalRequestCacheRepository.remove(
                for: identity,
                expectedAccountID: expectedAccountID,
                in: database
            )
        }
    }

    private nonisolated static func conditionalValidator(
        eTag: String?,
        lastModified: String?,
        identity: ConditionalRequestIdentity,
        observedAt: Date
    ) -> ConditionalRequestValidator? {
        guard eTag != nil || lastModified != nil else { return nil }
        return ConditionalRequestValidator(
            identity: identity,
            eTag: eTag,
            lastModified: lastModified,
            observedAt: observedAt
        )
    }

    private nonisolated static func prepareRepositoryPages(
        _ pages: [GitHubRepositoryTeamPage<GitHubRepositoryDTO>],
        context: Context,
        observedAt: Date
    ) throws -> [PreparedRepositoryPage] {
        try pages.enumerated().map { offset, page in
            let repositoryIDs = try page.page.values.map { repository in
                guard let repositoryID = RepositoryID(rawValue: repository.nodeID) else {
                    throw GitHubRepositoryTeamClientError.invalidRepository
                }
                return repositoryID
            }
            let requestIdentity = ConditionalRequestIdentity(
                scope: context.synchronizationScope,
                feature: .repositories,
                streamID: SyncStreamID(
                    rawValue: "inventory-repositories-\(context.organization.id.rawValue)"
                )!,
                requestKey: "GET \(page.endpoint)"
            )
            return PreparedRepositoryPage(
                pageIndex: offset + 1,
                endpoint: page.endpoint,
                linkHeader: page.page.linkHeader,
                nextEndpoint: page.page.nextPageURL.map {
                    $0.path + ($0.query.map { "?\($0)" } ?? "")
                },
                repositoryIDs: repositoryIDs,
                snapshot: RawAPISnapshot(
                    id: repositoryPageSnapshotID(
                        page: page,
                        context: context,
                        observedAt: observedAt
                    ),
                    accountID: context.account.id,
                    githubNodeID: nil,
                    endpoint: page.endpoint,
                    eTag: page.page.etag,
                    lastModified: page.page.lastModified,
                    parserVersion: 1,
                    observedAt: observedAt,
                    payload: page.page.payload,
                    requestIdentity: requestIdentity
                )
            )
        }
    }

    private nonisolated static func repositorySourceRevision(
        for pages: [PreparedRepositoryPage]
    ) -> String {
        var hasher = SHA256()
        updateDigest(with: Data("repository-inventory-v1".utf8), hasher: &hasher)
        for page in pages {
            updateDigest(with: Data(page.endpoint.utf8), hasher: &hasher)
            updateDigest(with: page.snapshot.payload, hasher: &hasher)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "repository-inventory-v1:\(digest)"
    }

    /// Raw pages are the only aggregate receipt available before the durable
    /// normalized-replay receipt is introduced. Reject a different complete
    /// response at the same canonical instant even when both inventories have
    /// no repository targets on which to record an access observation.
    private nonisolated static func validateRepositoryAggregateReplay(
        _ pages: [PreparedRepositoryPage],
        context: Context,
        observedAt: Date,
        in database: Database
    ) throws {
        guard let streamID = pages.first?.snapshot.requestIdentity?.streamID else {
            throw GitHubRepositoryTeamClientError.invalidRepository
        }
        let proposedObservedAtMilliseconds = canonicalMilliseconds(observedAt)
        let maximumObservedAtMilliseconds = try Int64.fetchOne(
            database,
            sql: """
                SELECT MAX(observed_at_ms)
                FROM raw_api_snapshots
                WHERE account_id = ?
                  AND authority_organization_id = ?
                  AND authority_feature = ?
                  AND authority_stream_id = ?
                  AND authority_credential_revision = ?
                  AND authority_capability_revision = ?
                """,
            arguments: [
                context.account.id.rawValue,
                context.organization.id.rawValue,
                CoverageFeature.repositories.rawValue,
                streamID.rawValue,
                context.synchronizationScope.credentialRevision.rawValue,
                context.synchronizationScope.capabilityRevision.rawValue
            ]
        )
        guard let maximumObservedAtMilliseconds else { return }
        guard proposedObservedAtMilliseconds >= maximumObservedAtMilliseconds else {
            throw SourceAccessObservationRepositoryError.staleObservation
        }
        guard proposedObservedAtMilliseconds == maximumObservedAtMilliseconds else { return }
        let existingSnapshotIDs = try String.fetchAll(
            database,
            sql: """
                SELECT id
                FROM raw_api_snapshots
                WHERE account_id = ?
                  AND authority_organization_id = ?
                  AND authority_feature = ?
                  AND authority_stream_id = ?
                  AND authority_credential_revision = ?
                  AND authority_capability_revision = ?
                  AND observed_at_ms = ?
                ORDER BY id
                """,
            arguments: [
                context.account.id.rawValue,
                context.organization.id.rawValue,
                CoverageFeature.repositories.rawValue,
                streamID.rawValue,
                context.synchronizationScope.credentialRevision.rawValue,
                context.synchronizationScope.capabilityRevision.rawValue,
                proposedObservedAtMilliseconds
            ]
        )
        let proposedSnapshotIDs = pages.map(\.snapshot.id.rawValue).sorted()
        guard existingSnapshotIDs == proposedSnapshotIDs else {
            throw SourceAccessObservationRepositoryError.conflictingObservation
        }
    }

    private nonisolated static func repositoryPageSnapshotID(
        page: GitHubRepositoryTeamPage<GitHubRepositoryDTO>,
        context: Context,
        observedAt: Date
    ) -> RawAPISnapshotID {
        let components = [
            Data("repository-page-v1".utf8),
            Data(context.account.id.rawValue.utf8),
            Data(context.organization.id.rawValue.utf8),
            Data(context.synchronizationScope.credentialRevision.rawValue.utf8),
            Data(context.synchronizationScope.capabilityRevision.rawValue.utf8),
            Data(page.endpoint.utf8),
            Data((page.page.etag ?? "<nil>").utf8),
            Data((page.page.lastModified ?? "<nil>").utf8),
            Data(String(canonicalMilliseconds(observedAt)).utf8),
            page.page.payload
        ]
        return RawAPISnapshotID(rawValue: "repository-page:\(digest(components))")!
    }

    private nonisolated static func repositoryAccessObservationID(
        repositoryID: RepositoryID,
        sourceRevision: String,
        rawSnapshotID: RawAPISnapshotID?,
        result: SourceAccessResult,
        authority: SourceAccessAuthority,
        observedAt: Date,
        context: Context
    ) -> SourceAccessObservationID {
        let components = [
            Data("repository-access-observation-v1".utf8),
            Data(context.account.id.rawValue.utf8),
            Data(context.organization.id.rawValue.utf8),
            Data(context.synchronizationScope.credentialRevision.rawValue.utf8),
            Data(context.synchronizationScope.capabilityRevision.rawValue.utf8),
            Data(repositoryID.rawValue.utf8),
            Data(sourceRevision.utf8),
            Data((rawSnapshotID?.rawValue ?? "<nil>").utf8),
            Data(result.rawValue.utf8),
            Data(authority.rawValue.utf8),
            Data(String(canonicalMilliseconds(observedAt)).utf8)
        ]
        return SourceAccessObservationID(
            rawValue: "repository-access:\(digest(components))"
        )!
    }

    private nonisolated static func digest(_ components: [Data]) -> String {
        var hasher = SHA256()
        for component in components {
            updateDigest(with: component, hasher: &hasher)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func canonicalMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func updateDigest(
        with data: Data,
        hasher: inout SHA256
    ) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
    }

    private nonisolated static func repositoryAccessCoverage(
        repositoryID: RepositoryID,
        status: CoverageStatus,
        lastSuccessfulAt: Date?,
        failureDetail: String?,
        context: Context
    ) -> CoverageRecord {
        CoverageRecord(
            accountID: context.account.id,
            organizationID: context.organization.id,
            repositoryID: repositoryID,
            feature: .repositories,
            streamID: SyncStreamID(
                rawValue: "inventory-repositories-\(context.organization.id.rawValue)"
            )!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: context.synchronizationScope.credentialRevision,
            capabilityRevision: context.synchronizationScope.capabilityRevision,
            status: status,
            lastSuccessfulAt: lastSuccessfulAt,
            failureDetail: failureDetail
        )
    }

    private nonisolated static func sourceAuthority(
        for intent: SynchronizationReconciliationIntent
    ) -> SourceAccessAuthority {
        switch intent {
        case .incremental:
            .incremental
        case .fullReconciliation:
            .fullReconciliation
        }
    }

    nonisolated static func coverageStatus(for error: Error) -> CoverageStatus {
        if let refreshError = error as? OrganizationRefreshError,
           case .ssoRequirement = refreshError {
            return .requiresSSO
        }
        if let clientError = error as? GitHubRepositoryTeamClientError,
           clientError == .ambiguousMembershipVisibility || clientError == .partialResults {
            return .partial
        }
        guard let failure = error as? GitHubFailure else {
            return .failed
        }
        if let restriction = failure.accessRestriction {
            switch restriction {
            case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
                return .requiresApproval
            case .organizationPolicyBlocked:
                return .unavailable
            }
        }
        switch failure.kind {
        case .forbidden, .notFound:
            return .unavailable
        case .unauthorized, .rateLimited, .secondaryRateLimited, .serverFailure, .unexpectedResponse:
            return .failed
        }
    }

    nonisolated static func failureClassification(
        for error: Error,
        observedAt: Date
    ) -> OrganizationInventoryRefreshFailure {
        if let refreshError = error as? OrganizationRefreshError,
           case let .ssoRequirement(header) = refreshError {
            return .ssoRequired(header)
        }
        if let clientError = error as? GitHubRepositoryTeamClientError,
           clientError == .ambiguousMembershipVisibility || clientError == .partialResults {
            return .partial
        }
        guard let failure = error as? GitHubFailure else {
            return .failed
        }
        if let restriction = failure.accessRestriction {
            switch restriction {
            case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
                return .approvalRequired
            case .organizationPolicyBlocked:
                return .unavailableOrPermission
            }
        }
        switch failure.kind {
        case .unauthorized:
            return .authenticationRequired
        case .rateLimited, .secondaryRateLimited:
            let retryAt = failure.retryAfter.flatMap { delay in
                delay > 0 ? observedAt.addingTimeInterval(delay) : nil
            }
            return .rateLimited(retryAt: retryAt)
        case .forbidden, .notFound:
            return .unavailableOrPermission
        case .serverFailure, .unexpectedResponse:
            return .failed
        }
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
        let vault: AccountVault
        let repositoryInventory: RepositoryInventoryRepository
        let teamInventory: TeamInventoryRepository
        let coverage: CoverageRepository
        let conditionalRequests: ConditionalRequestCacheRepository
    }

    private struct TeamMembershipTarget: Sendable {
        let id: TeamID
        let slug: String
    }

    private struct PreparedRepositoryPage: Sendable {
        let pageIndex: Int
        let endpoint: String
        let linkHeader: String?
        let nextEndpoint: String?
        let repositoryIDs: [RepositoryID]
        let snapshot: RawAPISnapshot
    }
}
