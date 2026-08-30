import Foundation
import GRDB

enum PullRequestReviewRepositoryError: Error, Equatable, Sendable {
    case pullRequestNodeScopeMismatch
    case reviewNodeScopeMismatch
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
                accountID: vault.accountID,
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
        try validateReviewNodeScopes(
            reviewNodeIDs,
            pullRequestNodeID: pullRequestNodeID,
            accountID: accountID,
            in: database
        )
        let staleReviewNodeIDs = try String.fetchAll(
            database,
            sql: "SELECT github_node_id FROM reviews WHERE pull_request_node_id = ?",
            arguments: [pullRequestNodeID.rawValue]
        )
        try database.execute(
            sql: "DELETE FROM reviews WHERE pull_request_node_id = ?",
            arguments: [pullRequestNodeID.rawValue]
        )
        for (review, reviewNodeID) in zip(reviews, reviewNodeIDs) {
            try save(
                review,
                reviewNodeID: reviewNodeID,
                pullRequestNodeID: pullRequestNodeID,
                accountID: accountID,
                observedAtMilliseconds: observedAtMilliseconds,
                in: database
            )
        }
        let retainedNodeIDs = Set(reviewNodeIDs.map(\.rawValue))
        for staleNodeID in staleReviewNodeIDs where !retainedNodeIDs.contains(staleNodeID) {
            try database.execute(
                sql: "DELETE FROM github_nodes WHERE github_node_id = ? AND kind = ? AND account_id = ?",
                arguments: [
                    staleNodeID,
                    GitHubContentKind.pullRequestReview.rawValue,
                    accountID.rawValue
                ]
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

    private nonisolated static func validateReviewNodeScopes(
        _ reviewNodeIDs: [GitHubNodeID],
        pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        in database: Database
    ) throws {
        for reviewNodeID in reviewNodeIDs {
            let conflictingReviewCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM reviews
                    WHERE github_node_id = ? AND pull_request_node_id <> ?
                    """,
                arguments: [reviewNodeID.rawValue, pullRequestNodeID.rawValue]
            ) ?? 0
            let conflictingNodeCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM github_nodes AS review_node
                    JOIN github_nodes AS pull_request_node
                      ON pull_request_node.github_node_id = ?
                    WHERE review_node.github_node_id = ?
                      AND (
                        review_node.account_id <> ?
                        OR review_node.account_id <> pull_request_node.account_id
                        OR review_node.organization_id <> pull_request_node.organization_id
                        OR review_node.repository_id IS NOT pull_request_node.repository_id
                        OR review_node.kind <> ?
                      )
                    """,
                arguments: [
                    pullRequestNodeID.rawValue,
                    reviewNodeID.rawValue,
                    accountID.rawValue,
                    GitHubContentKind.pullRequestReview.rawValue
                ]
            ) ?? 0
            guard conflictingReviewCount == 0, conflictingNodeCount == 0 else {
                throw PullRequestReviewRepositoryError.reviewNodeScopeMismatch
            }
        }
    }

    private nonisolated static func save(
        _ review: GitHubPullRequestReviewDTO,
        reviewNodeID: GitHubNodeID,
        pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        observedAtMilliseconds: Int64,
        in database: Database
    ) throws {
        let submittedAtMilliseconds = review.submittedAt.map(milliseconds)
        let reviewTimestamp = submittedAtMilliseconds ?? observedAtMilliseconds
        try database.execute(
            sql: """
                INSERT INTO github_nodes (
                    github_node_id, account_id, organization_id, repository_id, kind,
                    numeric_id, number, title, state, html_url, body_markdown, author_id,
                    created_at_ms, updated_at_ms, closed_at_ms, merged_at_ms,
                    source_revision, last_observed_at_ms, accessibility_state
                )
                SELECT
                    ?, account_id, organization_id, repository_id, ?,
                    ?, NULL, 'Pull request review', 'unknown', html_url, ?, NULL,
                    ?, ?, NULL, NULL, ?, ?, 'accessible'
                FROM github_nodes
                WHERE github_node_id = ? AND account_id = ? AND kind = ?
                ON CONFLICT(github_node_id) DO UPDATE SET
                    repository_id = excluded.repository_id,
                    kind = excluded.kind,
                    numeric_id = excluded.numeric_id,
                    title = excluded.title,
                    state = excluded.state,
                    html_url = excluded.html_url,
                    body_markdown = excluded.body_markdown,
                    updated_at_ms = excluded.updated_at_ms,
                    source_revision = excluded.source_revision,
                    last_observed_at_ms = excluded.last_observed_at_ms,
                    accessibility_state = excluded.accessibility_state
                """,
            arguments: [
                reviewNodeID.rawValue,
                GitHubContentKind.pullRequestReview.rawValue,
                String(review.id),
                review.body,
                reviewTimestamp,
                reviewTimestamp,
                "\(review.id):\(review.nodeID):\(review.state):\(reviewTimestamp)",
                observedAtMilliseconds,
                pullRequestNodeID.rawValue,
                accountID.rawValue,
                GitHubContentKind.pullRequest.rawValue
            ]
        )
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
                submittedAtMilliseconds,
                observedAtMilliseconds
            ]
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
