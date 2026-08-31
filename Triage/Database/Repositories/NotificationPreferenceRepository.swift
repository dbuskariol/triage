import Foundation
import GRDB

enum NotificationPreferenceRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationOutsideAccount
    case invalidPersistedData
}

/// Encrypted, account-and-organization-scoped notification consent. The
/// repository deliberately has no UserDefaults fallback: without an opened
/// vault and a matching account-organization membership, consent is absent.
actor NotificationPreferenceRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func isEnabled(accountID: AccountID, organizationID: OrganizationID) async throws -> Bool {
        try validateVaultAccount(accountID)
        return try await vault.read { database in
            try Self.validateOrganization(accountID: accountID, organizationID: organizationID, in: database)
            guard let value: Bool = try Bool.fetchOne(
                database,
                sql: """
                    SELECT is_enabled
                    FROM notification_preferences
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            ) else {
                return false
            }
            return value
        }
    }

    func setEnabled(
        _ isEnabled: Bool,
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws {
        try await setEnabled(
            isEnabled,
            accountID: accountID,
            organizationID: organizationID,
            at: .now
        )
    }

    func setEnabled(
        _ isEnabled: Bool,
        accountID: AccountID,
        organizationID: OrganizationID,
        at updatedAt: Date = .now
    ) async throws {
        try validateVaultAccount(accountID)
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NotificationPreferenceRepositoryError.invalidPersistedData
        }
        try await vault.writeTransaction { database in
            try Self.validateOrganization(accountID: accountID, organizationID: organizationID, in: database)
            try database.execute(
                sql: """
                    INSERT INTO notification_preferences (
                        account_id, organization_id, is_enabled, updated_at_ms
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET
                        is_enabled = excluded.is_enabled,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    accountID.rawValue,
                    organizationID.rawValue,
                    isEnabled,
                    Int64((updatedAt.timeIntervalSince1970 * 1_000).rounded())
                ]
            )
        }
    }

    /// Explicitly removes this account's notification consent before account
    /// teardown. Account deletion also cascades this table, but this method
    /// keeps crypto-erasure ordering auditable when teardown is interrupted.
    func removeAll(accountID: AccountID) async throws {
        try validateVaultAccount(accountID)
        try await vault.write { database in
            try database.execute(
                sql: "DELETE FROM notification_preferences WHERE account_id = ?",
                arguments: [accountID.rawValue]
            )
        }
    }

    private func validateVaultAccount(_ accountID: AccountID) throws {
        guard vault.accountID == accountID else {
            throw NotificationPreferenceRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func validateOrganization(
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws {
        let belongs = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM account_organizations
                    WHERE account_id = ? AND organization_id = ?
                )
                """,
            arguments: [accountID.rawValue, organizationID.rawValue]
        ) ?? false
        guard belongs else {
            throw NotificationPreferenceRepositoryError.organizationOutsideAccount
        }
    }
}
