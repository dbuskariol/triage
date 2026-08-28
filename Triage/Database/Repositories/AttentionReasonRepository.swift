import Foundation
import GRDB

actor AttentionReasonRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func replaceDiscoveryReasons(
        workItemID: WorkItemID,
        reasons: [AttentionReason]
    ) async throws {
        try await vault.write { database in
            try database.execute(
                sql: "DELETE FROM attention_reasons WHERE work_item_id = ? AND rule_id LIKE 'discovery.%'",
                arguments: [workItemID.rawValue]
            )
            for reason in reasons {
                try database.execute(
                    sql: """
                        INSERT INTO attention_reasons (
                            id, work_item_id, rule_id, rule_version, category, strength, title, explanation, evaluated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        reason.id, workItemID.rawValue, reason.ruleID, reason.ruleVersion,
                        reason.category.rawValue, reason.strength, reason.title, reason.explanation,
                        Self.milliseconds(reason.evaluatedAt)
                    ]
                )
                for evidence in reason.evidence {
                    try database.execute(
                        sql: """
                            INSERT INTO attention_reason_evidence (
                                attention_reason_id, evidence_id, source, source_node_id, source_event_id,
                                source_revision, observed_at_ms, excerpt
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            reason.id, evidence.id.rawValue, evidence.source.rawValue,
                            evidence.nodeID?.rawValue, evidence.eventID?.rawValue,
                            evidence.sourceRevision, Self.milliseconds(evidence.observedAt), evidence.excerpt
                        ]
                    )
                }
            }
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
