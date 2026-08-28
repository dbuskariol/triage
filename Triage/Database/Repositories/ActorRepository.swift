import Foundation
import GRDB

actor ActorRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ actor: ActorSummary, observedAt: Date = .now) async throws {
        try await vault.write { database in
            try Self.save(
                actor,
                observedAtMilliseconds: Self.milliseconds(observedAt),
                in: database
            )
        }
    }

    nonisolated static func save(
        _ actor: ActorSummary,
        observedAtMilliseconds: Int64,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO actors (
                    id, github_node_id, github_actor_id, login, display_name, avatar_url, kind, updated_at_ms
                ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    login = excluded.login,
                    display_name = excluded.display_name,
                    avatar_url = excluded.avatar_url,
                    updated_at_ms = excluded.updated_at_ms
                """,
            arguments: [
                actor.id.rawValue,
                actor.nodeID.rawValue,
                actor.login,
                actor.displayName,
                actor.avatarURL?.absoluteString,
                "user",
                observedAtMilliseconds
            ]
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
