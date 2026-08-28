import Foundation
import GRDB

enum RawAPISnapshotRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case nodeScopeMismatch
    case invalidEndpoint
    case invalidParserVersion
    case invalidLimit
    case invalidPersistedData
    case payloadTooLarge
}

actor RawAPISnapshotRepository {
    static let maximumPayloadBytes = 4 * 1_024 * 1_024

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ snapshot: RawAPISnapshot) async throws {
        guard snapshot.accountID == vault.accountID else {
            throw RawAPISnapshotRepositoryError.accountScopeMismatch
        }
        guard !snapshot.endpoint.isEmpty, snapshot.endpoint.count <= 2_048 else {
            throw RawAPISnapshotRepositoryError.invalidEndpoint
        }
        guard snapshot.parserVersion > 0 else {
            throw RawAPISnapshotRepositoryError.invalidParserVersion
        }
        guard snapshot.payload.count <= Self.maximumPayloadBytes else {
            throw RawAPISnapshotRepositoryError.payloadTooLarge
        }
        try await vault.write { database in
            if let nodeID = snapshot.githubNodeID {
                let matchingCount = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM github_nodes WHERE github_node_id = ? AND account_id = ?",
                    arguments: [nodeID.rawValue, snapshot.accountID.rawValue]
                ) ?? 0
                guard matchingCount == 1 else {
                    throw RawAPISnapshotRepositoryError.nodeScopeMismatch
                }
            }
            try database.execute(
                sql: """
                    INSERT INTO raw_api_snapshots (
                        id, account_id, github_node_id, endpoint, etag, parser_version, observed_at_ms, payload
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        account_id = excluded.account_id,
                        github_node_id = excluded.github_node_id,
                        endpoint = excluded.endpoint,
                        etag = excluded.etag,
                        parser_version = excluded.parser_version,
                        observed_at_ms = excluded.observed_at_ms,
                        payload = excluded.payload
                """,
                arguments: [
                    snapshot.id.rawValue, snapshot.accountID.rawValue, snapshot.githubNodeID?.rawValue,
                    snapshot.endpoint, snapshot.eTag, snapshot.parserVersion,
                    Self.milliseconds(snapshot.observedAt), snapshot.payload
                ]
            )
        }
    }

    func snapshots(for accountID: AccountID, limit: Int = 100) async throws -> [RawAPISnapshot] {
        guard accountID == vault.accountID else {
            throw RawAPISnapshotRepositoryError.accountScopeMismatch
        }
        guard limit >= 0 else {
            throw RawAPISnapshotRepositoryError.invalidLimit
        }
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, account_id, github_node_id, endpoint, etag, parser_version, observed_at_ms, payload
                    FROM raw_api_snapshots
                    WHERE account_id = ?
                    ORDER BY observed_at_ms DESC, id
                    LIMIT ?
                """,
                arguments: [accountID.rawValue, limit]
            ).map { try Self.snapshot(from: $0) }
        }
    }

    private nonisolated static func snapshot(from row: Row) throws -> RawAPISnapshot {
        guard let id = RawAPISnapshotID(rawValue: row["id"]),
              let accountID = AccountID(rawValue: row["account_id"]),
              let endpoint: String = row["endpoint"],
              let parserVersion: Int = row["parser_version"],
              let observedAtMilliseconds: Int64 = row["observed_at_ms"],
              let payload: Data = row["payload"]
        else {
            throw RawAPISnapshotRepositoryError.invalidPersistedData
        }
        let rawNodeID: String? = row["github_node_id"]
        let nodeID = rawNodeID.flatMap(GitHubNodeID.init(rawValue:))
        guard rawNodeID == nil || nodeID != nil else {
            throw RawAPISnapshotRepositoryError.invalidPersistedData
        }
        return RawAPISnapshot(
            id: id, accountID: accountID, githubNodeID: nodeID, endpoint: endpoint,
            eTag: row["etag"], parserVersion: parserVersion,
            observedAt: Date(timeIntervalSince1970: TimeInterval(observedAtMilliseconds) / 1_000),
            payload: payload
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
