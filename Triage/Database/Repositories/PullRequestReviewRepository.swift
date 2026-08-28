import Foundation
import GRDB

enum PullRequestReviewRepositoryError: Error, Equatable, Sendable {
    case pullRequestNodeScopeMismatch
    case invalidReviewNodeID
    case duplicateReviewNodeID
}

actor PullRequestReviewRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(
        review: GitHubPullRequestReviewDTO,
        pullRequestNodeID: GitHubNodeID,
        observedAt: Date = .now
    ) async throws {
        guard let reviewNodeID = GitHubNodeID(rawValue: review.nodeID) else {
            throw WorkItemRepositoryError.invalidPersistedData
        }
        let observedAtMilliseconds = Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
        try await vault.write { database in
            try Self.validatePullRequestNodeScope(
                pullRequestNodeID,
                accountID: vault.accountID,
                in: database
            )
            try Self.save(
                review,
                reviewNodeID: reviewNodeID,
                pullRequestNodeID: pullRequestNodeID,
                observedAtMilliseconds: observedAtMilliseconds,
                in: database
            )
        }
    }

    /// Replaces a fully paginated review history. Callers must not use this for
    /// individual pages, because doing so would incorrectly discard later pages.
    func replace(
        reviews: [GitHubPullRequestReviewDTO],
        pullRequestNodeID: GitHubNodeID,
        observedAt: Date = .now
    ) async throws {
        let observedAtMilliseconds = Self.milliseconds(observedAt)
        try await vault.writeTransaction { database in
            try Self.replace(
                reviews,
                pullRequestNodeID: pullRequestNodeID,
                accountID: vault.accountID,
                observedAtMilliseconds: observedAtMilliseconds,
                in: database
            )
        }
    }

    nonisolated static func replace(
        _ reviews: [GitHubPullRequestReviewDTO],
        pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        observedAtMilliseconds: Int64,
        in database: Database
    ) throws {
        let reviewNodeIDs = try reviewNodeIDs(for: reviews)
        try validatePullRequestNodeScope(pullRequestNodeID, accountID: accountID, in: database)
        try database.execute(
            sql: "DELETE FROM reviews WHERE pull_request_node_id = ?",
            arguments: [pullRequestNodeID.rawValue]
        )
        for (review, reviewNodeID) in zip(reviews, reviewNodeIDs) {
            try save(
                review,
                reviewNodeID: reviewNodeID,
                pullRequestNodeID: pullRequestNodeID,
                observedAtMilliseconds: observedAtMilliseconds,
                in: database
            )
        }
    }

    private nonisolated static func validatePullRequestNodeScope(
        _ nodeID: GitHubNodeID,
        accountID: AccountID,
        in database: Database
    ) throws {
        let matchingCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM pull_requests
                JOIN github_nodes ON github_nodes.github_node_id = pull_requests.github_node_id
                WHERE pull_requests.github_node_id = ? AND github_nodes.account_id = ?
                """,
            arguments: [nodeID.rawValue, accountID.rawValue]
        ) ?? 0
        guard matchingCount == 1 else {
            throw PullRequestReviewRepositoryError.pullRequestNodeScopeMismatch
        }
    }

    private nonisolated static func reviewNodeIDs(
        for reviews: [GitHubPullRequestReviewDTO]
    ) throws -> [GitHubNodeID] {
        let reviewNodeIDs = try reviews.map { review in
            guard let reviewNodeID = GitHubNodeID(rawValue: review.nodeID) else {
                throw PullRequestReviewRepositoryError.invalidReviewNodeID
            }
            return reviewNodeID
        }
        guard Set(reviewNodeIDs).count == reviewNodeIDs.count else {
            throw PullRequestReviewRepositoryError.duplicateReviewNodeID
        }
        return reviewNodeIDs
    }

    private nonisolated static func save(
        _ review: GitHubPullRequestReviewDTO,
        reviewNodeID: GitHubNodeID,
        pullRequestNodeID: GitHubNodeID,
        observedAtMilliseconds: Int64,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO reviews (
                    github_node_id, pull_request_node_id, author_id, state, body_markdown,
                    submitted_at_ms, html_url, updated_at_ms
                ) VALUES (?, ?, NULL, ?, ?, ?, NULL, ?)
                ON CONFLICT(github_node_id) DO UPDATE SET
                    pull_request_node_id = excluded.pull_request_node_id,
                    state = excluded.state,
                    body_markdown = excluded.body_markdown,
                    submitted_at_ms = excluded.submitted_at_ms,
                    updated_at_ms = excluded.updated_at_ms
                """,
            arguments: [
                reviewNodeID.rawValue,
                pullRequestNodeID.rawValue,
                review.state,
                review.body,
                review.submittedAt.map { milliseconds($0) },
                observedAtMilliseconds
            ]
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
