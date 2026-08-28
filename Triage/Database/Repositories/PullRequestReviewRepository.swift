import Foundation
import GRDB

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
            try database.execute(
                sql: """
                    INSERT INTO reviews (
                        github_node_id, pull_request_node_id, author_id, state, body_markdown,
                        submitted_at_ms, html_url, updated_at_ms
                    ) VALUES (?, ?, NULL, ?, ?, ?, NULL, ?)
                    ON CONFLICT(github_node_id) DO UPDATE SET
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
                    review.submittedAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) },
                    observedAtMilliseconds
                ]
            )
        }
    }
}
