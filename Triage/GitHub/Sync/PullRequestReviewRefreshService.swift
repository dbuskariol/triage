import Foundation
import GRDB

struct PullRequestReviewRefreshResult: Sendable {
    let refreshedPullRequestNodeIDs: [GitHubNodeID]
    let hasRemainingCandidates: Bool
    let ssoHeaders: [GitHubSSOHeader]

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }
}

actor PullRequestReviewRefreshService {
    private let client: GitHubPullRequestClient
    private let candidateRepository: PullRequestReviewCandidateRepository

    init(
        client: GitHubPullRequestClient,
        candidateRepository: PullRequestReviewCandidateRepository
    ) {
        self.client = client
        self.candidateRepository = candidateRepository
    }

    func refresh(
        scope: SynchronizationScope,
        githubOrganizationID: UInt64,
        limit: Int = 50,
        observedAt: Date = .now
    ) async throws -> PullRequestReviewRefreshResult {
        let accountID = scope.accountID
        let organizationID = scope.organizationID
        try await validateCurrentScope(scope)
        let inventory = try await candidateRepository.candidates(
            accountID: accountID,
            organizationID: organizationID,
            limit: limit
        )
        try await validateCurrentScope(scope)
        var refreshedPullRequestNodeIDs = [GitHubNodeID]()
        var ssoHeaders = [GitHubSSOHeader]()
        let observedAtMilliseconds = Self.milliseconds(observedAt)

        for candidate in inventory.candidates {
            let reviews: GitHubPullRequestReviewInventory
            do {
                try await validateCurrentScope(scope)
                reviews = try await client.allReviews(
                    repository: candidate.repository,
                    number: candidate.number
                )
                try await validateCurrentScope(scope)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await validateCurrentScope(scope)
                throw error
            }
            ssoHeaders.append(contentsOf: reviews.ssoHeaders)
            if reviews.ssoHeader?.scoped(to: githubOrganizationID) != nil {
                continue
            }
            let requestedReviewers: GitHubResponse<GitHubRequestedReviewersDTO>
            do {
                try await validateCurrentScope(scope)
                requestedReviewers = try await client.requestedReviewers(
                    repository: candidate.repository,
                    number: candidate.number
                )
                try await validateCurrentScope(scope)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await validateCurrentScope(scope)
                throw error
            }
            if let ssoHeader = requestedReviewers.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
            let candidateSSOHeader = GitHubSSOHeader.combined(
                [reviews.ssoHeader, requestedReviewers.ssoHeader]
            )
            if candidateSSOHeader?.scoped(to: githubOrganizationID) != nil {
                continue
            }
            try await candidateRepository.writeTransaction(accountID: accountID) { database in
                try Self.validateCurrentScope(scope, in: database)
                for (index, page) in reviews.pages.enumerated() {
                    try RawAPISnapshotRepository.save(
                        RawAPISnapshot(
                            id: RawAPISnapshotID.make(),
                            accountID: accountID,
                            githubNodeID: candidate.nodeID,
                            endpoint: "\(candidate.repository.path)/pulls/\(candidate.number)/reviews?page=\(index + 1)",
                            eTag: page.etag,
                            parserVersion: 1,
                            observedAt: observedAt,
                            payload: page.payload
                        ),
                        in: database
                    )
                }
                try RawAPISnapshotRepository.save(
                    RawAPISnapshot(
                        id: RawAPISnapshotID.make(),
                        accountID: accountID,
                        githubNodeID: candidate.nodeID,
                        endpoint: "\(candidate.repository.path)/pulls/\(candidate.number)/requested_reviewers",
                        eTag: requestedReviewers.etag,
                        parserVersion: 1,
                        observedAt: observedAt,
                        payload: requestedReviewers.payload
                    ),
                    in: database
                )
                try PullRequestReviewRepository.replace(
                    reviews.reviews,
                    pullRequestNodeID: candidate.nodeID,
                    accountID: accountID,
                    observedAtMilliseconds: observedAtMilliseconds,
                    in: database
                )
                try PullRequestReviewRequestRepository.replace(
                    requestedReviewers.value,
                    pullRequestNodeID: candidate.nodeID,
                    accountID: accountID,
                    observedAtMilliseconds: observedAtMilliseconds,
                    in: database
                )
            }
            try await validateCurrentScope(scope)
            refreshedPullRequestNodeIDs.append(candidate.nodeID)
        }
        try await validateCurrentScope(scope)
        return PullRequestReviewRefreshResult(
            refreshedPullRequestNodeIDs: refreshedPullRequestNodeIDs,
            hasRemainingCandidates: inventory.hasRemainingCandidates,
            ssoHeaders: ssoHeaders
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

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
