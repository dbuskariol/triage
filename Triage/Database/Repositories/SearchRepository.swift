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
    /// Search is an acceleration structure, not an unbounded second copy of
    /// the account vault. Keep its persisted document size aligned with the
    /// derived-intelligence contract.
    nonisolated static let maximumDocumentBytes = 128 * 1_024
    nonisolated static let maximumMatchQueryBytes = 4 * 1_024

    private nonisolated static let maximumSearchTerms = 12
    private nonisolated static let maximumSearchTermBytes = 256
    private nonisolated static let maximumTitleBytes = 8 * 1_024
    private nonisolated static let maximumBodyBytes = 64 * 1_024
    private nonisolated static let maximumRepositoryBytes = 4 * 1_024
    private nonisolated static let maximumLabelsBytes = 8 * 1_024
    private nonisolated static let maximumPeopleBytes = 8 * 1_024
    private nonisolated static let maximumProjectValuesBytes = 16 * 1_024
    private nonisolated static let maximumActionTextBytes = 12 * 1_024
    private nonisolated static let maximumLocalNoteBytes = 8 * 1_024

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
            try Task.checkCancellation()
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
                try Task.checkCancellation()
                let boundedDocument = Self.bounded(document)
                try database.execute(
                    sql: """
                        INSERT INTO search_documents (
                            title, body, repository, labels, people, project_values, action_text, local_note
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        boundedDocument.title, boundedDocument.body, boundedDocument.repository,
                        boundedDocument.labels, boundedDocument.people, boundedDocument.projectValues,
                        boundedDocument.actionText, boundedDocument.localNote
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
        try Task.checkCancellation()
        let documents: [SearchDocument] = try await vault.read { database -> [SearchDocument] in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        work_items.id AS work_item_id,
                        work_items.primary_node_id,
                        COALESCE(substr(github_nodes.title, 1, 8192), '') AS title,
                        COALESCE(substr(github_nodes.body_markdown, 1, 80000), '') || ' ' || COALESCE((
                            SELECT group_concat(body_markdown, ' ')
                            FROM (
                                SELECT substr(comments.body_markdown, 1, 4096) AS body_markdown
                                FROM comments
                                WHERE comments.parent_node_id = work_items.primary_node_id
                                ORDER BY comments.updated_at_ms DESC, comments.github_node_id
                                LIMIT 32
                            )
                        ), '') || ' ' || COALESCE((
                            SELECT group_concat(body_markdown, ' ')
                            FROM (
                                SELECT substr(reviews.body_markdown, 1, 4096) AS body_markdown
                                FROM reviews
                                WHERE reviews.pull_request_node_id = work_items.primary_node_id
                                ORDER BY reviews.updated_at_ms DESC, reviews.github_node_id
                                LIMIT 32
                            )
                        ), '') AS body,
                        substr(COALESCE(repositories.owner_login || '/' || repositories.name, ''), 1, 4096) AS repository,
                        COALESCE((
                            SELECT group_concat(value, ' ')
                            FROM (
                                SELECT substr(label_names.value, 1, 256) AS value
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
                                ORDER BY value
                                LIMIT 32
                            )
                        ), '') AS labels,
                        COALESCE((
                            SELECT group_concat(login, ' ')
                            FROM (
                                SELECT substr(actors.login, 1, 256) AS login
                                FROM github_nodes AS authored_node
                                JOIN actors ON actors.id = authored_node.author_id
                                WHERE authored_node.github_node_id = work_items.primary_node_id
                                UNION ALL
                                SELECT substr(actors.login, 1, 256) AS login
                                FROM comments
                                JOIN actors ON actors.id = comments.author_id
                                WHERE comments.github_node_id IN (
                                    SELECT comment_candidates.github_node_id
                                    FROM comments AS comment_candidates
                                    WHERE comment_candidates.parent_node_id = work_items.primary_node_id
                                    ORDER BY comment_candidates.updated_at_ms DESC,
                                             comment_candidates.github_node_id
                                    LIMIT 32
                                )
                                UNION ALL
                                SELECT substr(actors.login, 1, 256) AS login
                                FROM reviews
                                JOIN actors ON actors.id = reviews.author_id
                                WHERE reviews.github_node_id IN (
                                    SELECT review_candidates.github_node_id
                                    FROM reviews AS review_candidates
                                    WHERE review_candidates.pull_request_node_id = work_items.primary_node_id
                                    ORDER BY review_candidates.updated_at_ms DESC,
                                             review_candidates.github_node_id
                                    LIMIT 32
                                )
                            )
                        ), '') AS people,
                        COALESCE((
                            SELECT group_concat(
                                field_name || ' ' || display_value || ' ' || date_value,
                                ' '
                            )
                            FROM (
                                SELECT
                                    substr(project_field_values.field_name, 1, 512) AS field_name,
                                    substr(COALESCE(project_field_values.display_value, ''), 1, 2048) AS display_value,
                                    substr(COALESCE(CAST(project_field_values.date_value_ms AS TEXT), ''), 1, 64) AS date_value
                                FROM project_items
                                JOIN project_field_values
                                    ON project_field_values.project_item_node_id = project_items.github_node_id
                                WHERE project_items.content_node_id = work_items.primary_node_id
                                ORDER BY project_items.updated_at_ms DESC,
                                         project_items.github_node_id,
                                         project_field_values.field_name
                                LIMIT 32
                            )
                        ), '') AS project_values,
                        COALESCE((
                            SELECT group_concat(action_text, ' ')
                            FROM (
                                SELECT substr(action_items.title || ' ' || COALESCE(action_items.detail, ''), 1, 4096) AS action_text
                                FROM action_items
                                WHERE action_items.work_item_id = work_items.id
                                ORDER BY action_items.updated_at_ms DESC, action_items.id
                                LIMIT 32
                            )
                        ), '') AS action_text,
                        COALESCE(substr(workflow_states.local_note, 1, 16000), '') AS local_note
                    FROM work_items
                    JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                    LEFT JOIN repositories ON repositories.id = github_nodes.repository_id
                    LEFT JOIN workflow_states ON workflow_states.work_item_id = work_items.id
                    WHERE work_items.account_id = ? AND work_items.organization_id = ?
                    ORDER BY work_items.id
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
            return try rows.compactMap { row -> SearchDocument? in
                try Task.checkCancellation()
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
        try Task.checkCancellation()
        try await replace(documents, accountID: accountID, organizationID: organizationID)
        try Task.checkCancellation()
    }

    func search(
        _ query: String,
        accountID: AccountID,
        organizationID: OrganizationID,
        limit: Int = 100
    ) async throws -> [SearchResult] {
        try ensureAccountScope(accountID)
        guard let matchQuery = Self.matchQuery(for: query) else { return [] }
        try Task.checkCancellation()
        let results: [SearchResult] = try await vault.read { database -> [SearchResult] in
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
                try Task.checkCancellation()
                return SearchResult(
                    documentID: row["id"],
                    workItemID: (row["work_item_id"] as String?).flatMap(WorkItemID.init(rawValue:)),
                    nodeID: (row["github_node_id"] as String?).flatMap(GitHubNodeID.init(rawValue:)),
                    rank: row["rank"]
                )
            }
        }
        try Task.checkCancellation()
        return results
    }

    private func ensureAccountScope(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw SearchRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func bounded(_ document: SearchDocument) -> SearchDocument {
        var remainingBytes = maximumDocumentBytes

        func field(_ value: String, maximumBytes: Int) -> String {
            let result = boundedUTF8(value, maximumBytes: min(maximumBytes, remainingBytes))
            remainingBytes -= result.utf8.count
            return result
        }

        return SearchDocument(
            accountID: document.accountID,
            organizationID: document.organizationID,
            workItemID: document.workItemID,
            nodeID: document.nodeID,
            title: field(document.title, maximumBytes: maximumTitleBytes),
            body: field(document.body, maximumBytes: maximumBodyBytes),
            repository: field(document.repository, maximumBytes: maximumRepositoryBytes),
            labels: field(document.labels, maximumBytes: maximumLabelsBytes),
            people: field(document.people, maximumBytes: maximumPeopleBytes),
            projectValues: field(document.projectValues, maximumBytes: maximumProjectValuesBytes),
            actionText: field(document.actionText, maximumBytes: maximumActionTextBytes),
            localNote: field(document.localNote, maximumBytes: maximumLocalNoteBytes)
        )
    }

    /// Truncates on Unicode-scalar boundaries so persisted FTS text is always
    /// valid UTF-8. The marker makes a bounded document distinguishable from a
    /// complete source field without retaining additional private content.
    private nonisolated static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        guard maximumBytes > 0 else { return "" }

        let marker = "…"
        guard maximumBytes > marker.utf8.count else {
            return String(bytes: marker.utf8.prefix(maximumBytes), encoding: .utf8) ?? ""
        }

        let contentBudget = maximumBytes - marker.utf8.count
        var scalars = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            guard byteCount + scalarBytes <= contentBudget else { break }
            scalars.append(scalar)
            byteCount += scalarBytes
        }
        return String(scalars) + marker
    }

    nonisolated static func matchQuery(for query: String) -> String? {
        let terms = query
            .split(
                maxSplits: maximumSearchTerms,
                omittingEmptySubsequences: true,
                whereSeparator: { !$0.isLetter && !$0.isNumber }
            )
            .prefix(maximumSearchTerms)
            .map(boundedSearchTerm)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " AND ")
    }

    private nonisolated static func boundedSearchTerm(_ term: Substring) -> String {
        var scalars = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in term.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            guard byteCount + scalarBytes <= maximumSearchTermBytes else { break }
            scalars.append(scalar)
            byteCount += scalarBytes
        }
        return String(scalars)
    }
}
