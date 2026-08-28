import Foundation
import GRDB

enum NormalizationFailureRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case snapshotScopeMismatch
    case nodeScopeMismatch
    case invalidEndpoint
    case invalidParserVersion
    case invalidDiagnostic
    case invalidLimit
    case invalidPersistedData
}

actor NormalizationFailureRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func record(_ failure: NormalizationFailure) async throws {
        guard failure.accountID == vault.accountID else {
            throw NormalizationFailureRepositoryError.accountScopeMismatch
        }
        guard !failure.endpoint.isEmpty, failure.endpoint.count <= 2_048 else {
            throw NormalizationFailureRepositoryError.invalidEndpoint
        }
        guard failure.parserVersion > 0 else {
            throw NormalizationFailureRepositoryError.invalidParserVersion
        }
        guard !failure.redactedDiagnostic.isEmpty, failure.redactedDiagnostic.count <= 4_096 else {
            throw NormalizationFailureRepositoryError.invalidDiagnostic
        }
        try await vault.write { database in
            let snapshotCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM raw_api_snapshots WHERE id = ? AND account_id = ?",
                arguments: [failure.rawSnapshotID.rawValue, failure.accountID.rawValue]
            ) ?? 0
            guard snapshotCount == 1 else {
                throw NormalizationFailureRepositoryError.snapshotScopeMismatch
            }
            if let nodeID = failure.githubNodeID {
                let nodeCount = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM github_nodes WHERE github_node_id = ? AND account_id = ?",
                    arguments: [nodeID.rawValue, failure.accountID.rawValue]
                ) ?? 0
                guard nodeCount == 1 else {
                    throw NormalizationFailureRepositoryError.nodeScopeMismatch
                }
            }
            try database.execute(
                sql: """
                    INSERT INTO normalization_failures (
                        id, account_id, raw_snapshot_id, github_node_id, endpoint,
                        parser_version, occurred_at_ms, redacted_diagnostic
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    failure.id.uuidString.lowercased(), failure.accountID.rawValue,
                    failure.rawSnapshotID.rawValue, failure.githubNodeID?.rawValue,
                    failure.endpoint, failure.parserVersion, Self.milliseconds(failure.occurredAt),
                    failure.redactedDiagnostic
                ]
            )
        }
    }

    func failures(for accountID: AccountID, limit: Int = 100) async throws -> [NormalizationFailure] {
        guard accountID == vault.accountID else {
            throw NormalizationFailureRepositoryError.accountScopeMismatch
        }
        guard limit >= 0 else {
            throw NormalizationFailureRepositoryError.invalidLimit
        }
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, account_id, raw_snapshot_id, github_node_id, endpoint,
                           parser_version, occurred_at_ms, redacted_diagnostic
                    FROM normalization_failures
                    WHERE account_id = ?
                    ORDER BY occurred_at_ms DESC, id
                    LIMIT ?
                """,
                arguments: [accountID.rawValue, limit]
            ).map { try Self.failure(from: $0) }
        }
    }

    private nonisolated static func failure(from row: Row) throws -> NormalizationFailure {
        guard let rawID: String = row["id"],
              let id = UUID(uuidString: rawID),
              let accountID = AccountID(rawValue: row["account_id"]),
              let snapshotID = RawAPISnapshotID(rawValue: row["raw_snapshot_id"]),
              let endpoint: String = row["endpoint"],
              let parserVersion: Int = row["parser_version"],
              let milliseconds: Int64 = row["occurred_at_ms"],
              let diagnostic: String = row["redacted_diagnostic"]
        else {
            throw NormalizationFailureRepositoryError.invalidPersistedData
        }
        let rawNodeID: String? = row["github_node_id"]
        let nodeID = rawNodeID.flatMap(GitHubNodeID.init(rawValue:))
        guard rawNodeID == nil || nodeID != nil else {
            throw NormalizationFailureRepositoryError.invalidPersistedData
        }
        return NormalizationFailure(
            id: id, accountID: accountID, rawSnapshotID: snapshotID, githubNodeID: nodeID,
            endpoint: endpoint, parserVersion: parserVersion,
            occurredAt: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000),
            redactedDiagnostic: diagnostic
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
