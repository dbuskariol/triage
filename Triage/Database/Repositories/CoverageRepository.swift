import CryptoKit
import Foundation
import GRDB

enum CoverageRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case invalidInterval
    case invalidPersistedData
    case streamScopeMismatch
}

actor CoverageRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ record: CoverageRecord, attemptedAt: Date = .now) async throws {
        try validate(record)
        let coverageID = Self.coverageID(for: record)
        let attemptedAtMilliseconds = Self.milliseconds(attemptedAt)

        try await vault.write { database in
            try Self.saveStream(
                for: record,
                attemptedAtMilliseconds: attemptedAtMilliseconds,
                in: database
            )
            try database.execute(
                sql: """
                    INSERT INTO coverage_records (
                        id, account_id, organization_id, repository_id, feature, stream_id,
                        interval_start_ms, interval_end_ms, credential_revision, capability_revision,
                        status, last_successful_at_ms, failure_detail
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        account_id = excluded.account_id,
                        organization_id = excluded.organization_id,
                        repository_id = excluded.repository_id,
                        feature = excluded.feature,
                        stream_id = excluded.stream_id,
                        interval_start_ms = excluded.interval_start_ms,
                        interval_end_ms = excluded.interval_end_ms,
                        credential_revision = excluded.credential_revision,
                        capability_revision = excluded.capability_revision,
                        status = excluded.status,
                        last_successful_at_ms = COALESCE(
                            excluded.last_successful_at_ms,
                            coverage_records.last_successful_at_ms
                        ),
                        failure_detail = excluded.failure_detail
                    """,
                arguments: [
                    coverageID,
                    record.accountID.rawValue,
                    record.organizationID.rawValue,
                    record.repositoryID?.rawValue,
                    record.feature.rawValue,
                    record.streamID.rawValue,
                    record.intervalStart.map(Self.milliseconds),
                    record.intervalEnd.map(Self.milliseconds),
                    record.credentialRevision.rawValue,
                    record.capabilityRevision.rawValue,
                    record.status.rawValue,
                    record.lastSuccessfulAt.map(Self.milliseconds),
                    record.failureDetail
                ]
            )
        }
    }

    func records(
        for accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> [CoverageRecord] {
        guard accountID == vault.accountID else {
            throw CoverageRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT account_id, organization_id, repository_id, feature, stream_id,
                           interval_start_ms, interval_end_ms, credential_revision, capability_revision,
                           status, last_successful_at_ms, failure_detail
                    FROM coverage_records
                    WHERE account_id = ? AND organization_id = ?
                    ORDER BY feature, stream_id, repository_id, interval_start_ms, interval_end_ms
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            ).map(Self.record(from:))
        }
    }

    private func validate(_ record: CoverageRecord) throws {
        guard record.accountID == vault.accountID else {
            throw CoverageRepositoryError.accountScopeMismatch
        }
        if let intervalStart = record.intervalStart,
           let intervalEnd = record.intervalEnd,
           intervalStart > intervalEnd {
            throw CoverageRepositoryError.invalidInterval
        }
        guard record.intervalStart == nil || record.intervalEnd != nil else {
            throw CoverageRepositoryError.invalidInterval
        }
        guard record.intervalEnd == nil || record.intervalStart != nil else {
            throw CoverageRepositoryError.invalidInterval
        }
    }

    private nonisolated static func saveStream(
        for record: CoverageRecord,
        attemptedAtMilliseconds: Int64,
        in database: Database
    ) throws {
        let existingScope = try Row.fetchOne(
            database,
            sql: """
                SELECT account_id, organization_id, feature
                FROM sync_streams
                WHERE id = ?
                """,
            arguments: [record.streamID.rawValue]
        )
        if let existingScope {
            guard (existingScope["account_id"] as String?) == record.accountID.rawValue,
                  (existingScope["organization_id"] as String?) == record.organizationID.rawValue,
                  (existingScope["feature"] as String?) == record.feature.rawValue
            else {
                throw CoverageRepositoryError.streamScopeMismatch
            }
            try database.execute(
                sql: """
                    UPDATE sync_streams
                    SET high_water_ms = CASE
                            WHEN ? = ? AND ? IS NOT NULL THEN ?
                            ELSE high_water_ms
                        END,
                        last_successful_at_ms = COALESCE(?, last_successful_at_ms),
                        last_attempt_at_ms = ?,
                        state = ?, failure_detail = ?
                    WHERE id = ?
                    """,
                arguments: [
                    record.status.rawValue,
                    CoverageStatus.complete.rawValue,
                    record.intervalEnd.map(milliseconds),
                    record.intervalEnd.map(milliseconds),
                    record.lastSuccessfulAt.map(milliseconds),
                    attemptedAtMilliseconds,
                    record.status.rawValue,
                    record.failureDetail,
                    record.streamID.rawValue
                ]
            )
            return
        }

        try database.execute(
            sql: """
                INSERT INTO sync_streams (
                    id, account_id, organization_id, feature, high_water_ms,
                    last_successful_at_ms, last_attempt_at_ms, state, failure_detail
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                record.streamID.rawValue,
                record.accountID.rawValue,
                record.organizationID.rawValue,
                record.feature.rawValue,
                record.intervalEnd.map(milliseconds),
                record.lastSuccessfulAt.map(milliseconds),
                attemptedAtMilliseconds,
                record.status.rawValue,
                record.failureDetail
            ]
        )
    }

    private nonisolated static func record(from row: Row) throws -> CoverageRecord {
        guard let accountID = AccountID(rawValue: row["account_id"]),
              let organizationID = OrganizationID(rawValue: row["organization_id"]),
              let feature = CoverageFeature(rawValue: row["feature"]),
              let streamID = SyncStreamID(rawValue: row["stream_id"]),
              let credentialRevision = CredentialRevision(rawValue: row["credential_revision"]),
              let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"]),
              let status = CoverageStatus(rawValue: row["status"])
        else {
            throw CoverageRepositoryError.invalidPersistedData
        }
        let repositoryID = (row["repository_id"] as String?).flatMap(RepositoryID.init(rawValue:))
        if row["repository_id"] != nil && repositoryID == nil {
            throw CoverageRepositoryError.invalidPersistedData
        }
        let intervalStart = date(milliseconds: row["interval_start_ms"])
        let intervalEnd = date(milliseconds: row["interval_end_ms"])
        guard (intervalStart == nil) == (intervalEnd == nil),
              intervalStart.map({ $0 <= intervalEnd! }) ?? true
        else {
            throw CoverageRepositoryError.invalidPersistedData
        }
        return CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            feature: feature,
            streamID: streamID,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            status: status,
            lastSuccessfulAt: date(milliseconds: row["last_successful_at_ms"]),
            failureDetail: row["failure_detail"]
        )
    }

    private nonisolated static func coverageID(for record: CoverageRecord) -> String {
        let fields = [
            record.accountID.rawValue,
            record.organizationID.rawValue,
            record.repositoryID?.rawValue ?? "",
            record.feature.rawValue,
            record.streamID.rawValue,
            record.intervalStart.map(milliseconds).map(String.init) ?? "",
            record.intervalEnd.map(milliseconds).map(String.init) ?? "",
            record.credentialRevision.rawValue,
            record.capabilityRevision.rawValue
        ]
        let canonicalScope = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(canonicalScope.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func date(milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }
}
