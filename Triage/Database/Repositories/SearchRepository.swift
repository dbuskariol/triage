import Foundation
import GRDB

enum SearchRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case documentScopeMismatch
}

struct SearchDocument: Sendable {
    let accountID: AccountID
    let organizationID: OrganizationID
    let workItemID: WorkItemID
    let nodeID: GitHubNodeID
    let title: String
    let body: String
    let repository: String
    let labels: String
    let people: String
    let projectValues: String
    let actionText: String
    let localNote: String
}

struct SearchResult: Sendable, Equatable {
    let documentID: Int64
    let workItemID: WorkItemID?
    let nodeID: GitHubNodeID?
    let rank: Double
}

actor SearchRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    private func replace(
        _ documents: [SearchDocument],
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws {
        try ensureAccountScope(accountID)
        guard documents.allSatisfy({
            $0.accountID == accountID && $0.organizationID == organizationID
        }) else {
            throw SearchRepositoryError.documentScopeMismatch
        }
        let indexedAt = Self.milliseconds(Date.now)
        try await vault.write { database in
            try database.execute(
                sql: """
                    DELETE FROM search_documents
                    WHERE rowid IN (
                        SELECT id FROM search_document_metadata
                        WHERE account_id = ? AND organization_id = ?
                    )
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
            try database.execute(
                sql: """
                    DELETE FROM search_document_metadata
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )

            for document in documents {
                try database.execute(
                    sql: """
                        INSERT INTO search_documents (
                            title, body, repository, labels, people, project_values, action_text, local_note
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        document.title, document.body, document.repository,
                        document.labels, document.people, document.projectValues,
                        document.actionText, document.localNote
                    ]
                )
                let documentID = database.lastInsertedRowID
                try database.execute(
                    sql: """
                        INSERT INTO search_document_metadata (
                            id, account_id, organization_id, work_item_id, github_node_id, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        documentID, document.accountID.rawValue, document.organizationID.rawValue,
                        document.workItemID.rawValue, document.nodeID.rawValue,
                        indexedAt
                    ]
                )
            }
        }
    }

    func rebuild(accountID: AccountID, organizationID: OrganizationID) async throws {
        try ensureAccountScope(accountID)
        let documents = try await vault.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        work_items.id AS work_item_id,
                        work_items.primary_node_id,
                        github_nodes.title,
                        COALESCE(github_nodes.body_markdown, '') || ' ' || COALESCE((
                            SELECT group_concat(comments.body_markdown, ' ')
                            FROM comments
                            WHERE comments.parent_node_id = work_items.primary_node_id
                        ), '') || ' ' || COALESCE((
                            SELECT group_concat(reviews.body_markdown, ' ')
                            FROM reviews
                            WHERE reviews.pull_request_node_id = work_items.primary_node_id
                        ), '') AS body,
                        COALESCE(repositories.owner_login || '/' || repositories.name, '') AS repository,
                        COALESCE((
                            SELECT group_concat(label_names.value, ' ')
                            FROM (
                                SELECT label_names_json
                                FROM issues
                                WHERE issues.github_node_id = work_items.primary_node_id
                                UNION ALL
                                SELECT label_names_json
                                FROM pull_requests
                                WHERE pull_requests.github_node_id = work_items.primary_node_id
                            ) AS content_labels
                            JOIN json_each(CAST(content_labels.label_names_json AS TEXT)) AS label_names
                        ), '') AS labels,
                        COALESCE((
                            SELECT group_concat(login, ' ')
                            FROM (
                                SELECT actors.login
                                FROM github_nodes AS authored_node
                                JOIN actors ON actors.id = authored_node.author_id
                                WHERE authored_node.github_node_id = work_items.primary_node_id
                                UNION
                                SELECT actors.login
                                FROM comments
                                JOIN actors ON actors.id = comments.author_id
                                WHERE comments.parent_node_id = work_items.primary_node_id
                                UNION
                                SELECT actors.login
                                FROM reviews
                                JOIN actors ON actors.id = reviews.author_id
                                WHERE reviews.pull_request_node_id = work_items.primary_node_id
                            )
                        ), '') AS people,
                        COALESCE((
                            SELECT group_concat(
                                COALESCE(project_field_values.field_name, '') || ' ' ||
                                COALESCE(project_field_values.display_value, '') || ' ' ||
                                COALESCE(CAST(project_field_values.date_value_ms AS TEXT), ''),
                                ' '
                            )
                            FROM project_items
                            JOIN project_field_values
                                ON project_field_values.project_item_node_id = project_items.github_node_id
                            WHERE project_items.content_node_id = work_items.primary_node_id
                        ), '') AS project_values,
                        COALESCE((
                            SELECT group_concat(
                                action_items.title || ' ' || COALESCE(action_items.detail, ''),
                                ' '
                            )
                            FROM action_items
                            WHERE action_items.work_item_id = work_items.id
                        ), '') AS action_text,
                        COALESCE(workflow_states.local_note, '') AS local_note
                    FROM work_items
                    JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                    LEFT JOIN repositories ON repositories.id = github_nodes.repository_id
                    LEFT JOIN workflow_states ON workflow_states.work_item_id = work_items.id
                    WHERE work_items.account_id = ? AND work_items.organization_id = ?
                    ORDER BY work_items.id
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
            return rows.compactMap { row -> SearchDocument? in
                guard let workItemID = WorkItemID(rawValue: row["work_item_id"]),
                      let nodeID = GitHubNodeID(rawValue: row["primary_node_id"])
                else {
                    return nil
                }
                return SearchDocument(
                    accountID: accountID,
                    organizationID: organizationID,
                    workItemID: workItemID,
                    nodeID: nodeID,
                    title: row["title"],
                    body: row["body"],
                    repository: row["repository"],
                    labels: row["labels"],
                    people: row["people"],
                    projectValues: row["project_values"],
                    actionText: row["action_text"],
                    localNote: row["local_note"]
                )
            }
        }
        try await replace(documents, accountID: accountID, organizationID: organizationID)
    }

    func search(
        _ query: String,
        accountID: AccountID,
        organizationID: OrganizationID,
        limit: Int = 100
    ) async throws -> [SearchResult] {
        try ensureAccountScope(accountID)
        guard let matchQuery = Self.matchQuery(for: query) else { return [] }
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT metadata.id, metadata.work_item_id, metadata.github_node_id, bm25(search_documents) AS rank
                    FROM search_documents
                    JOIN search_document_metadata AS metadata ON metadata.id = search_documents.rowid
                    WHERE search_documents MATCH ?
                      AND metadata.account_id = ?
                      AND metadata.organization_id = ?
                    ORDER BY rank, metadata.updated_at_ms DESC, metadata.id
                    LIMIT ?
                    """,
                arguments: [matchQuery, accountID.rawValue, organizationID.rawValue, min(max(limit, 1), 100)]
            ).map { row in
                SearchResult(
                    documentID: row["id"],
                    workItemID: (row["work_item_id"] as String?).flatMap(WorkItemID.init(rawValue:)),
                    nodeID: (row["github_node_id"] as String?).flatMap(GitHubNodeID.init(rawValue:)),
                    rank: row["rank"]
                )
            }
        }
    }

    private func ensureAccountScope(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw SearchRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func matchQuery(for query: String) -> String? {
        let terms = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(12)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " AND ")
    }
}
