import Foundation
import GRDB

actor WorkflowRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(
        _ state: WorkflowState,
        for workItemID: WorkItemID
    ) async throws {
        let updatedAt = Self.milliseconds(state.updatedAt)
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO workflow_states (
                        work_item_id, status, pinned, priority, snoozed_until_ms, follow_up_at_ms, local_note, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(work_item_id) DO UPDATE SET
                        status = excluded.status,
                        pinned = excluded.pinned,
                        priority = excluded.priority,
                        snoozed_until_ms = excluded.snoozed_until_ms,
                        follow_up_at_ms = excluded.follow_up_at_ms,
                        local_note = excluded.local_note,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    workItemID.rawValue,
                    state.status.rawValue,
                    state.isPinned,
                    state.priority.rawValue,
                    state.snoozedUntil.map(Self.milliseconds),
                    state.followUpAt.map(Self.milliseconds),
                    state.localNote,
                    updatedAt
                ]
            )
        }
    }

    func save(_ actionItem: ActionItem) async throws {
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO action_items (
                        id, work_item_id, title, detail, origin, state, priority, due_at_ms,
                        source_fingerprint, created_at_ms, updated_at_ms, completed_at_ms, dismissed_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        detail = excluded.detail,
                        state = excluded.state,
                        priority = excluded.priority,
                        due_at_ms = excluded.due_at_ms,
                        source_fingerprint = excluded.source_fingerprint,
                        updated_at_ms = excluded.updated_at_ms,
                        completed_at_ms = excluded.completed_at_ms,
                        dismissed_at_ms = excluded.dismissed_at_ms
                    """,
                arguments: [
                    actionItem.id.rawValue, actionItem.workItemID.rawValue, actionItem.title,
                    actionItem.detail, actionItem.origin.rawValue, actionItem.state.rawValue,
                    actionItem.priority.rawValue, actionItem.dueAt.map(Self.milliseconds),
                    actionItem.sourceFingerprint, Self.milliseconds(actionItem.createdAt),
                    Self.milliseconds(actionItem.updatedAt), actionItem.completedAt.map(Self.milliseconds),
                    actionItem.dismissedAt.map(Self.milliseconds)
                ]
            )
            try database.execute(
                sql: "DELETE FROM action_item_evidence WHERE action_item_id = ?",
                arguments: [actionItem.id.rawValue]
            )
            for evidenceID in actionItem.evidenceIDs {
                try database.execute(
                    sql: "INSERT INTO action_item_evidence (action_item_id, evidence_id) VALUES (?, ?)",
                    arguments: [actionItem.id.rawValue, evidenceID.rawValue]
                )
            }
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
