import Foundation
import GRDB

enum SyncShardRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case streamScopeMismatch
    case invalidQueryKind
    case invalidInterval
    case invalidCursor
    case invalidCompletionState
    case invalidPersistedData
}

actor SyncShardRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ shard: SyncShard, accountID: AccountID) async throws {
        guard accountID == vault.accountID else {
            throw SyncShardRepositoryError.accountScopeMismatch
        }
        try Self.validate(shard)
        try await vault.write { database in
            try Self.requireStream(
                shard.streamID,
                accountID: accountID,
                database: database
            )
            try database.execute(
                sql: """
                    INSERT INTO sync_shards (
                        id, stream_id, query_kind, interval_start_ms, interval_end_ms,
                        page_cursor, state, completed_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        stream_id = excluded.stream_id,
                        query_kind = excluded.query_kind,
                        interval_start_ms = excluded.interval_start_ms,
                        interval_end_ms = excluded.interval_end_ms,
                        page_cursor = excluded.page_cursor,
                        state = excluded.state,
                        completed_at_ms = excluded.completed_at_ms
                """,
                arguments: [
                    shard.id.rawValue, shard.streamID.rawValue, shard.queryKind,
                    shard.intervalStart.map(Self.milliseconds), shard.intervalEnd.map(Self.milliseconds),
                    shard.pageCursor, shard.state.rawValue, shard.completedAt.map(Self.milliseconds)
                ]
            )
        }
    }

    func shards(
        for streamID: SyncStreamID,
        accountID: AccountID
    ) async throws -> [SyncShard] {
        guard accountID == vault.accountID else {
            throw SyncShardRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Self.requireStream(streamID, accountID: accountID, database: database)
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT id, stream_id, query_kind, interval_start_ms, interval_end_ms,
                           page_cursor, state, completed_at_ms
                    FROM sync_shards
                    WHERE stream_id = ?
                    ORDER BY interval_start_ms, interval_end_ms, id
                """,
                arguments: [streamID.rawValue]
            ).map { try Self.shard(from: $0) }
        }
    }

    private nonisolated static func validate(_ shard: SyncShard) throws {
        guard !shard.queryKind.isEmpty, shard.queryKind.count <= 512 else {
            throw SyncShardRepositoryError.invalidQueryKind
        }
        guard shard.intervalStart == nil || shard.intervalEnd != nil,
              shard.intervalEnd == nil || shard.intervalStart != nil,
              shard.intervalStart.map({ $0 <= shard.intervalEnd! }) ?? true
        else {
            throw SyncShardRepositoryError.invalidInterval
        }
        guard shard.pageCursor?.count ?? 0 <= 4_096 else {
            throw SyncShardRepositoryError.invalidCursor
        }
        guard (shard.state == .completed) == (shard.completedAt != nil) else {
            throw SyncShardRepositoryError.invalidCompletionState
        }
    }

    private nonisolated static func requireStream(
        _ streamID: SyncStreamID,
        accountID: AccountID,
        database: Database
    ) throws {
        let streamCount = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM sync_streams WHERE id = ? AND account_id = ?",
            arguments: [streamID.rawValue, accountID.rawValue]
        ) ?? 0
        guard streamCount == 1 else {
            throw SyncShardRepositoryError.streamScopeMismatch
        }
    }

    private nonisolated static func shard(from row: Row) throws -> SyncShard {
        guard let id = SyncShardID(rawValue: row["id"]),
              let streamID = SyncStreamID(rawValue: row["stream_id"]),
              let queryKind: String = row["query_kind"],
              let stateValue: String = row["state"],
              let state = SyncShardState(rawValue: stateValue)
        else {
            throw SyncShardRepositoryError.invalidPersistedData
        }
        let intervalStart = (row["interval_start_ms"] as Int64?).map(date)
        let intervalEnd = (row["interval_end_ms"] as Int64?).map(date)
        let completedAt = (row["completed_at_ms"] as Int64?).map(date)
        let shard = SyncShard(
            id: id, streamID: streamID, queryKind: queryKind,
            intervalStart: intervalStart, intervalEnd: intervalEnd,
            pageCursor: row["page_cursor"], state: state, completedAt: completedAt
        )
        do {
            try validate(shard)
        } catch {
            throw SyncShardRepositoryError.invalidPersistedData
        }
        return shard
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}
