import Foundation
import GRDB

enum DiscussionRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case repositoryScopeMismatch
}

actor DiscussionRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func replace(
        _ discussions: [GitHubDiscussionRecord],
        rawPages: [GitHubDiscussionRawPage],
        accountID: AccountID,
        organization: GitHubOrganization,
        repositoryID: RepositoryID,
        observedAt: Date,
        parserVersion: Int = 1,
        coverageRecords: [CoverageRecord] = []
    ) async throws {
        guard accountID == vault.accountID else { throw DiscussionRepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateScope(accountID: accountID, organization: organization, repositoryID: repositoryID, in: database)
            try discussions.forEach(Self.validate)
            for page in rawPages {
                try RawAPISnapshotRepository.save(
                    .init(id: .make(), accountID: accountID, githubNodeID: nil, endpoint: page.endpoint,
                          eTag: nil, parserVersion: parserVersion, observedAt: observedAt, payload: page.payload),
                    in: database
                )
            }
            let identifiers = Set(discussions.map(\.nodeID))
            guard identifiers.count == discussions.count else { throw GitHubDiscussionNormalizationError.duplicateDiscussionID }
            for discussion in discussions {
                try GitHubNodeRepository.save(
                    .init(nodeID: discussion.nodeID, accountID: accountID, organizationID: organization.id,
                          repositoryID: repositoryID, kind: .discussion, numericID: nil, number: discussion.number,
                          title: discussion.title, state: discussion.state, url: discussion.url, bodyMarkdown: discussion.body,
                          authorID: nil, createdAt: discussion.createdAt, updatedAt: discussion.updatedAt,
                          closedAt: discussion.closedAt, mergedAt: nil, sourceRevision: discussion.updatedAt.ISO8601Format(),
                          observedAt: observedAt, accessibility: .accessible),
                    in: database
                )
                try database.execute(
                    sql: """
                    INSERT INTO discussions (github_node_id, category_name, answer_comment_node_id, comments_count, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(github_node_id) DO UPDATE SET
                      category_name = excluded.category_name, answer_comment_node_id = excluded.answer_comment_node_id,
                      comments_count = excluded.comments_count, updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [discussion.nodeID.rawValue, discussion.categoryName, discussion.answerCommentNodeID?.rawValue,
                                discussion.commentsCount, Self.milliseconds(discussion.updatedAt)]
                )
            }
            try Self.deleteAbsent(discussions.map(\.nodeID), accountID: accountID, repositoryID: repositoryID, in: database)
            for record in coverageRecords {
                try CoverageRepository.save(
                    record,
                    attemptedAt: observedAt,
                    expectedAccountID: accountID,
                    in: database
                )
            }
        }
    }

    func recordFailedPage(
        _ page: GitHubDiscussionRawPage,
        accountID: AccountID,
        observedAt: Date,
        diagnostic: String,
        parserVersion: Int = 1
    ) async throws {
        try await recordFailure(
            pages: [page],
            accountID: accountID,
            observedAt: observedAt,
            diagnostic: diagnostic,
            parserVersion: parserVersion,
            coverageRecord: nil
        )
    }

    /// Stores replay provenance and its scoped coverage transition together.
    /// A failure in either write rolls the whole failure record back, preventing
    /// coverage from claiming evidence that was not retained.
    func recordFailure(
        pages: [GitHubDiscussionRawPage],
        accountID: AccountID,
        observedAt: Date,
        diagnostic: String,
        parserVersion: Int = 1,
        coverageRecord: CoverageRecord?
    ) async throws {
        guard accountID == vault.accountID else { throw DiscussionRepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            for page in pages {
                let snapshot = RawAPISnapshot(id: .make(), accountID: accountID, githubNodeID: nil, endpoint: page.endpoint,
                                              eTag: nil, parserVersion: parserVersion, observedAt: observedAt, payload: page.payload)
                try RawAPISnapshotRepository.save(snapshot, in: database)
                try NormalizationFailureRepository.record(
                    .init(id: UUID(), accountID: accountID, rawSnapshotID: snapshot.id, githubNodeID: nil,
                          endpoint: page.endpoint, parserVersion: parserVersion, occurredAt: observedAt,
                          redactedDiagnostic: String(diagnostic.prefix(4_096))),
                    in: database
                )
            }
            if let coverageRecord {
                try CoverageRepository.save(
                    coverageRecord,
                    attemptedAt: observedAt,
                    expectedAccountID: accountID,
                    in: database
                )
            }
        }
    }

    private nonisolated static func validateScope(
        accountID: AccountID, organization: GitHubOrganization, repositoryID: RepositoryID, in database: Database
    ) throws {
        let organizationCount = try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM account_organizations
            JOIN organizations ON organizations.id = account_organizations.organization_id
            WHERE account_organizations.account_id = ? AND organizations.id = ?
              AND organizations.github_organization_id = ? AND lower(organizations.login) = lower(?)
            """, arguments: [accountID.rawValue, organization.id.rawValue, String(organization.githubOrganizationID), organization.login]) ?? 0
        guard organizationCount == 1 else { throw DiscussionRepositoryError.organizationScopeMismatch }
        let repositoryCount = try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM repositories
            JOIN account_repository_access ON account_repository_access.repository_id = repositories.id
            WHERE repositories.id = ? AND repositories.organization_id = ?
              AND account_repository_access.account_id = ?
              AND account_repository_access.access_state = 'available'
            """, arguments: [repositoryID.rawValue, organization.id.rawValue, accountID.rawValue]) ?? 0
        guard repositoryCount == 1 else { throw DiscussionRepositoryError.repositoryScopeMismatch }
    }

    private nonisolated static func deleteAbsent(
        _ identifiers: [GitHubNodeID], accountID: AccountID, repositoryID: RepositoryID, in database: Database
    ) throws {
        if identifiers.isEmpty {
            try database.execute(sql: "DELETE FROM github_nodes WHERE account_id = ? AND repository_id = ? AND kind = ?",
                                 arguments: [accountID.rawValue, repositoryID.rawValue, GitHubContentKind.discussion.rawValue])
            return
        }

        let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
        var arguments: [DatabaseValueConvertible?] = [accountID.rawValue, repositoryID.rawValue, GitHubContentKind.discussion.rawValue]
        arguments.append(contentsOf: identifiers.map(\.rawValue))
        try database.execute(sql: """
            DELETE FROM github_nodes
            WHERE account_id = ? AND repository_id = ? AND kind = ? AND github_node_id NOT IN (\(placeholders))
            """, arguments: StatementArguments(arguments))
    }

    private nonisolated static func validate(_ discussion: GitHubDiscussionRecord) throws {
        guard discussion.number > 0,
              !discussion.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              discussion.createdAt <= discussion.updatedAt,
              discussion.closedAt.map({ $0 >= discussion.createdAt }) ?? true,
              discussion.commentsCount >= 0,
              discussion.url.scheme == "https",
              discussion.url.host == "github.com"
        else {
            throw GitHubDiscussionNormalizationError.invalidDiscussion
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
