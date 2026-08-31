import Foundation
import GRDB

/// The deliberately small source boundary used by review-thread refreshes.
/// Implementations must return the complete, independently paginated inventory
/// for exactly one pull request; REST review summaries are not a substitute.
protocol PullRequestReviewThreadFetching: Sendable {
    func allReviewThreads(
        pullRequestNodeID: GitHubNodeID,
        observedAt: Date
    ) async throws -> GitHubPullRequestReviewThreadInventory
}

extension GitHubPullRequestReviewThreadClient: PullRequestReviewThreadFetching {}

enum PullRequestReviewThreadRefreshOutcomeStatus: Sendable, Equatable {
    case refreshed
    case ssoRequired(GitHubSSOHeader)
    case approvalRequired
    case authenticationRequired
    case rateLimited(retryAt: Date?)
    case unavailableOrPermission
    case failed
}

struct PullRequestReviewThreadRefreshOutcome: Sendable {
    let pullRequestNodeID: GitHubNodeID
    let repositoryID: RepositoryID
    let pullRequestNumber: Int
    let status: PullRequestReviewThreadRefreshOutcomeStatus
}

struct PullRequestReviewThreadRefreshResult: Sendable {
    /// This remains in candidate-inventory order, so callers can associate
    /// source-local coverage decisions with the exact pull request.
    let outcomes: [PullRequestReviewThreadRefreshOutcome]
    /// A bounded inventory is not a complete organization-wide refresh.
    let hasRemainingCandidates: Bool
    /// Retained known pull requests which are not currently requestable under
    /// this account's node/repository authority.
    let hasBlockedKnownCandidates: Bool

    var ssoRequirement: GitHubSSOHeader? {
        outcomes.lazy.compactMap { outcome in
            if case let .ssoRequired(header) = outcome.status {
                return header
            }
            return nil
        }.first
    }

    var coverageAssessment: PullRequestReviewThreadCoverageAssessment {
        let statuses = outcomes.map(\.status)
        if ssoRequirement != nil {
            return .init(
                status: .requiresSSO,
                failureDetail: "GitHub organization SSO authorization is required for some review threads."
            )
        }
        if statuses.contains(.approvalRequired) {
            return .init(
                status: .requiresApproval,
                failureDetail: "GitHub organization approval is required for some review threads."
            )
        }
        if statuses.contains(.authenticationRequired) || statuses.contains(.failed) {
            return .init(
                status: .failed,
                failureDetail: "Some pull request review threads could not be refreshed."
            )
        }
        if statuses.contains(.unavailableOrPermission) {
            return .init(
                status: .unavailable,
                failureDetail: "Some pull request review threads are unavailable to the selected account."
            )
        }
        if hasBlockedKnownCandidates {
            return .init(
                status: .unavailable,
                failureDetail: "Some known pull requests are no longer accessible to the selected account. Restore repository access or refresh the repository inventory."
            )
        }
        if statuses.contains(where: {
            if case .rateLimited = $0 { return true }
            return false
        }) {
            return .init(
                status: .partial,
                failureDetail: "GitHub rate limiting left some review-thread coverage incomplete."
            )
        }
        if hasRemainingCandidates {
            return .init(
                status: .partial,
                failureDetail: "Additional pull request review-thread candidates remain for the next refresh."
            )
        }
        return .init(status: .complete, failureDetail: nil)
    }
}

struct PullRequestReviewThreadCoverageAssessment: Equatable, Sendable {
    let status: CoverageStatus
    let failureDetail: String?
}

