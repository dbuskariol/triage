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
        rateLimitController: GitHubRateLimitController? = nil,
        requestPriority: GitHubRequestPriority = .selectedOrganizationRefresh,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) async throws -> [RepositorySummary] {
        let context = try await context(for: account, organization: organization)
        let observedAt = clock()
        let client = try await repositoryTeamClient(
            for: account,
            rateLimitController: rateLimitController,
            requestPriority: requestPriority
        )
        try Task.checkCancellation()
        try await context.coverage.save(
            partialCoverage(feature: .repositories, context: context, observedAt: observedAt),
            attemptedAt: observedAt
        )
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
        rateLimitController: GitHubRateLimitController? = nil,
        requestPriority: GitHubRequestPriority = .selectedOrganizationRefresh,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) async throws -> OrganizationInventoryRefreshResult {
        let context = try await context(for: account, organization: organization)
        let observedAt = clock()
        let client = try await repositoryTeamClient(
            for: account,
            rateLimitController: rateLimitController,
            requestPriority: requestPriority
        )
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
        try await context.coverage.save(
            partialCoverage(feature: .repositories, context: context, observedAt: observedAt),
            attemptedAt: observedAt
        )
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
        try await context.coverage.save(
            partialCoverage(feature: .teams, context: context, observedAt: observedAt),
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
        let requestValidators: GitHubHTTPValidators? = switch reconciliationIntent {
        case .incremental:
            try currentHTTPValidators(from: validator, observedAt: observedAt)
        case .fullReconciliation:
            nil
        }
        let fetched = try await client.fetchRepositories(
            in: context.organization.login,
            validators: requestValidators
        )
        try Task.checkCancellation()
        let coverage = completeCoverage(feature: .repositories, context: context, observedAt: observedAt)
        switch fetched {
        case let .modified(inventory):
            try throwForSSORequirement(
                in: inventory.ssoHeader,
                githubOrganizationID: context.organization.githubOrganizationID
            )
            let summaries = try await context.repositoryInventory.writeTransaction(
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
                let summaries = try RepositoryInventoryRepository.replace(
                    inventory.values,
                    accountID: context.account.id,
                    organization: context.organization,
                    observedAt: observedAt,
                    in: database
                )
                try CoverageRepository.save(
                    coverage,
                    attemptedAt: observedAt,
                    expectedAccountID: context.account.id,
                    in: database
                )
                try Self.persistConditionalValidator(
                    eTag: inventory.pages.first?.page.etag,
                    lastModified: inventory.pages.first?.page.lastModified,
                    identity: conditionalIdentity,
                    observedAt: observedAt,
                    expectedAccountID: context.account.id,
                    in: database
                )
                return summaries
            }
            return (
                summaries,
                try await committedCoverage(coverage, context: context)
            )
        case .notModified:
            let summaries = try await context.repositoryInventory.repositories(
                accountID: context.account.id,
                organization: context.organization
            )
            return (
                summaries,
                try await commitCoverage(coverage, context: context, attemptedAt: observedAt)
            )
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
        let requestValidators = try currentHTTPValidators(from: validator, observedAt: observedAt)
        let fetched = try await client.fetchTeams(
            in: context.organization.login,
            validators: requestValidators
        )
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
        case .notModified:
            updatedTeams = nil
            teamPages = []
            let cachedTeams = try await context.teamInventory.teams(
                accountID: context.account.id,
                organization: context.organization
            )
            membershipTargets = cachedTeams.map { TeamMembershipTarget(id: $0.id, slug: $0.slug) }
        }
        var memberships = [TeamMembershipObservation]()
        var membershipSnapshots = [RawAPISnapshot]()
        for team in membershipTargets {
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
        let preparedTeamPages = teamPages
        let preparedUpdatedTeams = updatedTeams
        let coverage = completeCoverage(feature: .teams, context: context, observedAt: observedAt)
        try Task.checkCancellation()
        let summaries = try await context.teamInventory.writeTransaction(accountID: context.account.id) { database in
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
        return (
            summaries,
            try await committedCoverage(coverage, context: context)
        )
    }

    private func context(
        for account: GitHubAccount,
        organization: GitHubOrganization
    ) async throws -> Context {
        guard let vaultKey = try await vaultKeyReader(account.id) else {
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
            coverage: CoverageRepository(vault: vault),
            conditionalRequests: ConditionalRequestCacheRepository(vault: vault)
        )
    }

    private func repositoryTeamClient(
        for account: GitHubAccount,
        rateLimitController: GitHubRateLimitController?,
        requestPriority: GitHubRequestPriority
    ) async throws -> GitHubRepositoryTeamClient {
        try await repositoryTeamClientFactory(account, rateLimitController, requestPriority)
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
        try await context.coverage.save(coverage, attemptedAt: attemptedAt)
        return try await committedCoverage(coverage, context: context)
    }

    private func committedCoverage(
        _ coverage: CoverageRecord,
        context: Context
    ) async throws -> CoverageRecord {
        guard let committed = try await context.coverage.records(
            for: context.account.id,
            organizationID: context.organization.id
        ).filter({
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

    private func reportedError(for error: Error, context: Context) -> Error {
        ssoRequirement(
            for: error,
            githubOrganizationID: context.organization.githubOrganizationID
        ) ?? error
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
              validator.observedAt >= observedAt.addingTimeInterval(
                  -OrganizationInventoryRefreshCadence.fullReconciliationInterval
              )
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
        if eTag != nil || lastModified != nil {
            try ConditionalRequestCacheRepository.save(
                ConditionalRequestValidator(
                    identity: identity,
                    eTag: eTag,
                    lastModified: lastModified,
                    observedAt: observedAt
                ),
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
           clientError == .ambiguousMembershipVisibility {
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
        let repositoryInventory: RepositoryInventoryRepository
        let teamInventory: TeamInventoryRepository
        let coverage: CoverageRepository
        let conditionalRequests: ConditionalRequestCacheRepository
    }

    private struct TeamMembershipTarget: Sendable {
        let id: TeamID
        let slug: String
    }
}
