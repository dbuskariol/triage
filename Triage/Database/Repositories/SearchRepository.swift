import Foundation
import GRDB

struct SearchDocument: Sendable {
    let id: Int64
    let accountID: AccountID
    let organizationID: OrganizationID
    let workItemID: WorkItemID?
    let nodeID: GitHubNodeID?
    let updatedAt: Date
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

    func replace(_ document: SearchDocument) async throws {
        let updatedAt = Int64((document.updatedAt.timeIntervalSince1970 * 1_000).rounded())
        try await vault.write { database in
            try database.execute(
                sql: "DELETE FROM search_documents WHERE rowid = ?",
                arguments: [document.id]
            )
            try database.execute(
                sql: """
                    INSERT INTO search_documents (
                        rowid, title, body, repository, labels, people, project_values, action_text, local_note
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    document.id, document.title, document.body, document.repository,
                    document.labels, document.people, document.projectValues,
                    document.actionText, document.localNote
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO search_document_metadata (
                        id, account_id, organization_id, work_item_id, github_node_id, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        account_id = excluded.account_id,
                        organization_id = excluded.organization_id,
                        work_item_id = excluded.work_item_id,
                        github_node_id = excluded.github_node_id,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    document.id, document.accountID.rawValue, document.organizationID.rawValue,
                    document.workItemID?.rawValue, document.nodeID?.rawValue, updatedAt
                ]
            )
        }
    }

    func search(
        _ query: String,
        accountID: AccountID,
        organizationID: OrganizationID,
        limit: Int = 100
    ) async throws -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
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
                arguments: [query, accountID.rawValue, organizationID.rawValue, min(max(limit, 1), 100)]
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
}
