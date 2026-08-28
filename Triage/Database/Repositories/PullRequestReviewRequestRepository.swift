import Foundation
import GRDB

enum PullRequestReviewRequestRepositoryError: Error, Equatable, Sendable {
    case pullRequestNodeScopeMismatch
    case invalidReviewerNodeID
    case duplicateReviewerNodeID
}

actor PullRequestReviewRequestRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    /// Replaces requested reviewers from GitHub's complete, non-paginated
    /// requested-reviewers response.
    func replace(
        _ requestedReviewers: GitHubRequestedReviewersDTO,
        pullRequestNodeID: GitHubNodeID,
        observedAt: Date = .now
    ) async throws {
        try await vault.writeTransaction { database in
            try Self.replace(
                requestedReviewers,
                pullRequestNodeID: pullRequestNodeID,
                accountID: vault.accountID,
                observedAtMilliseconds: Self.milliseconds(observedAt),
                in: database
            )
        }
    }

    nonisolated static func replace(
        _ requestedReviewers: GitHubRequestedReviewersDTO,
        pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        observedAtMilliseconds: Int64,
        in database: Database
    ) throws {
        let reviewers = try normalizedReviewers(from: requestedReviewers)
        try validatePullRequestNodeScope(pullRequestNodeID, accountID: accountID, in: database)
        try database.execute(
            sql: "DELETE FROM review_requests WHERE pull_request_node_id = ?",
            arguments: [pullRequestNodeID.rawValue]
        )
        for reviewer in reviewers {
            try database.execute(
                sql: """
                    INSERT INTO review_requests (
                        pull_request_node_id, requested_reviewer_node_id, reviewer_kind, requested_at_ms
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    pullRequestNodeID.rawValue,
                    reviewer.nodeID.rawValue,
                    reviewer.kind,
                    observedAtMilliseconds
                ]
            )
        }
    }

    private nonisolated static func normalizedReviewers(
        from requestedReviewers: GitHubRequestedReviewersDTO
    ) throws -> [(nodeID: GitHubNodeID, kind: String)] {
        let reviewers = try requestedReviewers.users.map {
            try reviewer($0, kind: "user")
        } + requestedReviewers.teams.map {
            try reviewer($0, kind: "team")
        }
        guard Set(reviewers.map(\.nodeID)).count == reviewers.count else {
            throw PullRequestReviewRequestRepositoryError.duplicateReviewerNodeID
        }
        return reviewers
    }

    private nonisolated static func reviewer(
        _ reviewer: GitHubRequestedReviewersDTO.Reviewer,
        kind: String
    ) throws -> (nodeID: GitHubNodeID, kind: String) {
        guard let nodeID = GitHubNodeID(rawValue: reviewer.nodeID) else {
            throw PullRequestReviewRequestRepositoryError.invalidReviewerNodeID
        }
        return (nodeID, kind)
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
            throw PullRequestReviewRequestRepositoryError.pullRequestNodeScopeMismatch
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
