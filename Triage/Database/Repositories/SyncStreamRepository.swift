import Foundation
import GRDB

enum SyncStreamRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case streamScopeMismatch
    case invalidFailureDetail
    case invalidPersistedData
}

actor SyncStreamRepository {
    private static let maximumFailureDetailLength = 4_096

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func stream(
        withID streamID: SyncStreamID,
        accountID: AccountID
    ) async throws -> SyncStream? {
        guard accountID == vault.accountID else {
            throw SyncStreamRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT id, account_id, organization_id, feature, high_water_ms,
                           last_successful_at_ms, last_attempt_at_ms, state, failure_detail
                    FROM sync_streams
                    WHERE id = ? AND account_id = ?
                    """,
                arguments: [streamID.rawValue, accountID.rawValue]
            ).map(Self.stream(from:))
        }
    }

    func streams(
        for accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> [SyncStream] {
        guard accountID == vault.accountID else {
            throw SyncStreamRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, account_id, organization_id, feature, high_water_ms,
                           last_successful_at_ms, last_attempt_at_ms, state, failure_detail
                    FROM sync_streams
                    WHERE account_id = ? AND organization_id = ?
                    ORDER BY feature, id
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            ).map(Self.stream(from:))
        }
    }

    func save(_ stream: SyncStream) async throws {
        guard stream.accountID == vault.accountID else {
            throw SyncStreamRepositoryError.accountScopeMismatch
        }
        guard stream.failureDetail?.count ?? 0 <= Self.maximumFailureDetailLength else {
            throw SyncStreamRepositoryError.invalidFailureDetail
        }
        try await vault.write { database in
            if let existing = try Row.fetchOne(
                database,
                sql: """
                    SELECT account_id, organization_id, feature
                    FROM sync_streams
                    WHERE id = ?
                    """,
                arguments: [stream.id.rawValue]
            ) {
                guard (existing["account_id"] as String?) == stream.accountID.rawValue,
                      (existing["organization_id"] as String?) == stream.organizationID.rawValue,
                      (existing["feature"] as String?) == stream.feature.rawValue
                else {
                    throw SyncStreamRepositoryError.streamScopeMismatch
                }
            }
            try database.execute(
                sql: """
                    INSERT INTO sync_streams (
                        id, account_id, organization_id, feature, high_water_ms,
                        last_successful_at_ms, last_attempt_at_ms, state, failure_detail
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        high_water_ms = excluded.high_water_ms,
                        last_successful_at_ms = excluded.last_successful_at_ms,
                        last_attempt_at_ms = excluded.last_attempt_at_ms,
                        state = excluded.state,
                        failure_detail = excluded.failure_detail
                    """,
                arguments: [
                    stream.id.rawValue,
                    stream.accountID.rawValue,
                    stream.organizationID.rawValue,
                    stream.feature.rawValue,
                    stream.highWater.map(Self.milliseconds),
                    stream.lastSuccessfulAt.map(Self.milliseconds),
                    stream.lastAttemptAt.map(Self.milliseconds),
                    stream.status.rawValue,
                    stream.failureDetail
                ]
            )
        }
    }

    private nonisolated static func stream(from row: Row) throws -> SyncStream {
        guard let id = SyncStreamID(rawValue: row["id"]),
              let accountID = AccountID(rawValue: row["account_id"]),
              let organizationID = OrganizationID(rawValue: row["organization_id"]),
              let feature = CoverageFeature(rawValue: row["feature"]),
              let status = CoverageStatus(rawValue: row["state"])
        else {
            throw SyncStreamRepositoryError.invalidPersistedData
        }
        let failureDetail: String? = row["failure_detail"]
        guard failureDetail?.count ?? 0 <= Self.maximumFailureDetailLength else {
            throw SyncStreamRepositoryError.invalidPersistedData
        }
        return SyncStream(
            id: id,
            accountID: accountID,
            organizationID: organizationID,
            feature: feature,
            highWater: date(milliseconds: row["high_water_ms"]),
            lastSuccessfulAt: date(milliseconds: row["last_successful_at_ms"]),
            lastAttemptAt: date(milliseconds: row["last_attempt_at_ms"]),
            status: status,
            failureDetail: failureDetail
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func date(milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }
}
