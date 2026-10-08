import Foundation
import GRDB

enum AIConsentRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationNotConnected
    case invalidModelID
    case invalidUpdatedAt
    case invalidPersistedData
    case invalidAutomaticActionConfidenceThreshold
}

/// The explicit, local authorization to send bounded organization content to
/// the Copilot boundary. A missing record is intentionally indistinguishable
/// from a disabled record to callers that only need an effective policy.
struct OrganizationAIConsent: Equatable, Sendable {
    static let minimumAutomaticActionConfidenceThreshold = 0.92
    static let maximumAutomaticActionConfidenceThreshold = 1.0

    let accountID: AccountID
    let organizationID: OrganizationID
    let isEnabled: Bool
    /// `nil` represents Copilot's explicit Auto selection, never an inferred
    /// model chosen by Triage.
    let selectedModelID: String?
    /// `nil` uses the model's default effort.
    let reasoningEffort: String?
    /// `"long_context"` or `nil` for the default tier.
    let contextTier: String?
    /// The model for Draft Reply; `nil` uses the triage choice.
    let replyChoice: CopilotModelChoice?
    /// Organization-local safety floor for automatic Inbox actions.  This is
    /// not a helper instruction and never lowers the product-wide minimum.
    let automaticActionConfidenceThreshold: Double
    let updatedAt: Date?

    init(
        accountID: AccountID,
        organizationID: OrganizationID,
        isEnabled: Bool,
        selectedModelID: String?,
        reasoningEffort: String? = nil,
        contextTier: String? = nil,
        replyChoice: CopilotModelChoice? = nil,
        automaticActionConfidenceThreshold: Double = Self.minimumAutomaticActionConfidenceThreshold,
        updatedAt: Date?
    ) {
        self.replyChoice = replyChoice
        self.accountID = accountID
        self.organizationID = organizationID
        self.isEnabled = isEnabled
        self.selectedModelID = selectedModelID
        self.reasoningEffort = reasoningEffort
        self.contextTier = contextTier
        self.automaticActionConfidenceThreshold = automaticActionConfidenceThreshold
        self.updatedAt = updatedAt
    }

    var triageChoice: CopilotModelChoice {
        CopilotModelChoice(modelID: selectedModelID, reasoningEffort: reasoningEffort, contextTier: contextTier)
    }

    /// The model used to draft replies.
    var effectiveReplyChoice: CopilotModelChoice { replyChoice ?? triageChoice }

    static func disabled(accountID: AccountID, organizationID: OrganizationID) -> Self {
        .init(
            accountID: accountID,
            organizationID: organizationID,
            isEnabled: false,
            selectedModelID: nil,
            automaticActionConfidenceThreshold: minimumAutomaticActionConfidenceThreshold,
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
                    SELECT enabled, selected_model, reasoning_effort, context_tier, automatic_action_confidence_threshold, updated_at_ms,
                           reply_custom, reply_model, reply_reasoning_effort, reply_context_tier
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
            let reasoningEffort: String? = row["reasoning_effort"]
            let contextTier: String? = row["context_tier"]
            let replyCustom: Bool = row["reply_custom"] ?? false
            let replyChoice = replyCustom ? CopilotModelChoice(
                modelID: row["reply_model"], reasoningEffort: row["reply_reasoning_effort"], contextTier: row["reply_context_tier"]
            ) : nil
            guard replyChoice?.isValid ?? true, let enabled: Bool = row["enabled"],
                  let automaticActionConfidenceThreshold: Double = row["automatic_action_confidence_threshold"],
                  let milliseconds: Int64 = row["updated_at_ms"],
                  let updatedAt = Self.date(milliseconds: milliseconds),
                  Self.isValidModelID(selectedModelID),
                  CopilotModelChoice.isValidReasoningEffort(reasoningEffort),
                  CopilotModelChoice.isValidContextTier(contextTier),
                  Self.isValidAutomaticActionConfidenceThreshold(automaticActionConfidenceThreshold)
            else {
                throw AIConsentRepositoryError.invalidPersistedData
            }
            return OrganizationAIConsent(
                accountID: accountID,
                organizationID: organizationID,
                isEnabled: enabled,
                selectedModelID: enabled ? selectedModelID : nil,
                reasoningEffort: enabled ? reasoningEffort : nil,
                contextTier: enabled ? contextTier : nil,
                replyChoice: enabled ? replyChoice : nil,
                automaticActionConfidenceThreshold: automaticActionConfidenceThreshold,
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
        guard Self.isValidModelID(selectedModelID),
              CopilotModelChoice.isValidReasoningEffort(consent.reasoningEffort),
              CopilotModelChoice.isValidContextTier(consent.contextTier),
              consent.replyChoice?.isValid ?? true
        else {
            throw AIConsentRepositoryError.invalidModelID
        }
        let reply = consent.isEnabled ? consent.replyChoice : nil
        let reasoningEffort = consent.isEnabled ? consent.reasoningEffort : nil
        let contextTier = consent.isEnabled ? consent.contextTier : nil
        guard Self.isValidAutomaticActionConfidenceThreshold(consent.automaticActionConfidenceThreshold) else {
            throw AIConsentRepositoryError.invalidAutomaticActionConfidenceThreshold
        }
        try await vault.writeTransaction { database in
            try Self.validateConnectedOrganization(consent.accountID, consent.organizationID, in: database)
            try database.execute(
                sql: """
                    INSERT INTO ai_consents (account_id, organization_id, enabled, selected_model, reasoning_effort, context_tier, automatic_action_confidence_threshold, updated_at_ms, reply_custom, reply_model, reply_reasoning_effort, reply_context_tier)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET
                        enabled = excluded.enabled,
                        selected_model = excluded.selected_model,
                        reasoning_effort = excluded.reasoning_effort,
                        context_tier = excluded.context_tier,
                        automatic_action_confidence_threshold = excluded.automatic_action_confidence_threshold,
                        updated_at_ms = excluded.updated_at_ms,
                        reply_custom = excluded.reply_custom,
                        reply_model = excluded.reply_model,
                        reply_reasoning_effort = excluded.reply_reasoning_effort,
                        reply_context_tier = excluded.reply_context_tier
                    """,
                arguments: [
                    consent.accountID.rawValue,
                    consent.organizationID.rawValue,
                    consent.isEnabled,
                    selectedModelID,
                    reasoningEffort,
                    contextTier,
                    consent.automaticActionConfidenceThreshold,
                    Self.milliseconds(updatedAt),
                    reply != nil,
                    reply?.modelID,
                    reply?.reasoningEffort,
                    reply?.contextTier
                ]
            )
        }
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

    nonisolated static func isValidAutomaticActionConfidenceThreshold(_ value: Double) -> Bool {
        value.isFinite
            && value >= OrganizationAIConsent.minimumAutomaticActionConfidenceThreshold
            && value <= OrganizationAIConsent.maximumAutomaticActionConfidenceThreshold
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
