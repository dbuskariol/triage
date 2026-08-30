import Foundation
import GRDB

enum DerivedIntelligenceRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case invalidEvaluationDate
    case duplicateWorkItem
    case duplicateReason
    case invalidSearchDocument
    case incompleteWorkItemSnapshot
    case workItemScopeMismatch
}

struct DerivedIntelligencePersistenceItem: Sendable {
    let workItemID: WorkItemID
    let attentionReasons: [AttentionReason]
    let score: AttentionScore
    let searchDocument: SearchDocument
}

struct DerivedIntelligencePersistenceSnapshot: Sendable {
    let scope: SynchronizationScope
    let evaluatedAt: Date
    let items: [DerivedIntelligencePersistenceItem]
}

actor DerivedIntelligenceRepository {
    static let maximumSearchDocumentBytes = 128 * 1_024

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    /// Replaces the complete derived projection for an organization in one
    /// transaction. The snapshot must enumerate every persisted work item in
    /// the organization so stale rule, score, and FTS rows cannot survive.
    func replace(_ snapshot: DerivedIntelligencePersistenceSnapshot) async throws {
        guard snapshot.scope.accountID == vault.accountID else {
            throw DerivedIntelligenceRepositoryError.accountScopeMismatch
        }
        try Self.validate(snapshot)
        try await vault.writeTransaction { database in
            try Self.validateCompleteWorkItemSnapshot(snapshot, in: database)
            try Self.deleteDerivedRows(for: snapshot.scope, in: database)
            for item in snapshot.items.sorted(by: { $0.workItemID.rawValue < $1.workItemID.rawValue }) {
                try Self.insert(item, evaluatedAt: snapshot.evaluatedAt, in: database)
            }
        }
    }

    private nonisolated static func validate(_ snapshot: DerivedIntelligencePersistenceSnapshot) throws {
        guard snapshot.evaluatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DerivedIntelligenceRepositoryError.invalidEvaluationDate
        }
        guard Set(snapshot.items.map(\.workItemID)).count == snapshot.items.count else {
            throw DerivedIntelligenceRepositoryError.duplicateWorkItem
        }
        var reasonIDs = Set<String>()
        for item in snapshot.items {
            let document = item.searchDocument
            guard document.accountID == snapshot.scope.accountID,
                  document.organizationID == snapshot.scope.organizationID,
                  document.workItemID == item.workItemID,
                  documentBytes(document) <= maximumSearchDocumentBytes
            else {
                throw DerivedIntelligenceRepositoryError.invalidSearchDocument
            }
            for reason in item.attentionReasons {
                guard reasonIDs.insert(reason.id).inserted,
                      Set(reason.evidence.map(\.id)).count == reason.evidence.count
                else {
                    throw DerivedIntelligenceRepositoryError.duplicateReason
                }
            }
        }
    }

    private nonisolated static func validateCompleteWorkItemSnapshot(
        _ snapshot: DerivedIntelligencePersistenceSnapshot,
        in database: Database
    ) throws {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, primary_node_id
                FROM work_items
                WHERE account_id = ? AND organization_id = ?
                ORDER BY id
                """,
            arguments: [snapshot.scope.accountID.rawValue, snapshot.scope.organizationID.rawValue]
        )
        guard rows.count == snapshot.items.count else {
            throw DerivedIntelligenceRepositoryError.incompleteWorkItemSnapshot
        }
        let nodesByWorkItem = Dictionary(uniqueKeysWithValues: rows.map {
            (($0["id"] as String), ($0["primary_node_id"] as String))
        })
        for item in snapshot.items {
            guard nodesByWorkItem[item.workItemID.rawValue] == item.searchDocument.nodeID.rawValue else {
                throw DerivedIntelligenceRepositoryError.workItemScopeMismatch
            }
        }
    }

    private nonisolated static func deleteDerivedRows(
        for scope: SynchronizationScope,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                DELETE FROM attention_reasons
                WHERE rule_id NOT LIKE 'discovery.%'
                  AND work_item_id IN (
                      SELECT id FROM work_items
                      WHERE account_id = ? AND organization_id = ?
                  )
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        try database.execute(
            sql: """
                DELETE FROM attention_scores
                WHERE work_item_id IN (
                    SELECT id FROM work_items
                    WHERE account_id = ? AND organization_id = ?
                )
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        try database.execute(
            sql: """
                DELETE FROM search_documents
                WHERE rowid IN (
                    SELECT id FROM search_document_metadata
                    WHERE account_id = ? AND organization_id = ?
                )
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        try database.execute(
            sql: """
                DELETE FROM search_document_metadata
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
    }

    private nonisolated static func insert(
        _ item: DerivedIntelligencePersistenceItem,
        evaluatedAt: Date,
        in database: Database
    ) throws {
        for reason in item.attentionReasons.sorted(by: reasonOrder) {
            try database.execute(
                sql: """
                    INSERT INTO attention_reasons (
                        id, work_item_id, rule_id, rule_version, category, strength,
                        title, explanation, evaluated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    reason.id,
                    item.workItemID.rawValue,
                    reason.ruleID,
                    reason.ruleVersion,
                    reason.category.rawValue,
                    reason.strength,
                    reason.title,
                    reason.explanation,
                    milliseconds(reason.evaluatedAt)
                ]
            )
            for evidence in reason.evidence.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
                try database.execute(
                    sql: """
                        INSERT INTO attention_reason_evidence (
                            attention_reason_id, evidence_id, source, source_node_id,
                            source_event_id, source_revision, observed_at_ms, excerpt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        reason.id,
                        evidence.id.rawValue,
                        evidence.source.rawValue,
                        evidence.nodeID?.rawValue,
                        evidence.eventID?.rawValue,
                        evidence.sourceRevision,
                        milliseconds(evidence.observedAt),
                        evidence.excerpt
                    ]
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try database.execute(
            sql: """
                INSERT INTO attention_scores (work_item_id, score, breakdown_json, evaluated_at_ms)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                item.workItemID.rawValue,
                item.score.value,
                try encoder.encode(item.score.breakdown),
                milliseconds(evaluatedAt)
            ]
        )
        let document = item.searchDocument
        try database.execute(
            sql: """
                INSERT INTO search_documents (
                    title, body, repository, labels, people, project_values, action_text, local_note
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                document.title,
                document.body,
                document.repository,
                document.labels,
                document.people,
                document.projectValues,
                document.actionText,
                document.localNote
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO search_document_metadata (
                    id, account_id, organization_id, work_item_id, github_node_id, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                database.lastInsertedRowID,
                document.accountID.rawValue,
                document.organizationID.rawValue,
                document.workItemID.rawValue,
                document.nodeID.rawValue,
                milliseconds(evaluatedAt)
            ]
        )
    }

    private nonisolated static func reasonOrder(_ left: AttentionReason, _ right: AttentionReason) -> Bool {
        left.strength == right.strength ? left.id < right.id : left.strength > right.strength
    }

    private nonisolated static func documentBytes(_ document: SearchDocument) -> Int {
        [
            document.title,
            document.body,
            document.repository,
            document.labels,
            document.people,
            document.projectValues,
            document.actionText,
            document.localNote
        ].reduce(0) { $0 + $1.utf8.count }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
