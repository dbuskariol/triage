import Foundation
import GRDB

enum GitHubNodeRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
}

enum GitHubNodeAccessibility: String, Sendable {
    case accessible
    case inaccessible
}

struct NormalizedGitHubNode: Sendable {
    let nodeID: GitHubNodeID
    let accountID: AccountID
    let organizationID: OrganizationID
    let repositoryID: RepositoryID?
    let kind: GitHubContentKind
    let numericID: String?
    let number: Int?
    let title: String
    let state: GitHubItemState
    let url: URL
    let bodyMarkdown: String?
    let authorID: ActorID?
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let mergedAt: Date?
    let sourceRevision: String
    /// Exact immutable head commit for PR-only sources such as status checks.
    /// This is deliberately distinct from the node's `updatedAt` revision.
    let pullRequestHeadCommitSHA: String?
    let observedAt: Date
    let accessibility: GitHubNodeAccessibility

    init(
        nodeID: GitHubNodeID,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: RepositoryID?,
        kind: GitHubContentKind,
        numericID: String?,
        number: Int?,
        title: String,
        state: GitHubItemState,
        url: URL,
        bodyMarkdown: String?,
        authorID: ActorID?,
        createdAt: Date,
        updatedAt: Date,
        closedAt: Date?,
        mergedAt: Date?,
        sourceRevision: String,
        pullRequestHeadCommitSHA: String? = nil,
        observedAt: Date,
        accessibility: GitHubNodeAccessibility
    ) {
        self.nodeID = nodeID
        self.accountID = accountID
        self.organizationID = organizationID
        self.repositoryID = repositoryID
        self.kind = kind
        self.numericID = numericID
        self.number = number
        self.title = title
        self.state = state
        self.url = url
        self.bodyMarkdown = bodyMarkdown
        self.authorID = authorID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.mergedAt = mergedAt
        self.sourceRevision = sourceRevision
        self.pullRequestHeadCommitSHA = pullRequestHeadCommitSHA
        self.observedAt = observedAt
        self.accessibility = accessibility
    }
}

actor GitHubNodeRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ node: NormalizedGitHubNode) async throws {
        guard node.accountID == vault.accountID else {
            throw GitHubNodeRepositoryError.accountScopeMismatch
        }
        try await vault.write { database in
            try Self.save(node, in: database)
        }
    }

    nonisolated static func save(_ node: NormalizedGitHubNode, in database: Database) throws {
        let values = Values(node)
        try database.execute(
            sql: """
                INSERT INTO github_nodes (
                    github_node_id, account_id, organization_id, repository_id, kind, numeric_id, number,
                    title, state, html_url, body_markdown, author_id, created_at_ms, updated_at_ms,
                    closed_at_ms, merged_at_ms, source_revision, pull_request_head_commit_sha, last_observed_at_ms, accessibility_state
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(github_node_id) DO UPDATE SET
                    repository_id = excluded.repository_id,
                    kind = excluded.kind,
                    numeric_id = excluded.numeric_id,
                    number = excluded.number,
                    title = excluded.title,
                    state = excluded.state,
                    html_url = excluded.html_url,
                    body_markdown = excluded.body_markdown,
                    author_id = excluded.author_id,
                    updated_at_ms = excluded.updated_at_ms,
                    closed_at_ms = excluded.closed_at_ms,
                    merged_at_ms = excluded.merged_at_ms,
                    source_revision = excluded.source_revision,
                    pull_request_head_commit_sha = excluded.pull_request_head_commit_sha,
                    last_observed_at_ms = excluded.last_observed_at_ms,
                    accessibility_state = excluded.accessibility_state
                """,
            arguments: values.arguments
        )
    }

    private struct Values: Sendable {
        let arguments: StatementArguments

        init(_ node: NormalizedGitHubNode) {
            arguments = [
                node.nodeID.rawValue,
                node.accountID.rawValue,
                node.organizationID.rawValue,
                node.repositoryID?.rawValue,
                node.kind.rawValue,
                node.numericID,
                node.number,
                node.title,
                node.state.rawValue,
                node.url.absoluteString,
                node.bodyMarkdown,
                node.authorID?.rawValue,
                Self.milliseconds(node.createdAt),
                Self.milliseconds(node.updatedAt),
                node.closedAt.map(Self.milliseconds),
                node.mergedAt.map(Self.milliseconds),
                node.sourceRevision,
                node.pullRequestHeadCommitSHA,
                Self.milliseconds(node.observedAt),
                node.accessibility.rawValue
            ]
        }

        private static func milliseconds(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince1970 * 1_000).rounded())
        }
    }
}
