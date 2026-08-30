import Foundation

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
        accountID: AccountID,
        organizationID: OrganizationID,
        githubOrganizationID: UInt64,
        limit: Int = 50,
        observedAt: Date = .now
    ) async throws -> PullRequestReviewRefreshResult {
        let inventory = try await candidateRepository.candidates(
            accountID: accountID,
            organizationID: organizationID,
            limit: limit
        )
        var refreshedPullRequestNodeIDs = [GitHubNodeID]()
        var ssoHeaders = [GitHubSSOHeader]()
        let observedAtMilliseconds = Self.milliseconds(observedAt)

        for candidate in inventory.candidates {
            try Task.checkCancellation()
            let reviews = try await client.allReviews(
                repository: candidate.repository,
                number: candidate.number
            )
            try Task.checkCancellation()
            ssoHeaders.append(contentsOf: reviews.ssoHeaders)
            if reviews.ssoHeader?.scoped(to: githubOrganizationID) != nil {
                continue
            }
            let requestedReviewers = try await client.requestedReviewers(
                repository: candidate.repository,
                number: candidate.number
            )
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            refreshedPullRequestNodeIDs.append(candidate.nodeID)
        }
        return PullRequestReviewRefreshResult(
            refreshedPullRequestNodeIDs: refreshedPullRequestNodeIDs,
            hasRemainingCandidates: inventory.hasRemainingCandidates,
            ssoHeaders: ssoHeaders
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
