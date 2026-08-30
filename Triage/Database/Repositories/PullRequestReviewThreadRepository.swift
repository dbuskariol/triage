import Foundation
import GRDB

enum PullRequestReviewThreadRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case pullRequestScopeMismatch
    case duplicateThreadNodeID
    case duplicateCommentNodeID
    case invalidRecord
}

actor PullRequestReviewThreadRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func replace(
        pullRequestNodeID: GitHubNodeID,
        organizationID: OrganizationID,
        repositoryID: RepositoryID,
        currentUserNodeID: GitHubNodeID,
        inventory: GitHubPullRequestReviewThreadInventory,
        observedAt: Date = .now
    ) async throws {
        try await vault.writeTransaction { database in
            try Self.replace(
                pullRequestNodeID: pullRequestNodeID,
                accountID: vault.accountID,
                organizationID: organizationID,
                repositoryID: repositoryID,
                currentUserNodeID: currentUserNodeID,
                records: inventory.records,
                rawPages: inventory.rawPages,
                observedAt: observedAt,
                in: database
            )
        }
    }

    static func replace(
        pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: RepositoryID,
        currentUserNodeID: GitHubNodeID,
        records: [PullRequestReviewThreadRecord],
        rawPages: [GitHubPullRequestReviewThreadRawPage] = [],
        observedAt: Date,
        in database: Database
    ) throws {
        try validate(records)
        try validatePullRequest(
            pullRequestNodeID,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            in: database
        )

        for page in rawPages {
            try RawAPISnapshotRepository.save(
                RawAPISnapshot(
                    id: .make(),
                    accountID: accountID,
                    githubNodeID: pullRequestNodeID,
                    endpoint: page.endpoint,
                    eTag: nil,
                    parserVersion: 1,
                    observedAt: observedAt,
                    payload: page.payload
                ),
                in: database
            )
        }

        let observedAtMilliseconds = milliseconds(observedAt)
        let actors = Dictionary(
            records.flatMap(\.comments).compactMap(\.author).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        for actor in actors.values {
            try ActorRepository.save(actor, observedAtMilliseconds: observedAtMilliseconds, in: database)
        }

        let pullRequestURL = try URL.fetchOne(
            database,
            sql: "SELECT html_url FROM github_nodes WHERE github_node_id = ?",
            arguments: [pullRequestNodeID.rawValue]
        )
        guard let pullRequestURL else {
            throw PullRequestReviewThreadRepositoryError.pullRequestScopeMismatch
        }
        for record in records {
            let comments = record.comments
            let createdAt = comments.map(\.createdAt).min() ?? record.updatedAt
            let threadURL = comments.last?.url ?? pullRequestURL
            try GitHubNodeRepository.save(
                NormalizedGitHubNode(
                    nodeID: record.nodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: repositoryID,
                    kind: .pullRequestReviewThread,
                    numericID: nil,
                    number: nil,
                    title: "Review thread",
                    state: .unknown,
                    url: threadURL,
                    bodyMarkdown: nil,
                    authorID: nil,
                    createdAt: createdAt,
                    updatedAt: record.updatedAt,
                    closedAt: nil,
                    mergedAt: nil,
                    sourceRevision: record.updatedAt.ISO8601Format(),
                    observedAt: observedAt,
                    accessibility: .accessible
                ),
                in: database
            )
            for comment in comments {
                try GitHubNodeRepository.save(
                    NormalizedGitHubNode(
                        nodeID: comment.nodeID,
                        accountID: accountID,
                        organizationID: organizationID,
                        repositoryID: repositoryID,
                        kind: .pullRequestReviewComment,
                        numericID: nil,
                        number: nil,
                        title: "Review comment",
                        state: .unknown,
                        url: comment.url,
                        bodyMarkdown: comment.body,
                        authorID: comment.author?.id,
                        createdAt: comment.createdAt,
                        updatedAt: comment.updatedAt,
                        closedAt: nil,
                        mergedAt: nil,
                        sourceRevision: comment.updatedAt.ISO8601Format(),
                        observedAt: observedAt,
                        accessibility: .accessible
                    ),
                    in: database
                )
            }
        }

        try pruneStaleNodes(
            pullRequestNodeID: pullRequestNodeID,
            records: records,
            in: database
        )
        for record in records {
            let latestAuthor = record.comments.max { lhs, rhs in
                lhs.createdAt == rhs.createdAt
                    ? lhs.nodeID.rawValue < rhs.nodeID.rawValue
                    : lhs.createdAt < rhs.createdAt
            }?.author?.nodeID
            let requiresResponse = !record.isResolved
                && !record.isOutdated
                && latestAuthor != nil
                && latestAuthor != currentUserNodeID
            try database.execute(
                sql: """
                    INSERT INTO review_threads (
                        github_node_id, pull_request_node_id, is_resolved,
                        requires_current_user_response, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(github_node_id) DO UPDATE SET
                        pull_request_node_id = excluded.pull_request_node_id,
                        is_resolved = excluded.is_resolved,
                        requires_current_user_response = excluded.requires_current_user_response,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    record.nodeID.rawValue,
                    pullRequestNodeID.rawValue,
                    record.isResolved,
                    requiresResponse,
                    milliseconds(record.updatedAt)
                ]
            )
            for comment in record.comments {
                try database.execute(
                    sql: """
                        INSERT INTO comments (
                            github_node_id, parent_node_id, author_id, kind, body_markdown,
                            created_at_ms, updated_at_ms, html_url
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(github_node_id) DO UPDATE SET
                            parent_node_id = excluded.parent_node_id,
                            author_id = excluded.author_id,
                            kind = excluded.kind,
                            body_markdown = excluded.body_markdown,
                            created_at_ms = excluded.created_at_ms,
                            updated_at_ms = excluded.updated_at_ms,
                            html_url = excluded.html_url
                        """,
                    arguments: [
                        comment.nodeID.rawValue,
                        record.nodeID.rawValue,
                        comment.author?.id.rawValue,
                        GitHubContentKind.pullRequestReviewComment.rawValue,
                        comment.body,
                        milliseconds(comment.createdAt),
                        milliseconds(comment.updatedAt),
                        comment.url.absoluteString
                    ]
                )
            }
        }
        try database.execute(
            sql: """
                UPDATE pull_requests
                SET unresolved_thread_count = (
                    SELECT COUNT(*) FROM review_threads
                    WHERE pull_request_node_id = ? AND is_resolved = 0
                ), updated_at_ms = ?
                WHERE github_node_id = ?
                """,
            arguments: [pullRequestNodeID.rawValue, observedAtMilliseconds, pullRequestNodeID.rawValue]
        )
    }

    private static func validate(_ records: [PullRequestReviewThreadRecord]) throws {
        var threads = Set<GitHubNodeID>()
        var comments = Set<GitHubNodeID>()
        for record in records {
            guard threads.insert(record.nodeID).inserted else {
                throw PullRequestReviewThreadRepositoryError.duplicateThreadNodeID
            }
            guard record.updatedAt.isFinite else {
                throw PullRequestReviewThreadRepositoryError.invalidRecord
            }
            for comment in record.comments {
                guard !threads.contains(comment.nodeID), comments.insert(comment.nodeID).inserted else {
                    throw PullRequestReviewThreadRepositoryError.duplicateCommentNodeID
                }
                guard comment.createdAt.isFinite, comment.updatedAt.isFinite,
                      comment.createdAt <= comment.updatedAt,
                      comment.updatedAt <= record.updatedAt,
                      comment.url.scheme == "https", comment.url.host == "github.com"
                else {
                    throw PullRequestReviewThreadRepositoryError.invalidRecord
                }
            }
        }
    }

    private static func validatePullRequest(
        _ pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: RepositoryID,
        in database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM pull_requests
                JOIN github_nodes ON github_nodes.github_node_id = pull_requests.github_node_id
                WHERE pull_requests.github_node_id = ?
                  AND github_nodes.account_id = ?
                  AND github_nodes.organization_id = ?
                  AND github_nodes.repository_id = ?
                """,
            arguments: [
                pullRequestNodeID.rawValue,
                accountID.rawValue,
                organizationID.rawValue,
                repositoryID.rawValue
            ]
        ) ?? 0
        guard count == 1 else {
            throw PullRequestReviewThreadRepositoryError.pullRequestScopeMismatch
        }
    }

    private static func pruneStaleNodes(
        pullRequestNodeID: GitHubNodeID,
        records: [PullRequestReviewThreadRecord],
        in database: Database
    ) throws {
        let threadIDs = records.map(\.nodeID.rawValue)
        let commentIDs = records.flatMap(\.comments).map(\.nodeID.rawValue)
        let threadPlaceholders = Array(repeating: "?", count: max(threadIDs.count, 1)).joined(separator: ", ")
        let commentPlaceholders = Array(repeating: "?", count: max(commentIDs.count, 1)).joined(separator: ", ")
        let retainedThreads = threadIDs.isEmpty ? [""] : threadIDs
        let retainedComments = commentIDs.isEmpty ? [""] : commentIDs
        try database.execute(
            sql: """
                DELETE FROM github_nodes
                WHERE github_node_id IN (
                    SELECT comments.github_node_id
                    FROM comments
                    JOIN review_threads ON review_threads.github_node_id = comments.parent_node_id
                    WHERE review_threads.pull_request_node_id = ?
                      AND comments.github_node_id NOT IN (\(commentPlaceholders))
                )
                """,
            arguments: StatementArguments([pullRequestNodeID.rawValue] + retainedComments)
        )
        try database.execute(
            sql: """
                DELETE FROM github_nodes
                WHERE github_node_id IN (
                    SELECT github_node_id
                    FROM review_threads
                    WHERE pull_request_node_id = ?
                      AND github_node_id NOT IN (\(threadPlaceholders))
                )
                """,
            arguments: StatementArguments([pullRequestNodeID.rawValue] + retainedThreads)
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private extension Date {
    var isFinite: Bool {
        timeIntervalSinceReferenceDate.isFinite
    }
}
