import Foundation
import GRDB

enum AIConsentRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationNotConnected
    case invalidModelID
    case invalidUpdatedAt
    case invalidPersistedData
}

/// The explicit, local authorization to send bounded organization content to
/// the Copilot boundary. A missing record is intentionally indistinguishable
/// from a disabled record to callers that only need an effective policy.
struct OrganizationAIConsent: Equatable, Sendable {
    let accountID: AccountID
    let organizationID: OrganizationID
    let isEnabled: Bool
    /// `nil` represents Copilot's explicit Auto selection, never an inferred
    /// model chosen by Triage.
    let selectedModelID: String?
    let updatedAt: Date?

    static func disabled(accountID: AccountID, organizationID: OrganizationID) -> Self {
        .init(
            accountID: accountID,
            organizationID: organizationID,
            isEnabled: false,
            selectedModelID: nil,
            updatedAt: nil
        )
    }
}

actor AIConsentRepository {
    static let maximumModelIDBytes = 512

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func consent(
        for accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> OrganizationAIConsent {
        try validateVaultAccount(accountID)
        return try await vault.read { database in
            try Self.validateConnectedOrganization(accountID, organizationID, in: database)
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT enabled, selected_model, updated_at_ms
                    FROM ai_consents
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            ) else {
                return .disabled(accountID: accountID, organizationID: organizationID)
            }
            // A NULL model is the durable representation of Auto (and of a
            // disabled consent), so it must be decoded as an optional value,
            // not optional-bound by the validation guard.
            let selectedModelID: String? = row["selected_model"]
            guard let enabled: Bool = row["enabled"],
                  let milliseconds: Int64 = row["updated_at_ms"],
                  let updatedAt = Self.date(milliseconds: milliseconds),
                  Self.isValidModelID(selectedModelID)
            else {
                throw AIConsentRepositoryError.invalidPersistedData
            }
            return OrganizationAIConsent(
                accountID: accountID,
                organizationID: organizationID,
                isEnabled: enabled,
                selectedModelID: enabled ? selectedModelID : nil,
                updatedAt: updatedAt
            )
        }
    }

    func save(_ consent: OrganizationAIConsent, at updatedAt: Date = .now) async throws {
        try validateVaultAccount(consent.accountID)
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AIConsentRepositoryError.invalidUpdatedAt
        }
        let selectedModelID = consent.isEnabled ? consent.selectedModelID : nil
        guard Self.isValidModelID(selectedModelID) else {
            throw AIConsentRepositoryError.invalidModelID
        }
        try await vault.writeTransaction { database in
            try Self.validateConnectedOrganization(consent.accountID, consent.organizationID, in: database)
            try database.execute(
                sql: """
                    INSERT INTO ai_consents (account_id, organization_id, enabled, selected_model, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET
                        enabled = excluded.enabled,
                        selected_model = excluded.selected_model,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    consent.accountID.rawValue,
                    consent.organizationID.rawValue,
                    consent.isEnabled,
                    selectedModelID,
                    Self.milliseconds(updatedAt)
                ]
            )
        }
    }

    func disable(
        accountID: AccountID,
        organizationID: OrganizationID,
        at updatedAt: Date = .now
    ) async throws {
        try await save(
            .init(
                accountID: accountID,
                organizationID: organizationID,
                isEnabled: false,
                selectedModelID: nil,
                updatedAt: updatedAt
            ),
            at: updatedAt
        )
    }

    private func validateVaultAccount(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw AIConsentRepositoryError.accountScopeMismatch
        }
    }

    nonisolated static func validateConnectedOrganization(
        _ accountID: AccountID,
        _ organizationID: OrganizationID,
        in database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM account_organizations
                JOIN accounts ON accounts.id = account_organizations.account_id
                WHERE account_organizations.account_id = ?
                  AND account_organizations.organization_id = ?
                  AND accounts.disabled_at_ms IS NULL
                """,
            arguments: [accountID.rawValue, organizationID.rawValue]
        ) ?? 0
        guard count == 1 else {
            throw AIConsentRepositoryError.organizationNotConnected
        }
    }

    nonisolated static func isValidModelID(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && value.utf8.count <= maximumModelIDBytes
            && value.unicodeScalars.allSatisfy {
                !$0.properties.isWhitespace && $0.properties.generalCategory != .control
            }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func date(milliseconds: Int64) -> Date? {
        let value = Double(milliseconds) / 1_000
        guard value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}
