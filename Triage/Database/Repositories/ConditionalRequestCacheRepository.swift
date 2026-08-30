import Foundation
import GRDB

enum ConditionalRequestCacheRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case authorityScopeMismatch
    case streamScopeMismatch
    case invalidRequestKey
    case invalidValidator
    case missingValidator
    case invalidPersistedData
}

actor ConditionalRequestCacheRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ validator: ConditionalRequestValidator) async throws {
        try await vault.write { database in
            try Self.save(
                validator,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    func validator(for identity: ConditionalRequestIdentity) async throws -> ConditionalRequestValidator? {
        return try await vault.read { database in
            try Self.validator(
                for: identity,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    func remove(for identity: ConditionalRequestIdentity) async throws {
        try await vault.write { database in
            try Self.remove(
                for: identity,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    nonisolated static func save(
        _ validator: ConditionalRequestValidator,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        try validate(validator.identity, expectedAccountID: expectedAccountID)
        try validateAuthorityScope(validator.identity, in: database)
        try validateStreamScope(validator.identity, in: database)
        guard validator.eTag != nil || validator.lastModified != nil else {
            throw ConditionalRequestCacheRepositoryError.missingValidator
        }
        guard validHeaderValidator(validator.eTag), validHeaderValidator(validator.lastModified) else {
            throw ConditionalRequestCacheRepositoryError.invalidValidator
        }
        try database.execute(
            sql: """
                DELETE FROM conditional_request_cache
                WHERE account_id = ? AND organization_id = ? AND feature = ?
                  AND stream_id = ? AND request_key = ?
                  AND (credential_revision <> ? OR capability_revision <> ?)
            """,
            arguments: [
                validator.identity.scope.accountID.rawValue,
                validator.identity.scope.organizationID.rawValue,
                validator.identity.feature.rawValue,
                validator.identity.streamID.rawValue,
                validator.identity.requestKey,
                validator.identity.scope.credentialRevision.rawValue,
                validator.identity.scope.capabilityRevision.rawValue
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO conditional_request_cache (
                    account_id, organization_id, feature, stream_id, request_key,
                    credential_revision, capability_revision, etag, last_modified,
                    observed_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(
                    account_id, organization_id, feature, stream_id, request_key,
                    credential_revision, capability_revision
                )
                DO UPDATE SET
                    credential_revision = excluded.credential_revision,
                    capability_revision = excluded.capability_revision,
                    etag = excluded.etag,
                    last_modified = excluded.last_modified,
                    observed_at_ms = excluded.observed_at_ms
            """,
            arguments: [
                validator.identity.scope.accountID.rawValue,
                validator.identity.scope.organizationID.rawValue,
                validator.identity.feature.rawValue,
                validator.identity.streamID.rawValue,
                validator.identity.requestKey,
                validator.identity.scope.credentialRevision.rawValue,
                validator.identity.scope.capabilityRevision.rawValue,
                validator.eTag,
                validator.lastModified,
                milliseconds(validator.observedAt)
            ]
        )
    }

    nonisolated static func validator(
        for identity: ConditionalRequestIdentity,
        expectedAccountID: AccountID,
        in database: Database
    ) throws -> ConditionalRequestValidator? {
        try validate(identity, expectedAccountID: expectedAccountID)
        try validateAuthorityScope(identity, in: database)
        try validateStreamScopeIfPresent(identity, in: database)
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT account_id, organization_id, feature, stream_id, request_key,
                       credential_revision, capability_revision, etag, last_modified,
                       observed_at_ms
                FROM conditional_request_cache
                WHERE account_id = ? AND organization_id = ? AND feature = ?
                  AND stream_id = ? AND request_key = ?
                  AND credential_revision = ? AND capability_revision = ?
            """,
            arguments: [
                identity.scope.accountID.rawValue,
                identity.scope.organizationID.rawValue,
                identity.feature.rawValue,
                identity.streamID.rawValue,
                identity.requestKey,
                identity.scope.credentialRevision.rawValue,
                identity.scope.capabilityRevision.rawValue
            ]
        ) else {
            return nil
        }
        let validator = try validator(from: row)
        guard validator.identity == identity else {
            throw ConditionalRequestCacheRepositoryError.invalidPersistedData
        }
        return validator
    }

    nonisolated static func remove(
        for identity: ConditionalRequestIdentity,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        try validate(identity, expectedAccountID: expectedAccountID)
        try validateAuthorityScope(identity, in: database)
        try validateStreamScope(identity, in: database)
        try database.execute(
            sql: """
                DELETE FROM conditional_request_cache
                WHERE account_id = ? AND organization_id = ? AND feature = ?
                  AND stream_id = ? AND request_key = ?
                  AND credential_revision = ? AND capability_revision = ?
            """,
            arguments: [
                identity.scope.accountID.rawValue,
                identity.scope.organizationID.rawValue,
                identity.feature.rawValue,
                identity.streamID.rawValue,
                identity.requestKey,
                identity.scope.credentialRevision.rawValue,
                identity.scope.capabilityRevision.rawValue
            ]
        )
    }

    private nonisolated static func validator(from row: Row) throws -> ConditionalRequestValidator {
        guard let accountID = AccountID(rawValue: row["account_id"]),
              let organizationID = OrganizationID(rawValue: row["organization_id"]),
              let feature = CoverageFeature(rawValue: row["feature"]),
              let streamID = SyncStreamID(rawValue: row["stream_id"]),
              let requestKey: String = row["request_key"],
              let credentialRevision = CredentialRevision(rawValue: row["credential_revision"]),
              let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"]),
              let observedAtMilliseconds: Int64 = row["observed_at_ms"]
        else {
            throw ConditionalRequestCacheRepositoryError.invalidPersistedData
        }
        let eTag: String? = row["etag"]
        let lastModified: String? = row["last_modified"]
        let identity = ConditionalRequestIdentity(
            scope: SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision
            ),
            feature: feature,
            streamID: streamID,
            requestKey: requestKey
        )
        guard validRequestKey(requestKey),
              eTag != nil || lastModified != nil,
              validHeaderValidator(eTag),
              validHeaderValidator(lastModified)
        else {
            throw ConditionalRequestCacheRepositoryError.invalidPersistedData
        }
        return ConditionalRequestValidator(
            identity: identity,
            eTag: eTag,
            lastModified: lastModified,
            observedAt: Date(timeIntervalSince1970: TimeInterval(observedAtMilliseconds) / 1_000)
        )
    }

    private nonisolated static func validate(
        _ identity: ConditionalRequestIdentity,
        expectedAccountID: AccountID
    ) throws {
        guard identity.scope.accountID == expectedAccountID else {
            throw ConditionalRequestCacheRepositoryError.accountScopeMismatch
        }
        guard validRequestKey(identity.requestKey) else {
            throw ConditionalRequestCacheRepositoryError.invalidRequestKey
        }
    }

    private nonisolated static func validateStreamScope(
        _ identity: ConditionalRequestIdentity,
        in database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM sync_streams
                WHERE id = ? AND account_id = ? AND organization_id = ? AND feature = ?
            """,
            arguments: [
                identity.streamID.rawValue,
                identity.scope.accountID.rawValue,
                identity.scope.organizationID.rawValue,
                identity.feature.rawValue
            ]
        ) ?? 0
        guard count == 1 else {
            throw ConditionalRequestCacheRepositoryError.streamScopeMismatch
        }
    }

    private nonisolated static func validateStreamScopeIfPresent(
        _ identity: ConditionalRequestIdentity,
        in database: Database
    ) throws {
        let row = try Row.fetchOne(
            database,
            sql: """
                SELECT account_id, organization_id, feature
                FROM sync_streams
                WHERE id = ?
            """,
            arguments: [identity.streamID.rawValue]
        )
        guard let row else { return }
        let accountID: String? = row["account_id"]
        let organizationID: String? = row["organization_id"]
        let feature: String? = row["feature"]
        guard accountID == identity.scope.accountID.rawValue,
              organizationID == identity.scope.organizationID.rawValue,
              feature == identity.feature.rawValue
        else {
            throw ConditionalRequestCacheRepositoryError.streamScopeMismatch
        }
    }

    private nonisolated static func validateAuthorityScope(
        _ identity: ConditionalRequestIdentity,
        in database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM accounts
                JOIN account_organizations
                  ON account_organizations.account_id = accounts.id
                WHERE accounts.id = ?
                  AND account_organizations.organization_id = ?
                  AND accounts.credential_revision = ?
                  AND account_organizations.capability_revision = ?
            """,
            arguments: [
                identity.scope.accountID.rawValue,
                identity.scope.organizationID.rawValue,
                identity.scope.credentialRevision.rawValue,
                identity.scope.capabilityRevision.rawValue
            ]
        ) ?? 0
        guard count == 1 else {
            throw ConditionalRequestCacheRepositoryError.authorityScopeMismatch
        }
    }

    private nonisolated static func validRequestKey(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 2_048
            && !containsHTTPControlCharacter(value)
    }

    private nonisolated static func validHeaderValidator(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && value.count <= 2_048
            && !containsHTTPControlCharacter(value)
    }

    private nonisolated static func containsHTTPControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
