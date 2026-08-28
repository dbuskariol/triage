import Foundation
import GRDB

actor TimelineRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ event: TimelineEventSummary, sourceRevision: String) async throws {
        let payload = try JSONEncoder().encode(event)
        let occurredAt = Int64((event.occurredAt.timeIntervalSince1970 * 1_000).rounded())
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO timeline_events (
                        github_event_id, subject_node_id, actor_id, kind, occurred_at_ms, payload_json, source_revision
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(github_event_id) DO UPDATE SET
                        actor_id = excluded.actor_id,
                        kind = excluded.kind,
                        occurred_at_ms = excluded.occurred_at_ms,
                        payload_json = excluded.payload_json,
                        source_revision = excluded.source_revision
                    """,
                arguments: [
                    event.id.rawValue,
                    event.subjectNodeID.rawValue,
                    event.actor?.id.rawValue,
                    event.kind.rawValue,
                    occurredAt,
                    payload,
                    sourceRevision
                ]
            )
        }
    }
}