actor PullRequestReviewThreadRefreshService {
    private let fetcher: any PullRequestReviewThreadFetching
    private let candidateRepository: PullRequestReviewCandidateRepository
    private let threadRepository: PullRequestReviewThreadRepository
    private let currentUserNodeID: GitHubNodeID
    private let failureEnvelopeRepository: ReviewCandidateFailureEnvelopeRepository?

    init(
        fetcher: any PullRequestReviewThreadFetching,
        candidateRepository: PullRequestReviewCandidateRepository,
        threadRepository: PullRequestReviewThreadRepository,
        currentUserNodeID: GitHubNodeID,
        failureEnvelopeRepository: ReviewCandidateFailureEnvelopeRepository? = nil
    ) {
        self.fetcher = fetcher
        self.candidateRepository = candidateRepository
        self.threadRepository = threadRepository
        self.currentUserNodeID = currentUserNodeID
        self.failureEnvelopeRepository = failureEnvelopeRepository
    }

    func refresh(
        scope: SynchronizationScope,
        githubOrganizationID: UInt64,
        limit: Int = 50,
        observedAt: Date = .now,
        streamID: SyncStreamID
    ) async throws -> PullRequestReviewThreadRefreshResult {
        let accountID = scope.accountID
        let organizationID = scope.organizationID
        try await validateCurrentScope(scope)
        let inventory = try await selectCandidates(
            scope: scope,
            streamID: streamID,
            limit: limit
        )
        try await validateCurrentScope(scope)
        var outcomes = [PullRequestReviewThreadRefreshOutcome]()
        outcomes.reserveCapacity(inventory.candidates.count)

        for candidate in inventory.candidates {
            let threadInventory: GitHubPullRequestReviewThreadInventory
            do {
                try await validateCurrentScope(scope)
                threadInventory = try await fetcher.allReviewThreads(
                    pullRequestNodeID: candidate.nodeID,
                    observedAt: observedAt
                )
                try await validateCurrentScope(scope)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await validateCurrentScope(scope)
                let failure = try Self.failurePublication(
                    for: error,
                    candidate: candidate,
                    scope: scope,
                    streamID: streamID,
                    githubOrganizationID: githubOrganizationID,
                    attemptedAt: observedAt
                )
                try await publishFailure(failure, orThrow: error)
                try await validateCurrentScope(scope)
                let status = Self.status(
                    for: error,
                    githubOrganizationID: githubOrganizationID,
                    observedAt: observedAt
                )
                outcomes.append(
                    outcome(
                        for: candidate,
                        status: status
                    )
                )
                if status == .unavailableOrPermission {
                    continue
                }
                break
            }
            do {
                try await candidateRepository.writeTransaction(accountID: accountID) { database in
                    try Self.validateCurrentScope(scope, in: database)
                    let traversal = try Self.completeTraversal(
                        inventory: threadInventory,
                        candidate: candidate,
                        scope: scope,
                        streamID: streamID,
                        observedAt: observedAt,
                        in: database
                    )
                    let receipt = try ReviewCandidateCompleteTraversalReceiptRepository.persist(
                        traversal,
                        in: database
                    )
                    try PullRequestReviewThreadRepository.replace(
                        pullRequestNodeID: candidate.nodeID,
                        accountID: accountID,
                        organizationID: organizationID,
                        repositoryID: candidate.repositoryID,
                        currentUserNodeID: currentUserNodeID,
                        records: threadInventory.records,
                        rawPages: threadInventory.rawPages,
                        scope: scope,
                        streamID: streamID,
                        completeTraversalReceipt: receipt,
                        observedAt: observedAt,
                        in: database
                    )
                    try PullRequestReviewCandidateRepository.advanceFairSchedule(
                        after: candidate,
                        scope: scope,
                        streamID: streamID,
                        feature: .reviewThreads,
                        at: observedAt,
                        in: database
                    )
                }
            } catch ReviewCandidateCompleteTraversalReceiptRepositoryError.staleSynchronizationScope {
                throw CancellationError()
            }
            try await validateCurrentScope(scope)
            outcomes.append(outcome(for: candidate, status: .refreshed))
        }

        try await validateCurrentScope(scope)
        return PullRequestReviewThreadRefreshResult(
            outcomes: outcomes,
            hasRemainingCandidates: inventory.hasRemainingCandidates,
            hasBlockedKnownCandidates: inventory.hasBlockedKnownCandidates
        )
    }

    private func selectCandidates(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        limit: Int
    ) async throws -> PullRequestReviewCandidateInventory {
        do {
            return try await candidateRepository.fairCandidates(
                scope: scope,
                streamID: streamID,
                feature: .reviewThreads,
                limit: limit
            )
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope,
                OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw CancellationError()
        }
    }

    /// Builds the complete source topology before any normalized rows are
    /// touched. A review-thread replacement is authoritative only when there
    /// is one terminal root traversal and one terminal comment traversal for
    /// every discovered thread, including threads with zero comments.
    private nonisolated static func completeTraversal(
        inventory: GitHubPullRequestReviewThreadInventory,
        candidate: PullRequestReviewCandidate,
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        observedAt: Date,
        in database: Database
    ) throws -> ReviewCandidateCompleteTraversal {
        let sourceRevision = try String.fetchOne(
            database,
            sql: """
                SELECT source_revision
                FROM github_nodes
                WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                  AND repository_id = ? AND accessibility_state = 'accessible'
                """,
            arguments: [
                candidate.nodeID.rawValue,
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                candidate.repositoryID.rawValue
            ]
        )
        guard let sourceRevision else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidCandidateScope
        }

        let rootPrefix = "graphql:TriagePullRequestReviewThreads/pull-request=\(candidate.nodeID.rawValue)/after="
        var rootPages = [GitHubPullRequestReviewThreadRawPage]()
        var commentPages = [GitHubNodeID: [GitHubPullRequestReviewThreadRawPage]]()
        for page in inventory.rawPages {
            if page.requestKey.hasPrefix(rootPrefix),
               validCursorComponent(String(page.requestKey.dropFirst(rootPrefix.count))) {
                rootPages.append(page)
            } else if let threadNodeID = commentThreadNodeID(requestKey: page.requestKey) {
                commentPages[threadNodeID, default: []].append(page)
            } else {
                throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal
            }
        }

        let discoveredThreadNodeIDs = inventory.records.map(\.nodeID)
        let discoveredThreads = Set(discoveredThreadNodeIDs)
        guard !rootPages.isEmpty,
              discoveredThreads.count == discoveredThreadNodeIDs.count,
              Set(commentPages.keys) == discoveredThreads,
              inventory.rawPages.count == rootPages.count + commentPages.values.reduce(0, { $0 + $1.count })
        else {
            throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal
        }
        let discoveredCommentNodeIDsByThread = Dictionary(
            uniqueKeysWithValues: inventory.records.map { record in
                (record.nodeID, record.comments.map(\.nodeID))
            }
        )

        var segments = [ReviewCandidateTraversalSegment]()
        segments.append(
            .init(
                kind: .reviewThreads,
                pages: traversalPages(
                    from: rootPages,
                    scope: scope,
                    streamID: streamID
                )
            )
        )
        for threadNodeID in discoveredThreadNodeIDs {
            guard let pages = commentPages[threadNodeID], !pages.isEmpty else {
                throw ReviewCandidateCompleteTraversalReceiptRepositoryError.invalidTraversal
            }
            segments.append(
                .init(
                    kind: .threadComments,
                    parentThreadNodeID: threadNodeID,
                    pages: traversalPages(from: pages, scope: scope, streamID: streamID)
                )
            )
        }
        return ReviewCandidateCompleteTraversal(
            scope: scope,
            feature: .reviewThreads,
            streamID: streamID,
            candidate: candidate,
            candidateSourceRevision: sourceRevision,
            parserVersion: 1,
            observedAt: observedAt,
            normalizedDigest: PullRequestReviewThreadRepository.normalizedDigest(
                for: inventory.records
            ),
            discoveredThreadNodeIDs: discoveredThreadNodeIDs,
            discoveredCommentNodeIDsByThread: discoveredCommentNodeIDsByThread,
            segments: segments
        )
    }

    private nonisolated static func traversalPages(
        from pages: [GitHubPullRequestReviewThreadRawPage],
        scope: SynchronizationScope,
        streamID: SyncStreamID
    ) -> [ReviewCandidateTraversalPage] {
        pages.enumerated().map { offset, page in
            .init(
                ordinal: offset + 1,
                rawSnapshotID: .make(),
                requestIdentity: .init(
                    scope: scope,
                    feature: .reviewThreads,
                    streamID: streamID,
                    requestKey: page.requestKey
                ),
                endpoint: page.endpoint,
                payload: page.payload,
                isTerminal: offset == pages.count - 1
            )
        }
    }

    private nonisolated static func commentThreadNodeID(requestKey: String) -> GitHubNodeID? {
        let prefix = "graphql:TriagePullRequestReviewThreadComments/thread="
        guard requestKey.hasPrefix(prefix) else { return nil }
        let suffix = requestKey.dropFirst(prefix.count)
        guard let range = suffix.range(of: "/after="), range.lowerBound != suffix.startIndex else {
            return nil
        }
        guard validCursorComponent(String(suffix[range.upperBound...])) else { return nil }
        return GitHubNodeID(rawValue: String(suffix[..<range.lowerBound]))
    }

    private nonisolated static func validCursorComponent(_ value: String) -> Bool {
        value == "none" || (!value.isEmpty && Data(base64Encoded: value) != nil)
    }

    private func validateCurrentScope(_ scope: SynchronizationScope) async throws {
        try Task.checkCancellation()
        do {
            try await candidateRepository.writeTransaction(accountID: scope.accountID) { database in
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

    private func outcome(
        for candidate: PullRequestReviewCandidate,
        status: PullRequestReviewThreadRefreshOutcomeStatus
    ) -> PullRequestReviewThreadRefreshOutcome {
        PullRequestReviewThreadRefreshOutcome(
            pullRequestNodeID: candidate.nodeID,
            repositoryID: candidate.repositoryID,
            pullRequestNumber: candidate.number,
            status: status
        )
    }

    private nonisolated static func status(
        for error: Error,
        githubOrganizationID: UInt64,
        observedAt: Date
    ) -> PullRequestReviewThreadRefreshOutcomeStatus {
        if let traversal = error as? GitHubPullRequestReviewThreadTraversalFailure {
            if let header = traversal.ssoHeader?.scoped(to: githubOrganizationID) {
                return .ssoRequired(header)
            }
            if let remoteFailure = traversal.remoteFailure {
                return status(
                    for: remoteFailure,
                    githubOrganizationID: githubOrganizationID,
                    observedAt: observedAt
                )
            }
            return .failed
        }
        guard case let GitHubGraphQLError.requestFailed(failure) = error else {
            return .failed
        }
        return status(for: failure, githubOrganizationID: githubOrganizationID, observedAt: observedAt)
    }

    private nonisolated static func status(
        for failure: GitHubFailure,
        githubOrganizationID: UInt64,
        observedAt: Date
    ) -> PullRequestReviewThreadRefreshOutcomeStatus {
        if let header = failure.ssoHeader?.scoped(to: githubOrganizationID) {
            return .ssoRequired(header)
        }
        if failure.accessRestriction != nil {
            return .approvalRequired
        }
        switch failure.kind {
        case .unauthorized:
            return .authenticationRequired
        case .rateLimited, .secondaryRateLimited:
            return .rateLimited(retryAt: failure.retryAfter.map { observedAt.addingTimeInterval($0) })
        case .forbidden, .notFound:
            return .unavailableOrPermission
        case .serverFailure, .unexpectedResponse:
            return .failed
        }
    }

    private nonisolated static func failurePublication(
        for error: Error,
        candidate: PullRequestReviewCandidate,
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        githubOrganizationID: UInt64,
        attemptedAt: Date
    ) throws -> ReviewCandidateFailurePublication {
        let traversal = error as? GitHubPullRequestReviewThreadTraversalFailure
        // The concrete GraphQL client wraps every response-bearing failure in
        // a traversal error. A source-boundary error without that evidence is
        // deliberately only a zero-raw transport failure, even when a test
        // double or future adapter attaches remote-looking metadata to it.
        let classification: ReviewCandidateFailureClassification = if traversal == nil {
            .transportFailure
        } else {
            failureClassification(for: error, githubOrganizationID: githubOrganizationID)
        }
        let sourcePages = traversal?.rawPages ?? []
        var ordinals = [String: Int]()
        let rawPages = sourcePages.map { page -> ReviewCandidateFailureRawPage in
            let ordinal = (ordinals[page.requestKey] ?? 0) + 1
            ordinals[page.requestKey] = ordinal
            let identity = ConditionalRequestIdentity(
                scope: scope,
                feature: .reviewThreads,
                streamID: streamID,
                requestKey: page.requestKey
            )
            return ReviewCandidateFailureRawPage(
                ordinal: ordinal,
                rawSnapshotID: .make(),
                requestIdentity: identity,
                endpoint: page.endpoint,
                payload: page.payload
            )
        }
        let terminalRequestKey: String
        let rawProvenance: ReviewCandidateFailureRawProvenance
        if let traversal {
            guard traversal.rawPages.last?.requestKey == traversal.terminalRequestKey else {
                // Do not advance a fair cursor with a fabricated terminal
                // identity: the classified envelope must bind to raw evidence.
                throw ReviewCandidateFailureEnvelopeRepositoryError.invalidRawPages
            }
            terminalRequestKey = traversal.terminalRequestKey
            rawProvenance = .terminalRawPage
        } else {
            // Non-traversal source boundaries have no raw page to bind. Keep
            // their deliberately synthetic terminal key separate from every
            // GraphQL operation and do not claim it came from a response.
            terminalRequestKey = "review-thread-failure/\(candidate.nodeID.rawValue)"
            rawProvenance = .zeroRawTransportFailure
        }
        return ReviewCandidateFailurePublication(
            scope: scope,
            feature: .reviewThreads,
            streamID: streamID,
            candidate: candidate,
            requestIdentity: .init(
                scope: scope,
                feature: .reviewThreads,
                streamID: streamID,
                requestKey: terminalRequestKey
            ),
            parserVersion: 1,
            attemptedAt: attemptedAt,
            terminalAt: attemptedAt,
            classification: classification,
            redactedDiagnostic: failureDiagnostic(for: classification),
            rawProvenance: rawProvenance,
            rawPages: rawPages
        )
    }

    private nonisolated static func failureClassification(
        for error: Error,
        githubOrganizationID: UInt64
    ) -> ReviewCandidateFailureClassification {
        if let traversal = error as? GitHubPullRequestReviewThreadTraversalFailure {
            if traversal.ssoHeader?.scoped(to: githubOrganizationID) != nil {
                return .ssoRequired
            }
            if let failure = traversal.remoteFailure {
                return failureClassification(for: failure, githubOrganizationID: githubOrganizationID)
            }
            switch traversal.reason {
            case .normalizationFailed:
                return .normalizationFailure
            case .partialResponse, .missingData, .undecodableResponse,
                    .incompleteConnection, .missingRequestedPullRequest,
                    .missingRequestedThread, .duplicateThread,
                    .paginationLoop, .paginationLimitExceeded,
                    .queryCostExceeded, .responseByteBudgetExceeded:
                return .malformedResponse
            case .requestFailed, .transportFailure:
                return .transportFailure
            }
        }
        if case let GitHubGraphQLError.requestFailed(failure) = error {
            return failureClassification(for: failure, githubOrganizationID: githubOrganizationID)
        }
        return .transportFailure
    }

    private nonisolated static func failureClassification(
        for failure: GitHubFailure,
        githubOrganizationID: UInt64
    ) -> ReviewCandidateFailureClassification {
        if failure.ssoHeader?.scoped(to: githubOrganizationID) != nil {
            return .ssoRequired
        }
        if failure.accessRestriction != nil {
            return .approvalRequired
        }
        switch failure.kind {
        case .unauthorized:
            return .authenticationRequired
        case .rateLimited, .secondaryRateLimited:
            return .rateLimited
        case .forbidden, .notFound:
            return .unavailableOrPermission
        case .serverFailure:
            return .serverFailure
        case .unexpectedResponse:
            return .transportFailure
        }
    }

    private nonisolated static func failureDiagnostic(
        for classification: ReviewCandidateFailureClassification
    ) -> String {
        switch classification {
        case .authenticationRequired:
            return "Reconnect the selected account to continue pull-request review-thread synchronization."
        case .ssoRequired:
            return "GitHub organization SSO authorization is required for pull-request review threads."
        case .approvalRequired:
            return "GitHub organization approval is required for pull-request review threads."
        case .rateLimited:
            return "GitHub rate limiting left pull-request review-thread synchronization incomplete."
        case .unavailableOrPermission:
            return "This pull request's review threads are unavailable to the selected account."
        case .transportFailure:
            return "GitHub did not complete the pull-request review-thread request."
        case .serverFailure:
            return "GitHub server failure left pull-request review-thread synchronization incomplete."
        case .malformedResponse:
            return "GitHub returned incomplete or invalid pull-request review-thread data."
        case .normalizationFailure:
            return "Pull-request review-thread data failed local validation."
        }
    }

    private func publishFailure(
        _ publication: ReviewCandidateFailurePublication,
        orThrow originalError: Error
    ) async throws {
        guard let failureEnvelopeRepository else {
            // Until a caller explicitly supplies durable failure storage, do
            // not move the fair cursor merely because an attempt was
            // classified in memory.
            throw originalError
        }
        do {
            try await candidateRepository.writeTransaction(accountID: publication.scope.accountID) { database in
                try Self.validateCurrentScope(publication.scope, in: database)
                try ReviewCandidateFailureEnvelopeRepository.publish(publication, in: database)
            }
        } catch ReviewCandidateFailureEnvelopeRepositoryError.staleSynchronizationScope {
            throw CancellationError()
        }
        _ = failureEnvelopeRepository
        try await validateCurrentScope(publication.scope)
    }
}
