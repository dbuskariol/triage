import Foundation
import GRDB

struct OrganizationContextSelectionPolicy: Equatable, Sendable {
    let maximumDiscussionRepositories: Int
    let maximumProjects: Int

    init(maximumDiscussionRepositories: Int, maximumProjects: Int) {
        self.maximumDiscussionRepositories = max(1, maximumDiscussionRepositories)
        self.maximumProjects = max(1, maximumProjects)
    }

    static func policy(for reconciliationIntent: SynchronizationReconciliationIntent) -> Self {
        if reconciliationIntent == .fullReconciliation {
            // Full reconciliation widens the bounded candidate window; it does
            // not create an unbounded in-memory queue. Repeated reconciliations
            // rotate oldest/unattempted candidates until the inventory drains.
            return .init(maximumDiscussionRepositories: 100, maximumProjects: 50)
        }
        return .init(maximumDiscussionRepositories: 25, maximumProjects: 25)
    }
}

struct OrganizationContextRecovery: Equatable, Sendable {
    var ssoRequirement: GitHubSSOHeader?
    var approvalRequired = false
    var authenticationRequired = false
    var offline = false
    var rateLimited = false
    var rateLimitRetryAt: Date?
    var failed = false

    var isEmpty: Bool {
        ssoRequirement == nil
            && !approvalRequired
            && !authenticationRequired
            && !offline
            && !rateLimited
            && rateLimitRetryAt == nil
            && !failed
    }
}

struct OrganizationContextRefreshOutcome: Sendable {
    let discussionCoverage: CoverageRecord
    let projectCoverage: CoverageRecord?
    let projectItemCoverage: CoverageRecord
    let recovery: OrganizationContextRecovery
}

enum OrganizationContextRefreshServiceError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case discussionCommentsRefreshUnavailable
    case invalidPersistedDiscussionCandidate
}

