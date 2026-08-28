import Foundation
import GRDB

enum ConditionalRequestCacheRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case invalidRequestKey
    case missingValidator
    case invalidPersistedData
}

actor ConditionalRequestCacheRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ validator: ConditionalRequestValidator) async throws {
        guard validator.accountID == vault.accountID else {
            throw ConditionalRequestCacheRepositoryError.accountScopeMismatch
        }
        guard !validator.requestKey.isEmpty, validator.requestKey.count <= 2_048 else {
            throw ConditionalRequestCacheRepositoryError.invalidRequestKey
        }
        guard validator.eTag != nil || validator.lastModified != nil else {
            throw ConditionalRequestCacheRepositoryError.missingValidator
        }
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO conditional_request_cache (
                        request_key, account_id, etag, last_modified, observed_at_ms
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(request_key) DO UPDATE SET
                        account_id = excluded.account_id,
                        etag = excluded.etag,
                        last_modified = excluded.last_modified,
                        observed_at_ms = excluded.observed_at_ms
                """,
                arguments: [
                    validator.requestKey, validator.accountID.rawValue, validator.eTag,
                    validator.lastModified, Self.milliseconds(validator.observedAt)
                ]
            )
        }
    }

    func validator(
        for requestKey: String,
        accountID: AccountID
    ) async throws -> ConditionalRequestValidator? {
        guard accountID == vault.accountID else {
            throw ConditionalRequestCacheRepositoryError.accountScopeMismatch
        }
        guard !requestKey.isEmpty, requestKey.count <= 2_048 else {
            throw ConditionalRequestCacheRepositoryError.invalidRequestKey
        }
        return try await vault.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT request_key, account_id, etag, last_modified, observed_at_ms
                    FROM conditional_request_cache
                    WHERE request_key = ? AND account_id = ?
                """,
                arguments: [requestKey, accountID.rawValue]
            ) else {
                return nil
            }
            return try Self.validator(from: row)
        }
    }

    func remove(requestKey: String, accountID: AccountID) async throws {
        guard accountID == vault.accountID else {
            throw ConditionalRequestCacheRepositoryError.accountScopeMismatch
        }
        guard !requestKey.isEmpty, requestKey.count <= 2_048 else {
            throw ConditionalRequestCacheRepositoryError.invalidRequestKey
        }
        try await vault.write { database in
            try database.execute(
                sql: "DELETE FROM conditional_request_cache WHERE request_key = ? AND account_id = ?",
                arguments: [requestKey, accountID.rawValue]
            )
        }
    }

    private nonisolated static func validator(from row: Row) throws -> ConditionalRequestValidator {
        guard let requestKey: String = row["request_key"],
              let accountID = AccountID(rawValue: row["account_id"]),
              let observedAtMilliseconds: Int64 = row["observed_at_ms"]
        else {
            throw ConditionalRequestCacheRepositoryError.invalidPersistedData
        }
        let eTag: String? = row["etag"]
        let lastModified: String? = row["last_modified"]
        guard !requestKey.isEmpty, eTag != nil || lastModified != nil else {
            throw ConditionalRequestCacheRepositoryError.invalidPersistedData
        }
        return ConditionalRequestValidator(
            requestKey: requestKey,
            accountID: accountID,
            eTag: eTag,
            lastModified: lastModified,
            observedAt: Date(timeIntervalSince1970: TimeInterval(observedAtMilliseconds) / 1_000)
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
