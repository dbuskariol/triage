import Foundation
import GRDB

enum AIAnalysisRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationNotConnected
    case workItemScopeMismatch
    case invalidFingerprint
    case invalidModelID
    case invalidVersion
    case invalidDate
    case invalidPayload
    case invalidModelCache
    case invalidPersistedData
}

struct AIAnalysisCacheKey: Equatable, Sendable {
    let workItemID: WorkItemID
    let fingerprint: String
    let selectedModelID: String?
    let promptVersion: Int
    let outputSchemaVersion: Int
}

struct StoredAIAnalysis: Equatable, Sendable {
    let id: String
    let key: AIAnalysisCacheKey
    let modelID: String
    let resultJSON: Data
    let createdAt: Date
}

/// Local-only persistence for Copilot responses and model metadata. This
/// repository neither launches a helper nor treats a cached response as
/// authority to run AI; its callers must still resolve policy every time.
actor AIAnalysisRepository {
    static let maximumModelCount = 100
    static let maximumAnalysisJSONBytes = 256 * 1_024
    static let maximumMetadataJSONBytes = 16 * 1_024
    static let maximumModelCacheLifetime: TimeInterval = 24 * 60 * 60

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func cachedModels(
        for accountID: AccountID,
        organizationID: OrganizationID,
        at date: Date = .now
    ) async throws -> [CopilotModel] {
        try validateVaultAccount(accountID)
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw AIAnalysisRepositoryError.invalidDate }
        return try await vault.read { database in
            try AIConsentRepository.validateConnectedOrganization(accountID, organizationID, in: database)
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT model_id, metadata_json, expires_at_ms
                    FROM ai_model_cache
                    WHERE account_id = ? AND organization_id = ? AND expires_at_ms > ?
                    ORDER BY model_id
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue, Self.milliseconds(date)]
            )
            return try rows.map { row in
                guard let modelID: String = row["model_id"],
                      let metadata: Data = row["metadata_json"],
                      metadata.count <= Self.maximumMetadataJSONBytes,
                      Self.isValidModelID(modelID),
                      let model = try? JSONDecoder().decode(CopilotModel.self, from: metadata),
                      model.id == modelID,
                      Self.isValidModel(model)
                else {
                    throw AIAnalysisRepositoryError.invalidPersistedData
                }
                return model
            }
        }
    }

    func replaceModels(
        _ models: [CopilotModel],
        for accountID: AccountID,
        organizationID: OrganizationID,
        expiresAt: Date,
        at date: Date = .now
    ) async throws {
        try validateVaultAccount(accountID)
        guard date.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt > date,
              expiresAt.timeIntervalSince(date) <= Self.maximumModelCacheLifetime,
              models.count <= Self.maximumModelCount,
              Set(models.map(\.id)).count == models.count,
              models.allSatisfy(Self.isValidModel)
        else { throw AIAnalysisRepositoryError.invalidModelCache }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let values = try models.sorted { $0.id < $1.id }.map { model -> (CopilotModel, Data) in
            let data = try encoder.encode(model)
            guard data.count <= Self.maximumMetadataJSONBytes else {
                throw AIAnalysisRepositoryError.invalidModelCache
            }
            return (model, data)
        }
        try await vault.writeTransaction { database in
            try AIConsentRepository.validateConnectedOrganization(accountID, organizationID, in: database)
            try database.execute(
                sql: "DELETE FROM ai_model_cache WHERE account_id = ? AND organization_id = ?",
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
            for (model, metadata) in values {
                try database.execute(
                    sql: """
                        INSERT INTO ai_model_cache (account_id, organization_id, model_id, metadata_json, expires_at_ms)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        accountID.rawValue, organizationID.rawValue, model.id,
                        metadata, Self.milliseconds(expiresAt)
                    ]
                )
            }
        }
    }

    func validAnalysis(
        for scope: SynchronizationScope,
        key: AIAnalysisCacheKey,
        at date: Date = .now
    ) async throws -> StoredAIAnalysis? {
        try validateScope(scope)
        try Self.validate(key)
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw AIAnalysisRepositoryError.invalidDate }
        return try await vault.read { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validateWorkItem(key.workItemID, scope: scope, in: database)
            let modelClause: String
            let arguments: StatementArguments
            if let selectedModelID = key.selectedModelID {
                modelClause = "AND ai_analyses.model_id = ?"
                arguments = [
                    key.workItemID.rawValue, key.fingerprint, selectedModelID,
                    key.promptVersion, key.outputSchemaVersion
                ]
            } else {
                modelClause = ""
                arguments = [key.workItemID.rawValue, key.fingerprint, key.promptVersion, key.outputSchemaVersion]
            }
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, fingerprint, model_id, prompt_version, output_schema_version, result_json, created_at_ms
                    FROM ai_analyses
                    WHERE work_item_id = ? AND fingerprint = ?
                      \(modelClause)
                      AND prompt_version = ? AND output_schema_version = ?
                    ORDER BY created_at_ms DESC, id DESC
                    LIMIT 1
                    """,
                arguments: arguments
            ) else { return nil }
            return try Self.analysis(row, expectedKey: key)
        }
    }

    func save(
        _ analysis: StoredAIAnalysis,
        for scope: SynchronizationScope
    ) async throws {
        try validateScope(scope)
        try Self.validate(analysis.key)
        guard Self.isValidModelID(analysis.modelID),
              !analysis.id.isEmpty,
              analysis.id.utf8.count <= 512,
              analysis.resultJSON.count <= Self.maximumAnalysisJSONBytes,
              (try? JSONSerialization.jsonObject(with: analysis.resultJSON)) != nil,
              analysis.createdAt.timeIntervalSinceReferenceDate.isFinite,
              analysis.key.selectedModelID == nil || analysis.key.selectedModelID == analysis.modelID
        else { throw AIAnalysisRepositoryError.invalidPayload }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validateWorkItem(analysis.key.workItemID, scope: scope, in: database)
            try database.execute(
                sql: """
                    INSERT INTO ai_analyses (
                        id, work_item_id, fingerprint, model_id, prompt_version,
                        output_schema_version, result_json, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(work_item_id, fingerprint, model_id, prompt_version, output_schema_version)
                    DO UPDATE SET id = excluded.id, result_json = excluded.result_json,
                                  created_at_ms = excluded.created_at_ms
                    """,
                arguments: [
                    analysis.id, analysis.key.workItemID.rawValue, analysis.key.fingerprint,
                    analysis.modelID, analysis.key.promptVersion, analysis.key.outputSchemaVersion,
                    analysis.resultJSON, Self.milliseconds(analysis.createdAt)
                ]
            )
        }
    }

    /// Controller-only commit boundary. Scope, connected organization, and
    /// the exact persisted consent/model choice are checked in the same write
    /// transaction as the AI payload, so a stale lease cannot commit after an
    /// authority or consent change.
    func saveAuthorized(
        _ analysis: StoredAIAnalysis,
        for scope: SynchronizationScope,
        selectedModelID: String?
    ) async throws {
        try validateScope(scope)
        try Self.validate(analysis.key)
        guard analysis.key.selectedModelID == selectedModelID,
              Self.isValidModelID(analysis.modelID),
              !analysis.id.isEmpty,
              analysis.id.utf8.count <= 512,
              analysis.resultJSON.count <= Self.maximumAnalysisJSONBytes,
              (try? JSONSerialization.jsonObject(with: analysis.resultJSON)) != nil,
              analysis.createdAt.timeIntervalSinceReferenceDate.isFinite,
              analysis.key.selectedModelID == nil || analysis.key.selectedModelID == analysis.modelID
        else { throw AIAnalysisRepositoryError.invalidPayload }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validateAuthorizedConsent(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                selectedModelID: selectedModelID,
                in: database
            )
            try Self.validateWorkItem(analysis.key.workItemID, scope: scope, in: database)
            try database.execute(
                sql: """
                    INSERT INTO ai_analyses (
                        id, work_item_id, fingerprint, model_id, prompt_version,
                        output_schema_version, result_json, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(work_item_id, fingerprint, model_id, prompt_version, output_schema_version)
                    DO UPDATE SET id = excluded.id, result_json = excluded.result_json,
                                  created_at_ms = excluded.created_at_ms
                    """,
                arguments: [
                    analysis.id, analysis.key.workItemID.rawValue, analysis.key.fingerprint,
                    analysis.modelID, analysis.key.promptVersion, analysis.key.outputSchemaVersion,
                    analysis.resultJSON, Self.milliseconds(analysis.createdAt)
                ]
            )
        }
    }

    /// Removes only derived/copilot material for one connected organization.
    /// Source content, deterministic/manual action items, and corrections are
    /// deliberately retained. Foreign-key behaviour leaves corrections intact
    /// while detaching a removed Copilot action item.
    func eraseOrganizationAIData(
        for accountID: AccountID,
        organizationID: OrganizationID,
        at date: Date = .now
    ) async throws {
        try validateVaultAccount(accountID)
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw AIAnalysisRepositoryError.invalidDate }
        try await vault.writeTransaction { database in
            try AIConsentRepository.validateConnectedOrganization(accountID, organizationID, in: database)
            try database.execute(
                sql: """
                    INSERT INTO ai_consents (account_id, organization_id, enabled, selected_model, updated_at_ms)
                    VALUES (?, ?, 0, NULL, ?)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET
                        enabled = 0, selected_model = NULL, updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue, Self.milliseconds(date)]
            )
            try Self.eraseArtifacts(accountID: accountID, organizationID: organizationID, in: database)
        }
    }

    /// Erases the private local AI material while retaining the consent row so
    /// a model replacement can atomically establish a new consent afterward.
    func eraseOrganizationAIArtifacts(
        for accountID: AccountID,
        organizationID: OrganizationID,
        at date: Date = .now
    ) async throws {
        try validateVaultAccount(accountID)
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw AIAnalysisRepositoryError.invalidDate }
        try await vault.writeTransaction { database in
            try AIConsentRepository.validateConnectedOrganization(accountID, organizationID, in: database)
            try Self.eraseArtifacts(accountID: accountID, organizationID: organizationID, in: database)
        }
    }

    private static func eraseArtifacts(
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws {
        try database.execute(
                sql: """
                    DELETE FROM ai_analyses
                    WHERE work_item_id IN (
                        SELECT id FROM work_items WHERE account_id = ? AND organization_id = ?
                    )
                """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
        try database.execute(
                sql: "DELETE FROM ai_model_cache WHERE account_id = ? AND organization_id = ?",
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
        try database.execute(
                sql: "DELETE FROM ai_action_candidates WHERE account_id = ? AND organization_id = ?",
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
        try database.execute(
                sql: """
                    DELETE FROM action_items
                    WHERE origin = 'copilot' AND work_item_id IN (
                        SELECT id FROM work_items WHERE account_id = ? AND organization_id = ?
                    )
                """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
    }

    private func validateVaultAccount(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else { throw AIAnalysisRepositoryError.accountScopeMismatch }
    }

    private func validateScope(_ scope: SynchronizationScope) throws {
        try validateVaultAccount(scope.accountID)
    }

    private static func validateCurrentScope(_ scope: SynchronizationScope, in database: Database) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        } catch {
            throw AIAnalysisRepositoryError.organizationNotConnected
        }
    }

    private static func validateAuthorizedConsent(
        accountID: AccountID,
        organizationID: OrganizationID,
        selectedModelID: String?,
        in database: Database
    ) throws {
        let row = try Row.fetchOne(
            database,
            sql: """
                SELECT enabled, selected_model
                FROM ai_consents
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [accountID.rawValue, organizationID.rawValue]
        )
        guard let row else { throw AIAnalysisRepositoryError.organizationNotConnected }
        let persistedModelID: String? = row["selected_model"]
        guard let enabled: Bool = row["enabled"],
              enabled,
              persistedModelID == selectedModelID
        else { throw AIAnalysisRepositoryError.organizationNotConnected }
    }

    private static func validateWorkItem(_ id: WorkItemID, scope: SynchronizationScope, in database: Database) throws {
        let count = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM work_items WHERE id = ? AND account_id = ? AND organization_id = ?",
            arguments: [id.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue]
        ) ?? 0
        guard count == 1 else { throw AIAnalysisRepositoryError.workItemScopeMismatch }
    }

    private static func validate(_ key: AIAnalysisCacheKey) throws {
        guard isFingerprint(key.fingerprint) else { throw AIAnalysisRepositoryError.invalidFingerprint }
        guard key.selectedModelID.map(isValidModelID) ?? true else { throw AIAnalysisRepositoryError.invalidModelID }
        guard key.promptVersion > 0, key.outputSchemaVersion > 0 else {
            throw AIAnalysisRepositoryError.invalidVersion
        }
    }

    private static func analysis(_ row: Row, expectedKey: AIAnalysisCacheKey) throws -> StoredAIAnalysis {
        guard let id: String = row["id"], !id.isEmpty,
              let fingerprint: String = row["fingerprint"], fingerprint == expectedKey.fingerprint,
              let modelID: String = row["model_id"], isValidModelID(modelID),
              let promptVersion: Int = row["prompt_version"], promptVersion == expectedKey.promptVersion,
              let outputSchemaVersion: Int = row["output_schema_version"], outputSchemaVersion == expectedKey.outputSchemaVersion,
              let resultJSON: Data = row["result_json"], resultJSON.count <= Self.maximumAnalysisJSONBytes,
              (try? JSONSerialization.jsonObject(with: resultJSON)) != nil,
              let milliseconds: Int64 = row["created_at_ms"],
              let createdAt = date(milliseconds: milliseconds)
        else { throw AIAnalysisRepositoryError.invalidPersistedData }
        return StoredAIAnalysis(
            id: id,
            key: expectedKey,
            modelID: modelID,
            resultJSON: resultJSON,
            createdAt: createdAt
        )
    }

    private static func isValidModel(_ model: CopilotModel) -> Bool {
        isValidModelID(model.id)
            && !model.displayName.isEmpty
            && model.displayName.utf8.count <= 1_024
            && !model.displayName.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }

    private static func isValidModelID(_ value: String) -> Bool {
        AIConsentRepository.isValidModelID(value)
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
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
