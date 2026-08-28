import Foundation
import GRDB

enum AttentionScoreRepositoryError: Error, Equatable, Sendable {
    case workItemScopeMismatch
    case invalidPersistedData
}

actor AttentionScoreRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(
        _ score: AttentionScore,
        for workItemID: WorkItemID,
        evaluatedAt: Date = .now
    ) async throws {
        let breakdown = try JSONEncoder().encode(score.breakdown)
        try await vault.write { database in
            try Self.validateWorkItemScope(workItemID, vault: vault, in: database)
            try database.execute(
                sql: """
                    INSERT INTO attention_scores (work_item_id, score, breakdown_json, evaluated_at_ms)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(work_item_id) DO UPDATE SET
                        score = excluded.score,
                        breakdown_json = excluded.breakdown_json,
                        evaluated_at_ms = excluded.evaluated_at_ms
                """,
                arguments: [
                    workItemID.rawValue,
                    score.value,
                    breakdown,
                    Self.milliseconds(evaluatedAt)
                ]
            )
        }
    }

    func score(for workItemID: WorkItemID) async throws -> AttentionScore? {
        try await vault.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT attention_scores.score, attention_scores.breakdown_json
                    FROM attention_scores
                    JOIN work_items ON work_items.id = attention_scores.work_item_id
                    WHERE attention_scores.work_item_id = ? AND work_items.account_id = ?
                """,
                arguments: [workItemID.rawValue, vault.accountID.rawValue]
            ) else {
                return nil
            }
            guard let breakdown: Data = row["breakdown_json"] else {
                throw AttentionScoreRepositoryError.invalidPersistedData
            }
            return AttentionScore(
                value: row["score"],
                breakdown: try JSONDecoder().decode([String: Int].self, from: breakdown)
            )
        }
    }

    private nonisolated static func validateWorkItemScope(
        _ workItemID: WorkItemID,
        vault: AccountVault,
        in database: Database
    ) throws {
        let matchingCount = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM work_items WHERE id = ? AND account_id = ?",
            arguments: [workItemID.rawValue, vault.accountID.rawValue]
        ) ?? 0
        guard matchingCount == 1 else {
            throw AttentionScoreRepositoryError.workItemScopeMismatch
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