/// Coordinates the repository-scoped Discussion and organization-scoped
/// Projects V2 sources without allowing one source failure to erase or
/// misrepresent another source's durable state.
actor OrganizationContextRefreshService {
    typealias DiscussionRefresh = @Sendable (
        SynchronizationScope,
        GitHubOrganization,
        RepositorySummary,
        SyncStreamID,
        Date?,
        Date
    ) async throws -> CoverageRecord

    typealias ProjectInventoryRefresh = @Sendable (
        SynchronizationScope,
        GitHubOrganization,
        SyncStreamID,
        Date?,
        SynchronizationReconciliationIntent,
        Date
    ) async throws -> ProjectV2SynchronizationResult

    typealias ProjectItemsRefresh = @Sendable (
        GitHubProjectV2Record,
        SynchronizationScope,
        GitHubOrganization,
        SyncStreamID,
        Date?,
        SynchronizationReconciliationIntent,
        Date
    ) async throws -> CoverageRecord

    typealias DiscussionCommentsRefresh = @Sendable (
        SynchronizationScope,
        GitHubOrganization,
        RepositorySummary,
        GitHubNodeID,
        SyncStreamID,
        SyncStreamID,
        Date?,
        Date?,
        Date
    ) async throws -> DiscussionCommentSynchronizationResult

    private static let overlap: TimeInterval = 5 * 60
    private static let maximumDiscussionCommentCandidatesPerRepository = 25
    private let vault: AccountVault
    private let selectionPolicy: OrganizationContextSelectionPolicy
    private let refreshDiscussion: DiscussionRefresh
    private let refreshProjectInventory: ProjectInventoryRefresh
    private let refreshProjectItems: ProjectItemsRefresh
    private let runDiscussionCommentsRefresh: DiscussionCommentsRefresh

    init(
        vault: AccountVault,
        graphQLClient: GitHubGraphQLClient,
        selectionPolicy: OrganizationContextSelectionPolicy
    ) throws {
        self.vault = vault
        self.selectionPolicy = selectionPolicy
        let coverage = CoverageRepository(vault: vault)
        let discussionService = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(client: graphQLClient),
            repository: DiscussionRepository(vault: vault),
            coverage: coverage
        )
        let projectService = ProjectV2SynchronizationService(
            client: GitHubProjectV2Client(client: graphQLClient),
            repository: ProjectV2Repository(vault: vault),
            coverage: coverage
        )
        let discussionCommentService = DiscussionCommentSynchronizationService(
            client: try GitHubDiscussionCommentClient(client: graphQLClient),
            repository: DiscussionCommentRepository(vault: vault)
        )
        refreshDiscussion = { scope, organization, repository, streamID, previousHighWater, observedAt in
            try await discussionService.refresh(
                scope: scope,
                organization: organization,
                repositoryID: repository.id,
                repositoryNodeID: repository.nodeID,
                streamID: streamID,
                previousHighWater: previousHighWater,
                observedAt: observedAt
            ).coverage
        }
        refreshProjectInventory = { scope, organization, streamID, previousHighWater, reconciliationIntent, observedAt in
            try await projectService.refreshProjects(
                scope: scope,
                organization: organization,
                streamID: streamID,
                previousHighWater: previousHighWater,
                reconciliationIntent: reconciliationIntent,
                observedAt: observedAt
            )
        }
        refreshProjectItems = { project, scope, organization, streamID, previousHighWater, reconciliationIntent, observedAt in
            try await projectService.refreshItems(
                project: project,
                scope: scope,
                organization: organization,
                streamID: streamID,
                previousHighWater: previousHighWater,
                reconciliationIntent: reconciliationIntent,
                observedAt: observedAt
            )
        }
        runDiscussionCommentsRefresh = { scope, organization, repository, discussionNodeID, commentStreamID, replyStreamID, commentHighWater, replyHighWater, observedAt in
            try await discussionCommentService.refresh(
                discussionNodeID: discussionNodeID,
                scope: scope,
                organization: organization,
                repositoryID: repository.id,
                commentStreamID: commentStreamID,
                replyStreamID: replyStreamID,
                previousCommentHighWater: commentHighWater,
                previousReplyHighWater: replyHighWater,
                observedAt: observedAt
            )
        }
    }

    init(
        vault: AccountVault,
        selectionPolicy: OrganizationContextSelectionPolicy,
        refreshDiscussion: @escaping DiscussionRefresh,
        refreshProjectInventory: @escaping ProjectInventoryRefresh,
        refreshProjectItems: @escaping ProjectItemsRefresh,
        refreshDiscussionComments: @escaping DiscussionCommentsRefresh = { _, _, _, _, _, _, _, _, _ in
            throw OrganizationContextRefreshServiceError.discussionCommentsRefreshUnavailable
        }
    ) {
        self.vault = vault
        self.selectionPolicy = selectionPolicy
        self.refreshDiscussion = refreshDiscussion
        self.refreshProjectInventory = refreshProjectInventory
        self.refreshProjectItems = refreshProjectItems
        self.runDiscussionCommentsRefresh = refreshDiscussionComments
    }

    func refresh(
        scope: SynchronizationScope,
        organization: GitHubOrganization,
        repositories: [RepositorySummary],
        reconciliationIntent: SynchronizationReconciliationIntent = .incremental,
        observedAt: Date
    ) async throws -> OrganizationContextRefreshOutcome {
        guard scope.accountID == vault.accountID,
              scope.organizationID == organization.id
        else {
            throw OrganizationContextRefreshServiceError.accountScopeMismatch
        }
        try await validateCurrentScope(scope)
        let streams = try await SyncStreamRepository(vault: vault).streams(
            for: scope.accountID,
            organizationID: scope.organizationID
        )
        try await validateCurrentScope(scope)
        let streamsByID = Dictionary(uniqueKeysWithValues: streams.map { ($0.id, $0) })
        var recovery = OrganizationContextRecovery()
        let discussionCoverage = try await refreshDiscussions(
            scope: scope,
            organization: organization,
            repositories: repositories,
            observedAt: observedAt,
            streamsByID: streamsByID,
            recovery: &recovery
        )
        try await validateCurrentScope(scope)
        let projects = try await refreshProjects(
            scope: scope,
            organization: organization,
            observedAt: observedAt,
            streamsByID: streamsByID,
            reconciliationIntent: reconciliationIntent,
            recovery: &recovery
        )
        return .init(
            discussionCoverage: discussionCoverage,
            projectCoverage: projects.projectCoverage,
            projectItemCoverage: projects.itemCoverage,
            recovery: recovery
        )
    }

    private func refreshDiscussions(
        scope: SynchronizationScope,
        organization: GitHubOrganization,
        repositories: [RepositorySummary],
        observedAt: Date,
        streamsByID: [SyncStreamID: SyncStream],
        recovery: inout OrganizationContextRecovery
    ) async throws -> CoverageRecord {
        let orderedRepositories = repositories.sorted { lhs, rhs in
            if lhs.fullName != rhs.fullName { return lhs.fullName < rhs.fullName }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        var preliminaryCoverage = [CoverageRecord]()
        var metadataStatuses = [CoverageStatus]()
        var commentStatuses = [CoverageStatus]()
        var replyStatuses = [CoverageStatus]()
        var eligible = [RepositorySummary]()
        for repository in orderedRepositories {
            let metadataStreamID = Self.discussionStreamID(
                organizationID: organization.id,
                repositoryID: repository.id
            )
            if !repository.hasDiscussionsKnown {
                metadataStatuses.append(.unknown)
                commentStatuses.append(.unknown)
                replyStatuses.append(.unknown)
                preliminaryCoverage.append(makeCoverage(
                    scope: scope,
                    repositoryID: repository.id,
                    feature: .discussions,
                    streamID: metadataStreamID,
                    previousHighWater: streamsByID[metadataStreamID]?.highWater,
                    observedAt: observedAt,
                    status: .unknown,
                    detail: "GitHub did not report whether Discussions are enabled for this repository."
                ))
            } else if !repository.hasDiscussions {
                metadataStatuses.append(.unavailable)
                commentStatuses.append(.unavailable)
                replyStatuses.append(.unavailable)
                preliminaryCoverage.append(makeCoverage(
                    scope: scope,
                    repositoryID: repository.id,
                    feature: .discussions,
                    streamID: metadataStreamID,
                    previousHighWater: streamsByID[metadataStreamID]?.highWater,
                    observedAt: observedAt,
                    status: .unavailable,
                    detail: "Discussions are not enabled for this repository."
                ))
            } else {
                eligible.append(repository)
            }
            if !repository.hasDiscussionsKnown || !repository.hasDiscussions {
                preliminaryCoverage.append(contentsOf: nestedDiscussionPrerequisiteCoverage(
                    scope: scope,
                    repositoryID: repository.id,
                    observedAt: observedAt,
                    streamsByID: streamsByID,
                    status: repository.hasDiscussionsKnown ? .unavailable : .unknown,
                    detail: repository.hasDiscussionsKnown
                        ? "Discussions are not enabled for this repository."
                        : "GitHub did not report whether Discussions are enabled for this repository."
                ))
            }
        }
        try await saveCoverage(preliminaryCoverage, scope: scope, attemptedAt: observedAt)

        eligible.sort {
            Self.candidatePrecedes(
                lhsID: $0.id.rawValue,
                lhsAttempt: streamsByID[Self.discussionStreamID(
                    organizationID: organization.id,
                    repositoryID: $0.id
                )]?.lastAttemptAt,
                rhsID: $1.id.rawValue,
                rhsAttempt: streamsByID[Self.discussionStreamID(
                    organizationID: organization.id,
                    repositoryID: $1.id
                )]?.lastAttemptAt
            )
        }
        let selected = Array(eligible.prefix(selectionPolicy.maximumDiscussionRepositories))
        let deferredCount = eligible.count - selected.count
        for repository in selected {
            try await validateCurrentScope(scope)
            let streamID = Self.discussionStreamID(
                organizationID: organization.id,
                repositoryID: repository.id
            )
            do {
                let coverage = try await refreshDiscussion(
                    scope,
                    organization,
                    repository,
                    streamID,
                    streamsByID[streamID]?.highWater,
                    observedAt
                )
                try await validateCurrentScope(scope)
                metadataStatuses.append(coverage.status)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await validateCurrentScope(scope)
                if Self.isTransportCancellation(error) { throw CancellationError() }
                guard Self.isExpectedSourceError(error) else { throw error }
                metadataStatuses.append(Self.coverageStatus(for: error))
                Self.recordRecovery(from: error, observedAt: observedAt, into: &recovery)
                commentStatuses.append(.partial)
                replyStatuses.append(.partial)
                continue
            }
            do {
                let nested = try await refreshDiscussionComments(
                    scope: scope,
                    organization: organization,
                    repository: repository,
                    observedAt: observedAt,
                    streamsByID: streamsByID,
                    recovery: &recovery
                )
                try await validateCurrentScope(scope)
                commentStatuses.append(nested.comment)
                replyStatuses.append(nested.reply)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await validateCurrentScope(scope)
                if Self.isTransportCancellation(error) { throw CancellationError() }
                guard Self.isExpectedSourceError(error) else { throw error }
                let status = Self.coverageStatus(for: error)
                let source = Self.discussionCommentSource(for: error)
                commentStatuses.append(source == .comments ? status : .partial)
                replyStatuses.append(source == .replies ? status : .partial)
                Self.recordRecovery(from: error, observedAt: observedAt, into: &recovery)
            }
        }
        if deferredCount > 0 {
            metadataStatuses.append(.partial)
            commentStatuses.append(.partial)
            replyStatuses.append(.partial)
        }
        let aggregateStatus = Self.aggregateStatus(metadataStatuses)
        let aggregateStreamID = Self.discussionAggregateStreamID(organizationID: organization.id)
        let aggregate = makeCoverage(
            scope: scope,
            repositoryID: nil,
            feature: .discussions,
            streamID: aggregateStreamID,
            previousHighWater: streamsByID[aggregateStreamID]?.highWater,
            observedAt: observedAt,
            status: aggregateStatus,
            detail: Self.aggregateDetail(
                feature: "Discussion",
                status: aggregateStatus,
                deferredCount: deferredCount
            )
        )
        let commentsAggregate = makeCoverage(
            scope: scope,
            repositoryID: nil,
            feature: .discussionComments,
            streamID: Self.discussionCommentsAggregateStreamID(organizationID: organization.id),
            previousHighWater: streamsByID[Self.discussionCommentsAggregateStreamID(
                organizationID: organization.id
            )]?.highWater,
            observedAt: observedAt,
            status: Self.aggregateStatus(commentStatuses),
            detail: Self.aggregateDetail(
                feature: "Discussion comment",
                status: Self.aggregateStatus(commentStatuses),
                deferredCount: deferredCount
            )
        )
        let repliesAggregate = makeCoverage(
            scope: scope,
            repositoryID: nil,
            feature: .discussionReplies,
            streamID: Self.discussionRepliesAggregateStreamID(organizationID: organization.id),
            previousHighWater: streamsByID[Self.discussionRepliesAggregateStreamID(
                organizationID: organization.id
            )]?.highWater,
            observedAt: observedAt,
            status: Self.aggregateStatus(replyStatuses),
            detail: Self.aggregateDetail(
                feature: "Discussion reply",
                status: Self.aggregateStatus(replyStatuses),
                deferredCount: deferredCount
            )
        )
        try await saveCoverage(
            [aggregate, commentsAggregate, repliesAggregate],
            scope: scope,
            attemptedAt: observedAt
        )
        return aggregate
    }

    private func refreshProjects(
        scope: SynchronizationScope,
        organization: GitHubOrganization,
        observedAt: Date,
        streamsByID: [SyncStreamID: SyncStream],
        reconciliationIntent: SynchronizationReconciliationIntent,
        recovery: inout OrganizationContextRecovery
    ) async throws -> (projectCoverage: CoverageRecord?, itemCoverage: CoverageRecord) {
        let inventoryStreamID = Self.projectInventoryStreamID(organizationID: organization.id)
        let inventory: ProjectV2SynchronizationResult
        do {
            try await validateCurrentScope(scope)
            inventory = try await refreshProjectInventory(
                scope,
                organization,
                inventoryStreamID,
                streamsByID[inventoryStreamID]?.highWater,
                reconciliationIntent,
                observedAt
            )
            try await validateCurrentScope(scope)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await validateCurrentScope(scope)
            if Self.isTransportCancellation(error) { throw CancellationError() }
            guard Self.isExpectedSourceError(error) else { throw error }
            Self.recordRecovery(from: error, observedAt: observedAt, into: &recovery)
            let status = Self.coverageStatus(for: error)
            let aggregate = makeCoverage(
                scope: scope,
                repositoryID: nil,
                feature: .projectItems,
                streamID: Self.projectItemsAggregateStreamID(organizationID: organization.id),
                previousHighWater: streamsByID[Self.projectItemsAggregateStreamID(
                    organizationID: organization.id
                )]?.highWater,
                observedAt: observedAt,
                status: status,
                detail: "Project items could not be planned because Projects V2 inventory did not complete."
            )
            try await saveCoverage([aggregate], scope: scope, attemptedAt: observedAt)
            return (nil, aggregate)
        }

        var projects = inventory.projects
        projects.sort {
            Self.candidatePrecedes(
                lhsID: $0.nodeID.rawValue,
                lhsAttempt: streamsByID[Self.projectItemsStreamID(
                    organizationID: organization.id,
                    projectID: $0.nodeID
                )]?.lastAttemptAt,
                rhsID: $1.nodeID.rawValue,
                rhsAttempt: streamsByID[Self.projectItemsStreamID(
                    organizationID: organization.id,
                    projectID: $1.nodeID
                )]?.lastAttemptAt
            )
        }
        let selected = Array(projects.prefix(selectionPolicy.maximumProjects))
        let deferredCount = projects.count - selected.count
        var statuses = [CoverageStatus]()
        for project in selected {
            try await validateCurrentScope(scope)
            let streamID = Self.projectItemsStreamID(
                organizationID: organization.id,
                projectID: project.nodeID
            )
            do {
                let coverage = try await refreshProjectItems(
                    project,
                    scope,
                    organization,
                    streamID,
                    streamsByID[streamID]?.highWater,
                    reconciliationIntent,
                    observedAt
                )
                try await validateCurrentScope(scope)
                statuses.append(coverage.status)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await validateCurrentScope(scope)
                if Self.isTransportCancellation(error) { throw CancellationError() }
                guard Self.isExpectedSourceError(error) else { throw error }
                statuses.append(Self.coverageStatus(for: error))
                Self.recordRecovery(from: error, observedAt: observedAt, into: &recovery)
            }
        }
        if deferredCount > 0 {
            statuses.append(.partial)
        }
        let aggregateStatus = Self.aggregateStatus(statuses)
        let aggregateStreamID = Self.projectItemsAggregateStreamID(organizationID: organization.id)
        let aggregate = makeCoverage(
            scope: scope,
            repositoryID: nil,
            feature: .projectItems,
            streamID: aggregateStreamID,
            previousHighWater: streamsByID[aggregateStreamID]?.highWater,
            observedAt: observedAt,
            status: aggregateStatus,
            detail: Self.aggregateDetail(
                feature: "Project item",
                status: aggregateStatus,
                deferredCount: deferredCount
            )
        )
        try await saveCoverage([aggregate], scope: scope, attemptedAt: observedAt)
        return (inventory.projectCoverage, aggregate)
    }

    private func refreshDiscussionComments(
        scope: SynchronizationScope,
        organization: GitHubOrganization,
        repository: RepositorySummary,
        observedAt: Date,
        streamsByID: [SyncStreamID: SyncStream],
        recovery: inout OrganizationContextRecovery
    ) async throws -> (comment: CoverageStatus, reply: CoverageStatus) {
        let candidates = try await discussionCommentCandidates(
            scope: scope,
            repositoryID: repository.id,
            observedAt: observedAt
        )
        try await validateCurrentScope(scope)
        let selected = Array(candidates.sorted {
            let lhsComment = Self.discussionCommentLeafStreamID(
                organizationID: organization.id,
                repositoryID: repository.id,
                discussionNodeID: $0
            )
            let lhsReply = Self.discussionReplyLeafStreamID(
                organizationID: organization.id,
                repositoryID: repository.id,
                discussionNodeID: $0
            )
            let rhsComment = Self.discussionCommentLeafStreamID(
                organizationID: organization.id,
                repositoryID: repository.id,
                discussionNodeID: $1
            )
            let rhsReply = Self.discussionReplyLeafStreamID(
                organizationID: organization.id,
                repositoryID: repository.id,
                discussionNodeID: $1
            )
            return Self.candidatePrecedes(
                lhsID: $0.rawValue,
                lhsAttempt: [streamsByID[lhsComment]?.lastAttemptAt, streamsByID[lhsReply]?.lastAttemptAt]
                    .compactMap { $0 }
                    .min(),
                rhsID: $1.rawValue,
                rhsAttempt: [streamsByID[rhsComment]?.lastAttemptAt, streamsByID[rhsReply]?.lastAttemptAt]
                    .compactMap { $0 }
                    .min()
            )
        }.prefix(Self.maximumDiscussionCommentCandidatesPerRepository))
        let deferredCount = candidates.count - selected.count
        var comments = [CoverageStatus]()
        var replies = [CoverageStatus]()
        for discussionNodeID in selected {
            try await validateCurrentScope(scope)
            let commentStreamID = Self.discussionCommentLeafStreamID(
                organizationID: organization.id,
                repositoryID: repository.id,
                discussionNodeID: discussionNodeID
            )
            let replyStreamID = Self.discussionReplyLeafStreamID(
                organizationID: organization.id,
                repositoryID: repository.id,
                discussionNodeID: discussionNodeID
            )
            do {
                let result = try await runDiscussionCommentsRefresh(
                    scope,
                    organization,
                    repository,
                    discussionNodeID,
                    commentStreamID,
                    replyStreamID,
                    streamsByID[commentStreamID]?.highWater,
                    streamsByID[replyStreamID]?.highWater,
                    observedAt
                )
                try await validateCurrentScope(scope)
                comments.append(result.commentCoverage.status)
                replies.append(result.replyCoverage.status)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await validateCurrentScope(scope)
                if Self.isTransportCancellation(error) { throw CancellationError() }
                guard Self.isExpectedSourceError(error) else { throw error }
                let status = Self.coverageStatus(for: error)
                let source = Self.discussionCommentSource(for: error)
                comments.append(source == .comments ? status : .partial)
                replies.append(source == .replies ? status : .partial)
                Self.recordRecovery(from: error, observedAt: observedAt, into: &recovery)
            }
        }
        if deferredCount > 0 {
            comments.append(.partial)
            replies.append(.partial)
        }
        let commentStatus = Self.aggregateStatus(comments)
        let replyStatus = Self.aggregateStatus(replies)
        try await saveCoverage(
            [
                makeCoverage(
                    scope: scope,
                    repositoryID: repository.id,
                    feature: .discussionComments,
                    streamID: Self.discussionCommentsStreamID(
                        organizationID: organization.id,
                        repositoryID: repository.id
                    ),
                    previousHighWater: streamsByID[Self.discussionCommentsStreamID(
                        organizationID: organization.id,
                        repositoryID: repository.id
                    )]?.highWater,
                    observedAt: observedAt,
                    status: commentStatus,
                    detail: Self.aggregateDetail(
                        feature: "Discussion comment",
                        status: commentStatus,
                        deferredCount: deferredCount
                    )
                ),
                makeCoverage(
                    scope: scope,
                    repositoryID: repository.id,
                    feature: .discussionReplies,
                    streamID: Self.discussionRepliesStreamID(
                        organizationID: organization.id,
                        repositoryID: repository.id
                    ),
                    previousHighWater: streamsByID[Self.discussionRepliesStreamID(
                        organizationID: organization.id,
                        repositoryID: repository.id
                    )]?.highWater,
                    observedAt: observedAt,
                    status: replyStatus,
                    detail: Self.aggregateDetail(
                        feature: "Discussion reply",
                        status: replyStatus,
                        deferredCount: deferredCount
                    )
                )
            ],
            scope: scope,
            attemptedAt: observedAt
        )
        return (commentStatus, replyStatus)
    }

    private func discussionCommentCandidates(
        scope: SynchronizationScope,
        repositoryID: RepositoryID,
        observedAt: Date
    ) async throws -> [GitHubNodeID] {
        let cutoff = Int64((observedAt.addingTimeInterval(-90 * 24 * 60 * 60).timeIntervalSince1970 * 1_000).rounded())
        return try await vault.read { database in
            try Self.validateCurrentScope(scope, in: database)
            let values = try String.fetchAll(
                database,
                sql: """
                    SELECT discussions.github_node_id
                    FROM discussions
                    JOIN github_nodes ON github_nodes.github_node_id = discussions.github_node_id
                    WHERE github_nodes.account_id = ?
                      AND github_nodes.organization_id = ?
                      AND github_nodes.repository_id = ?
                      AND (github_nodes.state = 'open' OR discussions.updated_at_ms >= ?)
                    ORDER BY discussions.updated_at_ms DESC, discussions.github_node_id
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, repositoryID.rawValue, cutoff]
            )
            return try values.map {
                guard let nodeID = GitHubNodeID(rawValue: $0) else {
                    throw OrganizationContextRefreshServiceError.invalidPersistedDiscussionCandidate
                }
                return nodeID
            }
        }
    }

    private func nestedDiscussionPrerequisiteCoverage(
        scope: SynchronizationScope,
        repositoryID: RepositoryID,
        observedAt: Date,
        streamsByID: [SyncStreamID: SyncStream],
        status: CoverageStatus,
        detail: String
    ) -> [CoverageRecord] {
        let commentsID = Self.discussionCommentsStreamID(
            organizationID: scope.organizationID,
            repositoryID: repositoryID
        )
        let repliesID = Self.discussionRepliesStreamID(
            organizationID: scope.organizationID,
            repositoryID: repositoryID
        )
        return [
            makeCoverage(
                scope: scope,
                repositoryID: repositoryID,
                feature: .discussionComments,
                streamID: commentsID,
                previousHighWater: streamsByID[commentsID]?.highWater,
                observedAt: observedAt,
                status: status,
                detail: detail
            ),
            makeCoverage(
                scope: scope,
                repositoryID: repositoryID,
                feature: .discussionReplies,
                streamID: repliesID,
                previousHighWater: streamsByID[repliesID]?.highWater,
                observedAt: observedAt,
                status: status,
                detail: detail
            )
        ]
    }

    private func makeCoverage(
        scope: SynchronizationScope,
        repositoryID: RepositoryID?,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        previousHighWater: Date?,
        observedAt: Date,
        status: CoverageStatus,
        detail: String?
    ) -> CoverageRecord {
        let start = previousHighWater.map {
            max($0.addingTimeInterval(-Self.overlap), Date(timeIntervalSince1970: 0))
        } ?? Date(timeIntervalSince1970: 0)
        return CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: repositoryID,
            feature: feature,
            streamID: streamID,
            intervalStart: start,
            intervalEnd: observedAt,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: status,
            lastSuccessfulAt: status == .complete ? observedAt : nil,
            failureDetail: detail
        )
    }

    private func saveCoverage(
        _ records: [CoverageRecord],
        scope: SynchronizationScope,
        attemptedAt: Date
    ) async throws {
        guard !records.isEmpty else { return }
        let accountID = vault.accountID
        try await vault.write { database in
            try Self.validateCurrentScope(scope, in: database)
            for record in records {
                try CoverageRepository.save(
                    record,
                    attemptedAt: attemptedAt,
                    expectedAccountID: accountID,
                    in: database
                )
            }
        }
    }

    private func validateCurrentScope(_ scope: SynchronizationScope) async throws {
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

    private nonisolated static func candidatePrecedes(
        lhsID: String,
        lhsAttempt: Date?,
        rhsID: String,
        rhsAttempt: Date?
    ) -> Bool {
        switch (lhsAttempt, rhsAttempt) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(lhs), .some(rhs)) where lhs != rhs: return lhs < rhs
        default: return lhsID < rhsID
        }
    }

    private nonisolated static func aggregateStatus(_ statuses: [CoverageStatus]) -> CoverageStatus {
        statuses.max { severity($0) < severity($1) } ?? .complete
    }

    private nonisolated static func severity(_ status: CoverageStatus) -> Int {
        switch status {
        case .complete: 0
        case .unavailable: 1
        case .unknown: 2
        case .partial: 3
        case .failed: 4
        case .requiresApproval: 5
        case .requiresSSO: 6
        }
    }

    private nonisolated static func aggregateDetail(
        feature: String,
        status: CoverageStatus,
        deferredCount: Int
    ) -> String? {
        if deferredCount > 0 {
            return "\(feature) coverage is partial; \(deferredCount) source candidates remain deferred."
        }
        switch status {
        case .complete: return nil
        case .unknown: return "\(feature) coverage is not yet known for every source candidate."
        case .unavailable: return "\(feature) coverage is unavailable for one or more source candidates."
        case .partial: return "\(feature) coverage is partial for one or more source candidates."
        case .requiresSSO: return "GitHub organization SSO authorization is required for one or more \(feature.lowercased()) sources."
        case .requiresApproval: return "GitHub organization approval is required for one or more \(feature.lowercased()) sources."
        case .failed: return "One or more \(feature.lowercased()) sources did not complete."
        }
    }

    private nonisolated static func isExpectedSourceError(_ error: Error) -> Bool {
        error is DiscussionProjectV2SynchronizationError
            || error is DiscussionCommentSynchronizationError
            || error is GitHubGraphQLError
            || error is GitHubDiscussionClientError
            || error is GitHubDiscussionCommentClientError
            || error is GitHubProjectV2ClientError
            || error is URLError
    }

    private nonisolated static func isTransportCancellation(_ error: Error) -> Bool {
        (error as? URLError)?.code == .cancelled
    }

    private nonisolated static func coverageStatus(for error: Error) -> CoverageStatus {
        if case let DiscussionProjectV2SynchronizationError.requiresSSO(header) = error {
            return ssoCoverageStatus(header)
        }
        if case DiscussionProjectV2SynchronizationError.requiresApproval = error { return .requiresApproval }
        if case let DiscussionCommentSynchronizationError.requiresSSO(header) = error {
            return ssoCoverageStatus(header)
        }
        if case DiscussionCommentSynchronizationError.requiresApproval = error {
            return .requiresApproval
        }
        guard case let GitHubGraphQLError.requestFailed(failure) = error else {
            return .partial
        }
        if let header = failure.ssoHeader { return ssoCoverageStatus(header) }
        if failure.accessRestriction != nil { return .requiresApproval }
        switch failure.kind {
        case .forbidden, .notFound: return .unavailable
        case .rateLimited, .secondaryRateLimited: return .partial
        case .unauthorized, .serverFailure, .unexpectedResponse: return .failed
        }
    }

    private nonisolated static func recordRecovery(
        from error: Error,
        observedAt: Date,
        into recovery: inout OrganizationContextRecovery
    ) {
        if case let DiscussionProjectV2SynchronizationError.requiresSSO(header) = error {
            if case .authorizationRequired = header {
                recovery.ssoRequirement = GitHubSSOHeader.combined([recovery.ssoRequirement, header])
            }
            return
        }
        if case DiscussionProjectV2SynchronizationError.requiresApproval = error {
            recovery.approvalRequired = true
            return
        }
        if case let DiscussionCommentSynchronizationError.requiresSSO(header) = error {
            if case .authorizationRequired = header {
                recovery.ssoRequirement = GitHubSSOHeader.combined([recovery.ssoRequirement, header])
            }
            return
        }
        if case DiscussionCommentSynchronizationError.requiresApproval = error {
            recovery.approvalRequired = true
            return
        }
        if case let GitHubGraphQLError.requestFailed(failure) = error {
            if let header = failure.ssoHeader {
                if case .authorizationRequired = header {
                    recovery.ssoRequirement = GitHubSSOHeader.combined([recovery.ssoRequirement, header])
                }
                return
            }
            if failure.accessRestriction != nil {
                recovery.approvalRequired = true
                return
            }
            switch failure.kind {
            case .unauthorized:
                recovery.authenticationRequired = true
            case .rateLimited, .secondaryRateLimited:
                recovery.rateLimited = true
                let retryAt = failure.retryAfter.map { observedAt.addingTimeInterval($0) }
                recovery.rateLimitRetryAt = [recovery.rateLimitRetryAt, retryAt]
                    .compactMap { $0 }
                    .max()
            case .serverFailure, .unexpectedResponse:
                recovery.failed = true
            case .forbidden, .notFound:
                break
            }
            return
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                recovery.offline = true
            case .cancelled:
                break
            default:
                recovery.failed = true
            }
        }
    }

    private nonisolated static func ssoCoverageStatus(_ header: GitHubSSOHeader) -> CoverageStatus {
        switch header {
        case .authorizationRequired:
            .requiresSSO
        case .partialResults, .malformed:
            .partial
        }
    }

    private nonisolated static func discussionCommentSource(
        for error: Error
    ) -> GitHubDiscussionCommentSource {
        switch error {
        case let GitHubDiscussionCommentClientError.requestFailed(source, _, _),
             let GitHubDiscussionCommentClientError.paginationLoop(source, _),
             let GitHubDiscussionCommentClientError.paginationLimitExceeded(source, _),
             let GitHubDiscussionCommentClientError.queryCostExceeded(source, _),
             let GitHubDiscussionCommentClientError.aggregateLimitExceeded(source, _),
             let GitHubDiscussionCommentClientError.missingRequestedNode(source, _),
             let GitHubDiscussionCommentClientError.incompleteConnection(source, _),
             let GitHubDiscussionCommentClientError.undecodableResponse(source, _),
             let GitHubDiscussionCommentClientError.partialResponse(source, _),
             let GitHubDiscussionCommentClientError.ssoResponse(source, _, _),
             let GitHubDiscussionCommentClientError.normalizationFailed(source, _):
            source
        default:
            .comments
        }
    }

    private nonisolated static func discussionAggregateStreamID(
        organizationID: OrganizationID
    ) -> SyncStreamID {
        SyncStreamID(rawValue: "discussions-\(organizationID.rawValue)")!
    }

    private nonisolated static func discussionStreamID(
        organizationID: OrganizationID,
        repositoryID: RepositoryID
    ) -> SyncStreamID {
        SyncStreamID(rawValue: "discussions-\(organizationID.rawValue)-\(repositoryID.rawValue)")!
    }

    private nonisolated static func discussionCommentsAggregateStreamID(
        organizationID: OrganizationID
    ) -> SyncStreamID {
        SyncStreamID(rawValue: "discussion-comments-\(organizationID.rawValue)")!
    }

    private nonisolated static func discussionCommentsStreamID(
        organizationID: OrganizationID,
        repositoryID: RepositoryID
    ) -> SyncStreamID {
        SyncStreamID(rawValue: "discussion-comments-\(organizationID.rawValue)-\(repositoryID.rawValue)")!
    }

    private nonisolated static func discussionCommentLeafStreamID(
        organizationID: OrganizationID,
        repositoryID: RepositoryID,
        discussionNodeID: GitHubNodeID
    ) -> SyncStreamID {
        SyncStreamID(
            rawValue: "discussion-comments-\(organizationID.rawValue)-\(repositoryID.rawValue)-\(discussionNodeID.rawValue)"
        )!
    }

    private nonisolated static func discussionRepliesAggregateStreamID(
        organizationID: OrganizationID
    ) -> SyncStreamID {
        SyncStreamID(rawValue: "discussion-replies-\(organizationID.rawValue)")!
    }

    private nonisolated static func discussionRepliesStreamID(
        organizationID: OrganizationID,
        repositoryID: RepositoryID
    ) -> SyncStreamID {
        SyncStreamID(rawValue: "discussion-replies-\(organizationID.rawValue)-\(repositoryID.rawValue)")!
    }

    private nonisolated static func discussionReplyLeafStreamID(
        organizationID: OrganizationID,
        repositoryID: RepositoryID,
        discussionNodeID: GitHubNodeID
    ) -> SyncStreamID {
        SyncStreamID(
            rawValue: "discussion-replies-\(organizationID.rawValue)-\(repositoryID.rawValue)-\(discussionNodeID.rawValue)"
        )!
    }

    private nonisolated static func projectInventoryStreamID(
        organizationID: OrganizationID
    ) -> SyncStreamID {
        SyncStreamID(rawValue: "projects-v2-inventory-\(organizationID.rawValue)")!
    }

    private nonisolated static func projectItemsAggregateStreamID(
        organizationID: OrganizationID
    ) -> SyncStreamID {
        SyncStreamID(rawValue: "projects-v2-items-\(organizationID.rawValue)")!
    }

    private nonisolated static func projectItemsStreamID(
        organizationID: OrganizationID,
        projectID: GitHubNodeID
    ) -> SyncStreamID {
        SyncStreamID(rawValue: "projects-v2-items-\(organizationID.rawValue)-\(projectID.rawValue)")!
    }
}
