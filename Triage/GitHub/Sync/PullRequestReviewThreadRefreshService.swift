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

    init(
        fetcher: any PullRequestReviewThreadFetching,
        candidateRepository: PullRequestReviewCandidateRepository,
        threadRepository: PullRequestReviewThreadRepository,
        currentUserNodeID: GitHubNodeID
    ) {
        self.fetcher = fetcher
        self.candidateRepository = candidateRepository
        self.threadRepository = threadRepository
        self.currentUserNodeID = currentUserNodeID
    }

    func refresh(
        scope: SynchronizationScope,
        githubOrganizationID: UInt64,
        limit: Int = 50,
        observedAt: Date = .now
    ) async throws -> PullRequestReviewThreadRefreshResult {
        let accountID = scope.accountID
        let organizationID = scope.organizationID
        try await validateCurrentScope(scope)
        let inventory = try await candidateRepository.candidates(
            accountID: accountID,
            organizationID: organizationID,
            limit: limit
        )
        try await validateCurrentScope(scope)
        var outcomes = [PullRequestReviewThreadRefreshOutcome]()
        outcomes.reserveCapacity(inventory.candidates.count)

        for candidate in inventory.candidates {
            do {
                try await validateCurrentScope(scope)
                let threadInventory = try await fetcher.allReviewThreads(
                    pullRequestNodeID: candidate.nodeID,
                    observedAt: observedAt
                )
                try await validateCurrentScope(scope)
                try await candidateRepository.writeTransaction(accountID: accountID) { database in
                    try Self.validateCurrentScope(scope, in: database)
                    try PullRequestReviewThreadRepository.replace(
                        pullRequestNodeID: candidate.nodeID,
                        accountID: accountID,
                        organizationID: organizationID,
                        repositoryID: candidate.repositoryID,
                        currentUserNodeID: currentUserNodeID,
                        records: threadInventory.records,
                        rawPages: threadInventory.rawPages,
                        observedAt: observedAt,
                        in: database
                    )
                }
                try await validateCurrentScope(scope)
                outcomes.append(outcome(for: candidate, status: .refreshed))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await validateCurrentScope(scope)
                outcomes.append(
                    outcome(
                        for: candidate,
                        status: Self.status(
                            for: error,
                            githubOrganizationID: githubOrganizationID,
                            observedAt: observedAt
                        )
                    )
                )
            }
        }

        try await validateCurrentScope(scope)
        return PullRequestReviewThreadRefreshResult(
            outcomes: outcomes,
            hasRemainingCandidates: inventory.hasRemainingCandidates
        )
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
        guard case let GitHubGraphQLError.requestFailed(failure) = error else {
            return .failed
        }
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
}
