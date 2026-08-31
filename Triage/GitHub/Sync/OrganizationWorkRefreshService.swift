import Foundation
import GRDB

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
        organization: GitHubOrganization,
        synchronizationScope: SynchronizationScope,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) async throws -> [WorkItemID] {
        guard synchronizationScope.accountID == account.id,
              synchronizationScope.organizationID == organization.id
        else {
            throw CancellationError()
        }
        guard let vaultKey = try await secretStore.readVaultKey(for: account.id) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: account.id, vaultKey: vaultKey)
        let currentScope = try await AccountRepository(vault: vault).synchronizationScope(
            for: account.id,
            organizationID: organization.id
        )
        guard currentScope == synchronizationScope else {
            throw CancellationError()
        }
        try await validateCurrentScope(synchronizationScope, vault: vault)
        let token = try await credentialReader.accessToken(for: account)
        try await validateCurrentScope(synchronizationScope, vault: vault)
        let coverageRepository = CoverageRepository(vault: vault)
        let streamID = SyncStreamID(rawValue: "role-discovery-\(organization.id.rawValue)")!
        let attemptedAt = Date()
        try await validateCurrentScope(synchronizationScope, vault: vault)
        let rateLimitController = try await rateLimitControllers.controller(
            for: account.id,
            vault: vault
        )
        try await validateCurrentScope(synchronizationScope, vault: vault)
        let restClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(),
            credential: token,
            rateLimitController: rateLimitController,
            requestPriority: requestPriority
        )
        // Post-account only: bind selected-organization metadata to the
        // persisted scope before any work source can treat it as current. The
        // first account connection remains unconditional in
        // AccountConnectionService; this path has an exact vault scope.
        let identityClient = GitHubIdentityClient(client: restClient)
        _ = try await PostAccountOrganizationMetadataReplayService(
            client: identityClient,
            receipts: PostAccountIdentityReplayReceiptRepository(vault: vault)
        ).organization(organization, scope: synchronizationScope)
        try await validateCurrentScope(synchronizationScope, vault: vault)
        let searchClient = GitHubIssueSearchClient(client: restClient)
        var searchRange: SearchTimeRange?
        var deferredSSORequirement: GitHubSSOHeader?
        var contextRecovery = OrganizationContextRecovery()
        var roleDiscoveryCompleted = false
        let refreshedWorkItemIDs: [WorkItemID]
        do {
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let serverObservedAt = try await searchClient.serverTime()
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let previousHighWater = try await SyncStreamRepository(vault: vault)
                .stream(withID: streamID, accountID: account.id)?
                .highWater
            try await validateCurrentScope(synchronizationScope, vault: vault)
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
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let overlapStart = previousHighWater.map {
                max($0.addingTimeInterval(-10 * 60), Date(timeIntervalSince1970: 0))
            }
            let range = incompleteRange ?? SearchTimeRange(
                start: overlapStart ?? Date(timeIntervalSince1970: 0),
                end: serverObservedAt
            )
            searchRange = range
            let initialRoleCoverage = coverageRecord(
                scope: synchronizationScope,
                streamID: streamID,
                interval: range,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            )
            try Task.checkCancellation()
            try await vault.write { database in
                try Self.validateCurrentScope(synchronizationScope, in: database)
                try CoverageRepository.removeUnboundedRecord(
                    accountID: synchronizationScope.accountID,
                    organizationID: synchronizationScope.organizationID,
                    feature: .roleDiscovery,
                    streamID: streamID,
                    expectedAccountID: synchronizationScope.accountID,
                    in: database
                )
                try CoverageRepository.save(
                    initialRoleCoverage,
                    attemptedAt: attemptedAt,
                    expectedAccountID: synchronizationScope.accountID,
                    in: database
                )
            }
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let inventoryResult = try await OrganizationInventoryRefreshService(
                credentialReader: credentialReader,
                vaultRegistry: vaultRegistry,
                secretStore: secretStore
            ).refreshInventory(
                account: account,
                organization: organization,
                synchronizationScope: synchronizationScope,
                rateLimitController: rateLimitController,
                requestPriority: requestPriority,
                reconciliationIntent: reconciliationIntent
            )
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let inventory: [RepositorySummary]
            switch inventoryResult.repositories {
            case let .success(summaries, _):
                inventory = summaries
            case let .failure(failure, _):
                throw requiredRepositoryInventoryFailure(failure)
            }
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let notificationCapability = try await AccountRepository(vault: vault)
                .accountCapabilities(for: account.id)?
                .status(for: .notifications) ?? .unknown
            try await validateCurrentScope(synchronizationScope, vault: vault)
            try await refreshNotifications(
                restClient: restClient,
                vault: vault,
                scope: synchronizationScope,
                organization: organization,
                capabilityStatus: notificationCapability,
                attemptedAt: attemptedAt
            )
            try await validateCurrentScope(synchronizationScope, vault: vault)
            if case let .failure(.ssoRequired(header), _) = inventoryResult.teams {
                deferredSSORequirement = header
            }
            let teamSummaries: [TeamInventorySummary]
            let teamDiscoveryStatus: CoverageStatus
            let teamDiscoveryFailureDetail: String?
            switch inventoryResult.teams {
            case let .success(summaries, _):
                teamSummaries = summaries
                teamDiscoveryStatus = .complete
                teamDiscoveryFailureDetail = nil
            case let .failure(_, coverage):
                teamSummaries = []
                teamDiscoveryStatus = coverage.status
                teamDiscoveryFailureDetail = coverage.failureDetail
            }
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
                teams: teamSummaries,
                now: serverObservedAt
            )
            let roleStreamRecords = plan.streams.map { stream in
                let isUnavailableTeamStream = stream.kind == .openTeamReviewRequested
                    && teamDiscoveryStatus != .complete
                return roleDiscoveryCoverageRecord(
                    scope: synchronizationScope,
                    parentStreamID: streamID,
                    stream: stream,
                    interval: range,
                    status: isUnavailableTeamStream ? teamDiscoveryStatus : .partial,
                    lastSuccessfulAt: nil,
                    failureDetail: isUnavailableTeamStream ? teamDiscoveryFailureDetail : nil
                )
            }
            try await saveCoverage(
                roleStreamRecords,
                attemptedAt: attemptedAt,
                vault: vault,
                scope: synchronizationScope
            )
            let executableStreams = plan.streams.filter {
                $0.kind != .openTeamReviewRequested || teamDiscoveryStatus == .complete
            }
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let discoveryResult = try await RoleDiscoverySynchronizer(
                searchClient: searchClient,
                workItemRepository: WorkItemRepository(vault: vault),
                shardRepository: SyncShardRepository(vault: vault),
                replayRepository: RoleSearchPageReplayRepository(vault: vault)
            ).synchronize(
                plan: plan,
                scope: synchronizationScope,
                githubOrganizationID: organization.githubOrganizationID,
                streamID: streamID,
                searchRange: range,
                accessibleRepositoryNames: inventory.map(\.fullName),
                repositoryID: { repositoryIDsByAPIURL[$0.repositoryURL] },
                streams: executableStreams,
                recordStreamOutcome: { stream, outcome in
                    try await self.saveCoverage(
                        self.roleDiscoveryCoverageRecord(
                            scope: synchronizationScope,
                            parentStreamID: streamID,
                            stream: stream,
                            interval: range,
                            status: outcome.status,
                            lastSuccessfulAt: outcome.status == .complete ? serverObservedAt : nil,
                            failureDetail: outcome.failureDetail
                        ),
                        attemptedAt: attemptedAt,
                        vault: vault,
                        scope: synchronizationScope
                    )
                }
            )
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let aggregateRoleStatus = teamDiscoveryStatus == .complete
                ? CoverageStatus.complete
                : teamDiscoveryStatus
            try await saveCoverage(
                coverageRecord(
                    scope: synchronizationScope,
                    streamID: streamID,
                    interval: range,
                    status: aggregateRoleStatus,
                    lastSuccessfulAt: aggregateRoleStatus == .complete ? serverObservedAt : nil,
                    failureDetail: teamDiscoveryFailureDetail
                ),
                attemptedAt: attemptedAt,
                vault: vault,
                scope: synchronizationScope
            )
            roleDiscoveryCompleted = true
            let graphqlClient = GitHubGraphQLClient(
                credential: token,
                rateLimitController: rateLimitController,
                requestPriority: requestPriority
            )
            try await validateCurrentScope(synchronizationScope, vault: vault)
            try await refreshHydration(
                graphqlClient: graphqlClient,
                vault: vault,
                scope: synchronizationScope,
                organization: organization,
                nodeIDs: discoveryResult.candidateNodeIDs,
                attemptedAt: attemptedAt,
                repositoryID: { repository in
                    repositoryIDsByNodeID[repository.id]
                }
            )
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let contextService = try OrganizationContextRefreshService(
                vault: vault,
                graphQLClient: graphqlClient,
                selectionPolicy: .policy(for: reconciliationIntent)
            )
            let contextOutcome = try await contextService.refresh(
                scope: synchronizationScope,
                organization: organization,
                repositories: inventory,
                reconciliationIntent: reconciliationIntent,
                observedAt: serverObservedAt
            )
            try await validateCurrentScope(synchronizationScope, vault: vault)
            contextRecovery = contextOutcome.recovery
            deferredSSORequirement = GitHubSSOHeader.combined([
                deferredSSORequirement,
                contextRecovery.ssoRequirement?.scoped(to: organization.githubOrganizationID)
            ])
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let timelineSSORequirement = try await refreshTimelines(
                restClient: restClient,
                vault: vault,
                scope: synchronizationScope,
                organization: organization,
                repositoryIDs: inventory.map(\.id),
                currentUserNodeID: account.nodeID,
                attemptedAt: attemptedAt
            )
            try await validateCurrentScope(synchronizationScope, vault: vault)
            deferredSSORequirement = GitHubSSOHeader.combined([
                deferredSSORequirement,
                timelineSSORequirement
            ])
            try await validateCurrentScope(synchronizationScope, vault: vault)
            try await refreshPullRequestReviews(
                restClient: restClient,
                vault: vault,
                scope: synchronizationScope,
                organization: organization,
                attemptedAt: attemptedAt
            )
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let reviewThreadSSORequirement = try await refreshPullRequestReviewThreads(
                graphqlClient: graphqlClient,
                vault: vault,
                scope: synchronizationScope,
                organization: organization,
                currentUserNodeID: account.nodeID,
                attemptedAt: attemptedAt
            )
            try await validateCurrentScope(synchronizationScope, vault: vault)
            deferredSSORequirement = GitHubSSOHeader.combined([
                deferredSSORequirement,
                reviewThreadSSORequirement
            ])
            refreshedWorkItemIDs = discoveryResult.workItemIDs
        } catch let failure as GitHubFailure {
            try await validateCurrentScope(synchronizationScope, vault: vault)
            if let ssoHeader = failure.ssoHeader?.scoped(to: organization.githubOrganizationID) {
                if !roleDiscoveryCompleted {
                    try await saveCoverage(
                        coverageRecord(
                            scope: synchronizationScope,
                            streamID: streamID,
                            interval: searchRange,
                            status: .requiresSSO,
                            lastSuccessfulAt: nil,
                            failureDetail: "GitHub organization SSO authorization is required."
                        ),
                        attemptedAt: attemptedAt,
                        vault: vault,
                        scope: synchronizationScope
                    )
                }
                throw OrganizationRefreshError.ssoRequirement(ssoHeader)
            }
            if !roleDiscoveryCompleted {
                try await saveCoverage(
                    coverageRecord(
                        scope: synchronizationScope,
                        streamID: streamID,
                        interval: searchRange,
                        status: .failed,
                        lastSuccessfulAt: nil,
                        failureDetail: "GitHub request failed: \(failure.kind.rawValue)."
                    ),
                    attemptedAt: attemptedAt,
                    vault: vault,
                    scope: synchronizationScope
                )
            }
            throw failure
        } catch let failure as OrganizationRefreshError {
            try await validateCurrentScope(synchronizationScope, vault: vault)
            let status: CoverageStatus = switch failure {
            case .ssoRequirement:
                .requiresSSO
            }
            if !roleDiscoveryCompleted {
                try await saveCoverage(
                    coverageRecord(
                        scope: synchronizationScope,
                        streamID: streamID,
                        interval: searchRange,
                        status: status,
                        lastSuccessfulAt: nil,
                        failureDetail: "GitHub organization SSO authorization is required."
                    ),
                    attemptedAt: attemptedAt,
                    vault: vault,
                    scope: synchronizationScope
                )
            }
            throw failure
        } catch let failure as AccountOrganizationRefreshFailure {
            try await validateCurrentScope(synchronizationScope, vault: vault)
            if !roleDiscoveryCompleted {
                try await saveCoverage(
                    coverageRecord(
                        scope: synchronizationScope,
                        streamID: streamID,
                        interval: searchRange,
                        status: coverageStatus(for: failure),
                        lastSuccessfulAt: nil,
                        failureDetail: failure.freshness.detail
                    ),
                    attemptedAt: attemptedAt,
                    vault: vault,
                    scope: synchronizationScope
                )
            }
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await validateCurrentScope(synchronizationScope, vault: vault)
            if !roleDiscoveryCompleted {
                try await saveCoverage(
                    coverageRecord(
                        scope: synchronizationScope,
                        streamID: streamID,
                        interval: searchRange,
                        status: .failed,
                        lastSuccessfulAt: nil,
                        failureDetail: "Organization work refresh did not complete."
                    ),
                    attemptedAt: attemptedAt,
                    vault: vault,
                    scope: synchronizationScope
                )
            }
            throw error
        }
        try await validateCurrentScope(synchronizationScope, vault: vault)
        let derivedOutcome = try await OrganizationRefreshCompletionCoordinator(vault: vault)
            .finalizeAfterNormalizedCommit(
                for: synchronizationScope,
                evaluatedAt: attemptedAt
            )
        try await validateCurrentScope(synchronizationScope, vault: vault)
        switch derivedOutcome {
        case .published, .partial:
            break
        case let .failed(failure):
            throw OrganizationRefreshCompletionCoordinatorError.derivedProjectionFailed(failure)
        }
        if let deferredSSORequirement {
            throw OrganizationRefreshError.ssoRequirement(deferredSSORequirement)
        }
        if contextRecovery.approvalRequired {
            throw AccountOrganizationRefreshFailure.approvalRequired(
                detail: "GitHub organization approval is required for Discussion or Projects V2 context."
            )
        }
        if contextRecovery.authenticationRequired {
            throw AccountOrganizationRefreshFailure.authenticationRequired(
                detail: "Reconnect the selected account to refresh Discussion or Projects V2 context."
            )
        }
        if contextRecovery.offline {
            throw AccountOrganizationRefreshFailure.offline(
                detail: "A network connection is required to refresh Discussion or Projects V2 context."
            )
        }
        if contextRecovery.rateLimited {
            throw AccountOrganizationRefreshFailure.rateLimited(
                retryAt: contextRecovery.rateLimitRetryAt,
                detail: "GitHub rate limiting left Discussion or Projects V2 context incomplete."
            )
        }
        if contextRecovery.failed {
            throw AccountOrganizationRefreshFailure.failed(
                detail: "GitHub did not complete one or more Discussion or Projects V2 context streams."
            )
        }
        return refreshedWorkItemIDs
    }

    private func saveCoverage(
        _ record: CoverageRecord,
        attemptedAt: Date,
        vault: AccountVault,
        scope: SynchronizationScope
    ) async throws {
        try await saveCoverage(
            [record],
            attemptedAt: attemptedAt,
            vault: vault,
            scope: scope
        )
    }

    private func saveCoverage(
        _ records: [CoverageRecord],
        attemptedAt: Date,
        vault: AccountVault,
        scope: SynchronizationScope
    ) async throws {
        guard !records.isEmpty else { return }
        try Task.checkCancellation()
        try await vault.write { database in
            try Self.validateCurrentScope(scope, in: database)
            for record in records {
                try CoverageRepository.save(
                    record,
                    attemptedAt: attemptedAt,
                    expectedAccountID: scope.accountID,
                    in: database
                )
            }
        }
        try await validateCurrentScope(scope, vault: vault)
    }

    private func validateCurrentScope(
        _ scope: SynchronizationScope,
        vault: AccountVault
    ) async throws {
        try Task.checkCancellation()
        do {
            try await vault.read { database in
                try Self.validateCurrentScope(scope, in: database)
            }
        } catch is CancellationError {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private nonisolated static func validateCurrentScope(
        _ scope: SynchronizationScope,
        in database: Database
    ) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope {
            throw CancellationError()
        } catch OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw CancellationError()
        }
    }

    private func refreshHydration(
        graphqlClient: GitHubGraphQLClient,
        vault: AccountVault,
        scope: SynchronizationScope,
        organization: GitHubOrganization,
        nodeIDs: Set<GitHubNodeID>,
        attemptedAt: Date,
        repositoryID: @escaping @Sendable (GitHubNodeHydrationPayload.Repository) -> RepositoryID?
    ) async throws {
        let detailsRepository = GitHubNodeDetailsRepository(vault: vault)
        try await validateCurrentScope(scope, vault: vault)
        let candidates = try await detailsRepository.hydrationCandidates(
            nodeIDs: nodeIDs,
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
        try await validateCurrentScope(scope, vault: vault)
        let kinds: [GitHubContentKind] = [.issue, .pullRequest]
        let initialRecords = kinds.flatMap { kind -> [CoverageRecord] in
            let repositoryIDs = Set(
                candidates.filter { $0.kind == kind }.map(\.repositoryID)
            ).sorted { $0.rawValue < $1.rawValue }
            let repositoryRecords = repositoryIDs.map { repositoryID in
                hydrationCoverageRecord(
                    scope: scope,
                    organizationID: organization.id,
                    kind: kind,
                    repositoryID: repositoryID,
                    status: .partial,
                    lastSuccessfulAt: nil,
                    failureDetail: nil
                )
            }
            return repositoryRecords + [hydrationCoverageRecord(
                scope: scope,
                organizationID: organization.id,
                kind: kind,
                repositoryID: nil,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            )]
        }
        try await saveCoverage(
            initialRecords,
            attemptedAt: attemptedAt,
            vault: vault,
            scope: scope
        )

        try await validateCurrentScope(scope, vault: vault)
        let result = try await GitHubNodeHydrationService(
            client: graphqlClient,
            detailsRepository: detailsRepository,
            rawSnapshotRepository: RawAPISnapshotRepository(vault: vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: vault),
            batchMetricRepository: GitHubHydrationBatchMetricRepository(vault: vault)
        ).hydrate(
            nodeIDs: nodeIDs,
            scope: scope,
            githubOrganizationID: organization.githubOrganizationID,
            repositoryID: repositoryID
        )
        try await validateCurrentScope(scope, vault: vault)

        let finalRecords = kinds.flatMap { kind -> [CoverageRecord] in
            let repositoryIDs = Set(
                candidates.filter { $0.kind == kind }.map(\.repositoryID)
            ).sorted { $0.rawValue < $1.rawValue }
            let repositoryRecords = repositoryIDs.map { repositoryID in
                let assessment = result.coverageAssessment(repositoryID: repositoryID, kind: kind)
                return hydrationCoverageRecord(
                    scope: scope,
                    organizationID: organization.id,
                    kind: kind,
                    repositoryID: repositoryID,
                    status: assessment.status,
                    lastSuccessfulAt: assessment.status == .complete ? attemptedAt : nil,
                    failureDetail: assessment.failureDetail
                )
            }
            let aggregate = result.coverageAssessment(kind: kind)
            return repositoryRecords + [hydrationCoverageRecord(
                scope: scope,
                organizationID: organization.id,
                kind: kind,
                repositoryID: nil,
                status: aggregate.status,
                lastSuccessfulAt: aggregate.status == .complete ? attemptedAt : nil,
                failureDetail: aggregate.failureDetail
            )]
        }
        try await saveCoverage(
            finalRecords,
            attemptedAt: attemptedAt,
            vault: vault,
            scope: scope
        )
        guard !result.isComplete else { return }

        let statuses = result.outcomes.map(\.status)
        if let header = statuses.compactMap({ status -> GitHubSSOHeader? in
            guard case let .ssoRequired(header) = status else { return nil }
            return header
        }).first {
            throw OrganizationRefreshError.ssoRequirement(header)
        }
        if statuses.contains(.approvalRequired) {
            throw AccountOrganizationRefreshFailure.approvalRequired(
                detail: "GitHub organization approval is required for current issue and pull request fields."
            )
        }
        if statuses.contains(.authenticationRequired) {
            throw AccountOrganizationRefreshFailure.authenticationRequired(
                detail: "GitHub authentication is required for current issue and pull request fields."
            )
        }
        let retryDates = statuses.compactMap { status -> Date? in
            guard case let .rateLimited(retryAt) = status else { return nil }
            return retryAt
        }
        if statuses.contains(where: {
            if case .rateLimited = $0 { return true }
            return false
        }) {
            throw AccountOrganizationRefreshFailure.rateLimited(
                retryAt: retryDates.max(),
                detail: "GitHub rate limiting left current issue and pull request fields incomplete."
            )
        }
        if statuses.contains(.unavailableOrPermission) {
            throw AccountOrganizationRefreshFailure.unavailable(
                detail: "Some current issue and pull request fields are unavailable to this account."
            )
        }
        throw AccountOrganizationRefreshFailure.failed(
            detail: "Current issue and pull request field hydration is incomplete."
        )
    }

    private func hydrationCoverageRecord(
        scope: SynchronizationScope,
        organizationID: OrganizationID,
        kind: GitHubContentKind,
        repositoryID: RepositoryID?,
        status: CoverageStatus,
        lastSuccessfulAt: Date?,
        failureDetail: String?
    ) -> CoverageRecord {
        let feature: CoverageFeature = kind == .issue ? .issues : .pullRequests
        let kindComponent = kind == .issue ? "issues" : "pull-requests"
        let repositoryComponent = repositoryID.map { "-\($0.rawValue)" } ?? ""
        return coverageRecord(
            scope: scope,
            streamID: SyncStreamID(
                rawValue: "hydration-\(kindComponent)-\(organizationID.rawValue)\(repositoryComponent)"
            )!,
            interval: nil,
            status: status,
            lastSuccessfulAt: lastSuccessfulAt,
            failureDetail: failureDetail,
            feature: feature,
            repositoryID: repositoryID
        )
    }

    private func roleDiscoveryCoverageRecord(
        scope: SynchronizationScope,
        parentStreamID: SyncStreamID,
        stream: RoleDiscoveryStream,
        interval: SearchTimeRange,
        status: CoverageStatus,
        lastSuccessfulAt: Date?,
        failureDetail: String?
    ) -> CoverageRecord {
        coverageRecord(
            scope: scope,
            streamID: stream.streamID(parent: parentStreamID),
            interval: interval,
            status: status,
            lastSuccessfulAt: lastSuccessfulAt,
            failureDetail: failureDetail
        )
    }

    private func coverageRecord(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        interval: SearchTimeRange?,
        status: CoverageStatus,
        lastSuccessfulAt: Date?,
        failureDetail: String?,
        feature: CoverageFeature = .roleDiscovery,
        repositoryID: RepositoryID? = nil
    ) -> CoverageRecord {
        CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: repositoryID,
            feature: feature,
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

    private func requiredRepositoryInventoryFailure(
        _ failure: OrganizationInventoryRefreshFailure
    ) -> any Error {
        switch failure {
        case let .ssoRequired(header):
            OrganizationRefreshError.ssoRequirement(header)
        case .approvalRequired:
            AccountOrganizationRefreshFailure.approvalRequired(
                detail: "GitHub organization approval is required for repository inventory."
            )
        case .authenticationRequired:
            AccountOrganizationRefreshFailure.authenticationRequired(
                detail: "GitHub authentication is required for repository inventory."
            )
        case let .rateLimited(retryAt):
            AccountOrganizationRefreshFailure.rateLimited(
                retryAt: retryAt,
                detail: "GitHub rate limiting left repository inventory incomplete."
            )
        case .unavailableOrPermission:
            AccountOrganizationRefreshFailure.unavailable(
                detail: "Repository inventory is unavailable to the selected account."
            )
        case .partial:
            AccountOrganizationRefreshFailure.unavailable(
                detail: "Repository inventory is partial and cannot safely scope role discovery."
            )
        case .failed:
            AccountOrganizationRefreshFailure.failed(
                detail: "Repository inventory could not be refreshed."
            )
        }
    }

    private func coverageStatus(
        for failure: AccountOrganizationRefreshFailure
    ) -> CoverageStatus {
        switch failure {
        case .ssoRequired:
            .requiresSSO
        case .approvalRequired:
            .requiresApproval
        case .unavailable:
            .unavailable
        case .rateLimited:
            .partial
        case .offline, .authenticationRequired, .failed:
            .failed
        }
    }

    private nonisolated static func coverageStatus(
        for failure: ReviewCandidateFailureClassification
    ) -> CoverageStatus {
        switch failure {
        case .ssoRequired:
            .requiresSSO
        case .approvalRequired:
            .requiresApproval
        case .unavailableOrPermission:
            .unavailable
        case .rateLimited:
            .partial
        case .authenticationRequired, .transportFailure, .serverFailure, .malformedResponse, .normalizationFailure:
            .failed
        }
    }

    private nonisolated static func reviewFailureSeverity(
        _ failure: ReviewCandidateFailureClassification
    ) -> Int {
        switch coverageStatus(for: failure) {
        case .complete: 0
        case .unavailable: 1
        case .unknown: 2
        case .partial: 3
        case .failed: 4
        case .requiresApproval: 5
        case .requiresSSO: 6
        }
    }

    private nonisolated static func reviewFailureDetail(
        for failure: ReviewCandidateFailureClassification
    ) -> String {
        switch failure {
        case .authenticationRequired:
            "Reconnect the selected account to refresh pull request reviews."
        case .ssoRequired:
            "GitHub organization SSO authorization is required for pull request reviews."
        case .approvalRequired:
            "GitHub organization approval is required for pull request reviews."
        case .rateLimited:
            "GitHub rate limiting left pull request review coverage incomplete."
        case .unavailableOrPermission:
            "Some pull request reviews are unavailable to the selected account."
        case .transportFailure:
            "A transport failure left pull request review coverage incomplete."
        case .serverFailure:
            "GitHub did not complete pull request review coverage."
        case .malformedResponse:
            "GitHub returned malformed pull request review data."
        case .normalizationFailure:
            "GitHub pull request review data could not be normalized."
        }
    }

    private func refreshTimelines(
        restClient: GitHubRESTClient,
        vault: AccountVault,
        scope: SynchronizationScope,
        organization: GitHubOrganization,
        repositoryIDs requestedRepositoryIDs: [RepositoryID],
        currentUserNodeID: GitHubNodeID,
        attemptedAt: Date
    ) async throws -> GitHubSSOHeader? {
        let aggregateStreamID = SyncStreamID(rawValue: "timelines-\(organization.id.rawValue)")!
        let repositoryIDs = Set(requestedRepositoryIDs).sorted { $0.rawValue < $1.rawValue }
        let initialRepositoryRecords = repositoryIDs.map { repositoryID in
            coverageRecord(
                scope: scope,
                streamID: SyncStreamID(
                    rawValue: "timelines-\(organization.id.rawValue)-\(repositoryID.rawValue)"
                )!,
                interval: nil,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil,
                feature: .timelines,
                repositoryID: repositoryID
            )
        }
        let initialAggregateRecord = coverageRecord(
            scope: scope,
            streamID: aggregateStreamID,
            interval: nil,
            status: .partial,
            lastSuccessfulAt: nil,
            failureDetail: nil,
            feature: .timelines
        )
        let initialRecords = initialRepositoryRecords + [initialAggregateRecord]
        try await saveCoverage(
            initialRecords,
            attemptedAt: attemptedAt,
            vault: vault,
            scope: scope
        )
        do {
            try await validateCurrentScope(scope, vault: vault)
            let result = try await GitHubTimelineRefreshService(
                client: GitHubTimelineClient(client: restClient),
                candidateRepository: TimelineCandidateRepository(vault: vault),
                eventRepository: TimelineEventRepository(vault: vault),
                normalizationFailureRepository: NormalizationFailureRepository(vault: vault),
                conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: vault)
            ).refresh(
                scope: scope,
                githubOrganizationID: organization.githubOrganizationID,
                currentUserID: ActorID(rawValue: currentUserNodeID.rawValue)!,
                observedAt: attemptedAt
            )
            try await validateCurrentScope(scope, vault: vault)
            let repositoryRecords = repositoryIDs.map { repositoryID in
                let assessment = result.coverageAssessment(for: repositoryID)
                return coverageRecord(
                    scope: scope,
                    streamID: SyncStreamID(
                        rawValue: "timelines-\(organization.id.rawValue)-\(repositoryID.rawValue)"
                    )!,
                    interval: nil,
                    status: assessment.status,
                    lastSuccessfulAt: assessment.status == .complete ? attemptedAt : nil,
                    failureDetail: assessment.failureDetail,
                    feature: .timelines,
                    repositoryID: repositoryID
                )
            }
            let aggregateAssessment = result.coverageAssessment
            let aggregateRecord = coverageRecord(
                scope: scope,
                streamID: aggregateStreamID,
                interval: nil,
                status: aggregateAssessment.status,
                lastSuccessfulAt: aggregateAssessment.status == .complete ? attemptedAt : nil,
                failureDetail: aggregateAssessment.failureDetail,
                feature: .timelines
            )
            let records = repositoryRecords + [aggregateRecord]
            try await saveCoverage(
                records,
                attemptedAt: attemptedAt,
                vault: vault,
                scope: scope
            )
            return result.ssoHeader
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await validateCurrentScope(scope, vault: vault)
            try await saveCoverage(
                coverageRecord(
                    scope: scope,
                    streamID: aggregateStreamID,
                    interval: nil,
                    status: .failed,
                    lastSuccessfulAt: nil,
                    failureDetail: "Timeline refresh did not complete.",
                    feature: .timelines
                ),
                attemptedAt: attemptedAt,
                vault: vault,
                scope: scope
            )
            return nil
        }
    }

    /// Notifications are account-scoped, read-only discovery evidence. The
    /// selected organization only receives a filtered local view after the
    /// repository inventory has established its current scope.
    private func refreshNotifications(
        restClient: GitHubRESTClient,
        vault: AccountVault,
        scope: SynchronizationScope,
        organization: GitHubOrganization,
        capabilityStatus: CapabilityStatus,
        attemptedAt: Date
    ) async throws {
        let streamID = SyncStreamID(rawValue: "notifications-\(organization.id.rawValue)")!
        guard capabilityStatus == .available else {
            let status: CoverageStatus = switch capabilityStatus {
            case .available:
                .complete
            case .unavailable, .notApplicable:
                .unavailable
            case .unknown:
                .unknown
            case .requiresSSO:
                .requiresSSO
            case .requiresApproval:
                .requiresApproval
            }
            let detail: String = switch capabilityStatus {
            case .unavailable, .notApplicable:
                "GitHub notifications are unavailable to the selected account."
            case .unknown:
                "GitHub notification capability has not been established for the selected account."
            case .requiresSSO:
                "GitHub SSO authorization is required before notifications can refresh."
            case .requiresApproval:
                "GitHub organization approval is required before notifications can refresh."
            case .available:
                ""
            }
            try await saveCoverage(
                coverageRecord(
                    scope: scope,
                    streamID: streamID,
                    interval: nil,
                    status: status,
                    lastSuccessfulAt: nil,
                    failureDetail: detail,
                    feature: .notifications
                ),
                attemptedAt: attemptedAt,
                vault: vault,
                scope: scope
            )
            return
        }
        try await validateCurrentScope(scope, vault: vault)
        let previousHighWater = try await SyncStreamRepository(vault: vault)
            .stream(withID: streamID, accountID: scope.accountID)?
            .highWater
        try await validateCurrentScope(scope, vault: vault)
        _ = try await GitHubNotificationSynchronizationService(
            client: GitHubNotificationClient(client: restClient),
            repository: GitHubNotificationSourceRepository(vault: vault)
        ).refresh(
            scope: scope,
            organizationLogin: organization.login,
            streamID: streamID,
            previousHighWater: previousHighWater,
            observedAt: attemptedAt
        )
        try await validateCurrentScope(scope, vault: vault)
    }

    private func refreshPullRequestReviews(
        restClient: GitHubRESTClient,
        vault: AccountVault,
        scope: SynchronizationScope,
        organization: GitHubOrganization,
        attemptedAt: Date
    ) async throws {
        let streamID = SyncStreamID(rawValue: "pull-request-reviews-\(organization.id.rawValue)")!
        try await saveCoverage(
            coverageRecord(
                scope: scope,
                streamID: streamID,
                interval: nil,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil,
                feature: .reviews
            ),
            attemptedAt: attemptedAt,
            vault: vault,
            scope: scope
        )
        do {
            try await validateCurrentScope(scope, vault: vault)
            let result = try await PullRequestReviewRefreshService(
                client: GitHubPullRequestClient(client: restClient),
                candidateRepository: PullRequestReviewCandidateRepository(vault: vault),
                failureEnvelopeRepository: ReviewCandidateFailureEnvelopeRepository(vault: vault)
            ).refresh(
                scope: scope,
                githubOrganizationID: organization.githubOrganizationID,
                streamID: streamID
            )
            try await validateCurrentScope(scope, vault: vault)
            let scopedSSOHeader = result.ssoHeader?.scoped(to: organization.githubOrganizationID)
            let classifiedFailure = result.failureClassifications.max { lhs, rhs in
                Self.reviewFailureSeverity(lhs) < Self.reviewFailureSeverity(rhs)
            }
            let status: CoverageStatus = if let classifiedFailure {
                Self.coverageStatus(for: classifiedFailure)
            } else if scopedSSOHeader != nil {
                .requiresSSO
            } else if result.hasBlockedKnownCandidates {
                .unavailable
            } else if result.hasUncorroboratedRequestedReviewers {
                .partial
            } else if result.hasRemainingCandidates {
                .partial
            } else {
                .complete
            }
            let failureDetail: String? = if let classifiedFailure {
                Self.reviewFailureDetail(for: classifiedFailure)
            } else if scopedSSOHeader != nil {
                "GitHub returned partial pull request review results due to SSO."
            } else if result.hasBlockedKnownCandidates {
                "Some known pull requests are no longer accessible to the selected account. Restore repository access or refresh the repository inventory."
            } else if result.hasUncorroboratedRequestedReviewers {
                "Requested-reviewer sources did not corroborate the current pull request revision. Existing review data was retained."
            } else if result.hasRemainingCandidates {
                "Additional pull request review candidates remain for the next refresh."
            } else {
                nil
            }
            try await saveCoverage(
                coverageRecord(
                    scope: scope,
                    streamID: streamID,
                    interval: nil,
                    status: status,
                    lastSuccessfulAt: status == .complete ? Date() : nil,
                    failureDetail: failureDetail,
                    feature: .reviews
                ),
                attemptedAt: attemptedAt,
                vault: vault,
                scope: scope
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as GitHubFailure {
            try await validateCurrentScope(scope, vault: vault)
            let status: CoverageStatus = failure.ssoHeader?.scoped(to: organization.githubOrganizationID) == nil
                ? .failed
                : .requiresSSO
            try await saveCoverage(
                coverageRecord(
                    scope: scope,
                    streamID: streamID,
                    interval: nil,
                    status: status,
                    lastSuccessfulAt: nil,
                    failureDetail: status == .requiresSSO
                        ? "GitHub organization SSO authorization is required for pull request reviews."
                        : "GitHub pull request review request failed: \(failure.kind.rawValue).",
                    feature: .reviews
                ),
                attemptedAt: attemptedAt,
                vault: vault,
                scope: scope
            )
        } catch {
            try await validateCurrentScope(scope, vault: vault)
            try await saveCoverage(
                coverageRecord(
                    scope: scope,
                    streamID: streamID,
                    interval: nil,
                    status: .failed,
                    lastSuccessfulAt: nil,
                    failureDetail: "Pull request review refresh did not complete.",
                    feature: .reviews
                ),
                attemptedAt: attemptedAt,
                vault: vault,
                scope: scope
            )
        }
    }

    private func refreshPullRequestReviewThreads(
        graphqlClient: GitHubGraphQLClient,
        vault: AccountVault,
        scope: SynchronizationScope,
        organization: GitHubOrganization,
        currentUserNodeID: GitHubNodeID,
        attemptedAt: Date
    ) async throws -> GitHubSSOHeader? {
        let streamID = SyncStreamID(rawValue: "pull-request-review-threads-\(organization.id.rawValue)")!
        try await saveCoverage(
            coverageRecord(
                scope: scope,
                streamID: streamID,
                interval: nil,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil,
                feature: .reviewThreads
            ),
            attemptedAt: attemptedAt,
            vault: vault,
            scope: scope
        )
        do {
            try await validateCurrentScope(scope, vault: vault)
            let result = try await PullRequestReviewThreadRefreshService(
                fetcher: GitHubPullRequestReviewThreadClient(client: graphqlClient),
                candidateRepository: PullRequestReviewCandidateRepository(vault: vault),
                threadRepository: PullRequestReviewThreadRepository(vault: vault),
                currentUserNodeID: currentUserNodeID,
                failureEnvelopeRepository: ReviewCandidateFailureEnvelopeRepository(vault: vault)
            ).refresh(
                scope: scope,
                githubOrganizationID: organization.githubOrganizationID,
                observedAt: attemptedAt,
                streamID: streamID
            )
            try await validateCurrentScope(scope, vault: vault)
            let assessment = result.coverageAssessment
            try await saveCoverage(
                coverageRecord(
                    scope: scope,
                    streamID: streamID,
                    interval: nil,
                    status: assessment.status,
                    lastSuccessfulAt: assessment.status == .complete ? Date() : nil,
                    failureDetail: assessment.failureDetail,
                    feature: .reviewThreads
                ),
                attemptedAt: attemptedAt,
                vault: vault,
                scope: scope
            )
            return result.ssoRequirement
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await validateCurrentScope(scope, vault: vault)
            try await saveCoverage(
                coverageRecord(
                    scope: scope,
                    streamID: streamID,
                    interval: nil,
                    status: .failed,
                    lastSuccessfulAt: nil,
                    failureDetail: "Pull request review-thread refresh did not complete.",
                    feature: .reviewThreads
                ),
                attemptedAt: attemptedAt,
                vault: vault,
                scope: scope
            )
            return nil
        }
    }
}
