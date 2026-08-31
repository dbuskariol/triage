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
    /// The persisted user preference; `nil` remains Auto.
    let selectedModelID: String?
    /// The exact authenticated runtime model used to produce this analysis.
    /// This is intentionally distinct from the Auto preference so a changed
    /// runtime default cannot match an earlier cache row.
    let effectiveModelID: String
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
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, fingerprint, model_id, prompt_version, output_schema_version, result_json, created_at_ms
                    FROM ai_analyses
                    WHERE work_item_id = ? AND fingerprint = ?
                      AND model_id = ?
                      AND prompt_version = ? AND output_schema_version = ?
                    ORDER BY created_at_ms DESC, id DESC
                    LIMIT 1
                    """,
                arguments: [
                    key.workItemID.rawValue, key.fingerprint, key.effectiveModelID,
                    key.promptVersion, key.outputSchemaVersion
                ]
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
              analysis.key.selectedModelID == nil
                || analysis.key.selectedModelID == analysis.key.effectiveModelID,
              analysis.key.effectiveModelID == analysis.modelID
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
        selectedModelID: String?,
        effectiveModelID: String,
        actionItems: [ActionItem] = []
    ) async throws {
        try validateScope(scope)
        try Self.validate(analysis.key)
        guard analysis.key.selectedModelID == selectedModelID,
              analysis.key.effectiveModelID == effectiveModelID,
              Self.isValidModelID(analysis.modelID),
              !analysis.id.isEmpty,
              analysis.id.utf8.count <= 512,
              analysis.resultJSON.count <= Self.maximumAnalysisJSONBytes,
              (try? JSONSerialization.jsonObject(with: analysis.resultJSON)) != nil,
              analysis.createdAt.timeIntervalSinceReferenceDate.isFinite,
              analysis.key.selectedModelID == nil
                || analysis.key.selectedModelID == analysis.key.effectiveModelID,
              analysis.key.effectiveModelID == analysis.modelID,
              actionItems.allSatisfy({
                  Self.isValidAuthorizedAction($0, analysis: analysis)
              })
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
            for actionItem in actionItems {
                // A stable source-fingerprint-derived ID means a user
                // dismissal or correction wins over a late/retried helper
                // response. Never upsert an existing Copilot action.
                try database.execute(
                    sql: """
                        INSERT INTO action_items (
                            id, work_item_id, title, detail, origin, state, priority, due_at_ms,
                            source_fingerprint, created_at_ms, updated_at_ms, completed_at_ms, dismissed_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO NOTHING
                        """,
                    arguments: [
                        actionItem.id.rawValue,
                        actionItem.workItemID.rawValue,
                        actionItem.title,
                        actionItem.detail,
                        actionItem.origin.rawValue,
                        actionItem.state.rawValue,
                        actionItem.priority.rawValue,
                        actionItem.dueAt.map(Self.milliseconds),
                        actionItem.sourceFingerprint,
                        Self.milliseconds(actionItem.createdAt),
                        Self.milliseconds(actionItem.updatedAt),
                        actionItem.completedAt.map(Self.milliseconds),
                        actionItem.dismissedAt.map(Self.milliseconds)
                    ]
                )
                for evidenceID in actionItem.evidenceIDs {
                    try database.execute(
                        sql: """
                            INSERT OR IGNORE INTO action_item_evidence (action_item_id, evidence_id)
                            VALUES (?, ?)
                            """,
                        arguments: [actionItem.id.rawValue, evidenceID.rawValue]
                    )
                }
            }
        }
    }

    /// Returns whether the person has already rejected a Copilot action for
    /// this exact content fingerprint. A changed bounded input produces a new
    /// fingerprint and can be considered again; unchanged content cannot.
    func hasDismissedCopilotAction(
        for scope: SynchronizationScope,
        workItemID: WorkItemID,
        sourceFingerprint: String
    ) async throws -> Bool {
        try validateScope(scope)
        guard Self.isFingerprint(sourceFingerprint) else {
            throw AIAnalysisRepositoryError.invalidFingerprint
        }
        return try await vault.read { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validateWorkItem(workItemID, scope: scope, in: database)
            return (try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM action_items
                    WHERE work_item_id = ? AND origin = 'copilot'
                      AND source_fingerprint = ? AND state = 'dismissed'
                    """,
                arguments: [workItemID.rawValue, sourceFingerprint]
            ) ?? 0) > 0
        }
    }

    /// A dismissal is retained with its exact source fingerprint. It is a
    /// local user decision, not a GitHub mutation, and blocks only a replay of
    /// unchanged candidate content.
    func dismissCopilotAction(
        _ actionItemID: ActionItemID,
        for scope: SynchronizationScope,
        at date: Date = .now
    ) async throws {
        try validateScope(scope)
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw AIAnalysisRepositoryError.invalidDate
        }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            let sourceFingerprint = try Self.copilotActionFingerprint(
                actionItemID,
                scope: scope,
                in: database
            )
            try database.execute(
                sql: """
                    UPDATE action_items
                    SET state = 'dismissed', dismissed_at_ms = ?, updated_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [Self.milliseconds(date), Self.milliseconds(date), actionItemID.rawValue]
            )
            try Self.insertUserCorrection(
                workItemID: try Self.copilotActionWorkItemID(actionItemID, in: database),
                actionItemID: actionItemID,
                sourceFingerprint: sourceFingerprint,
                kind: "dismissed",
                detail: nil,
                at: date,
                in: database
            )
        }
    }

    /// Corrections remain local and preserve source/evidence provenance. A
    /// corrected action still carries the old fingerprint, so it does not
    /// retrigger unless normalized input changes materially.
    func correctCopilotAction(
        _ actionItemID: ActionItemID,
        edit: LocalActionItemEdit,
        for scope: SynchronizationScope,
        at date: Date = .now
    ) async throws {
        try validateScope(scope)
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw AIAnalysisRepositoryError.invalidDate
        }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            let sourceFingerprint = try Self.copilotActionFingerprint(
                actionItemID,
                scope: scope,
                in: database
            )
            let workItemID = try Self.copilotActionWorkItemID(actionItemID, in: database)
            try database.execute(
                sql: """
                    UPDATE action_items
                    SET title = ?, detail = ?, priority = ?, due_at_ms = ?, updated_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    edit.title,
                    edit.detail,
                    edit.priority.rawValue,
                    edit.dueAt.map(Self.milliseconds),
                    Self.milliseconds(date),
                    actionItemID.rawValue
                ]
            )
            try Self.insertUserCorrection(
                workItemID: workItemID,
                actionItemID: actionItemID,
                sourceFingerprint: sourceFingerprint,
                kind: "corrected",
                detail: edit.detail,
                at: date,
                in: database
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

    /// A model choice changes analysis authority but not the authenticated
    /// runtime's bounded, encrypted model inventory. Keep that inventory so a
    /// user can select another currently available model without silently
    /// falling back to an ambient or uncached value.
    func eraseOrganizationAIOutputs(
        for accountID: AccountID,
        organizationID: OrganizationID,
        at date: Date = .now
    ) async throws {
        try validateVaultAccount(accountID)
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw AIAnalysisRepositoryError.invalidDate }
        try await vault.writeTransaction { database in
            try AIConsentRepository.validateConnectedOrganization(accountID, organizationID, in: database)
            try Self.eraseOutputs(accountID: accountID, organizationID: organizationID, in: database)
        }
    }

    func invalidateModelCache(
        for accountID: AccountID,
        organizationID: OrganizationID
    ) async throws {
        try validateVaultAccount(accountID)
        try await vault.writeTransaction { database in
            try AIConsentRepository.validateConnectedOrganization(accountID, organizationID, in: database)
            try database.execute(
                sql: "DELETE FROM ai_model_cache WHERE account_id = ? AND organization_id = ?",
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
        }
    }

    /// Runtime and credential authority are account-wide.  A transition at
    /// either boundary must not leave a different organization's encrypted
    /// 24-hour model inventory available for reuse.
    func invalidateModelCaches(for accountID: AccountID) async throws {
        try validateVaultAccount(accountID)
        try await vault.writeTransaction { database in
            try database.execute(
                sql: "DELETE FROM ai_model_cache WHERE account_id = ?",
                arguments: [accountID.rawValue]
            )
        }
    }

    private static func eraseArtifacts(
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws {
        try eraseOutputs(accountID: accountID, organizationID: organizationID, in: database)
        try database.execute(
            sql: "DELETE FROM ai_model_cache WHERE account_id = ? AND organization_id = ?",
            arguments: [accountID.rawValue, organizationID.rawValue]
        )
    }

    private static func eraseOutputs(
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

    private static func copilotActionFingerprint(
        _ actionItemID: ActionItemID,
        scope: SynchronizationScope,
        in database: Database
    ) throws -> String {
        guard let fingerprint: String = try Row.fetchOne(
            database,
            sql: """
                SELECT action_items.source_fingerprint
                FROM action_items
                JOIN work_items ON work_items.id = action_items.work_item_id
                WHERE action_items.id = ? AND action_items.origin = 'copilot'
                  AND work_items.account_id = ? AND work_items.organization_id = ?
                """,
            arguments: [actionItemID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue]
        )?["source_fingerprint"], isFingerprint(fingerprint)
        else { throw AIAnalysisRepositoryError.invalidPayload }
        return fingerprint
    }

    private static func copilotActionWorkItemID(
        _ actionItemID: ActionItemID,
        in database: Database
    ) throws -> WorkItemID {
        guard let rawValue: String = try Row.fetchOne(
            database,
            sql: "SELECT work_item_id FROM action_items WHERE id = ?",
            arguments: [actionItemID.rawValue]
        )?["work_item_id"], let workItemID = WorkItemID(rawValue: rawValue)
        else { throw AIAnalysisRepositoryError.invalidPayload }
        return workItemID
    }

    private static func insertUserCorrection(
        workItemID: WorkItemID,
        actionItemID: ActionItemID,
        sourceFingerprint: String,
        kind: String,
        detail: String?,
        at date: Date,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO user_corrections (
                    id, work_item_id, action_item_id, source_fingerprint,
                    correction_kind, detail, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                "copilot-correction-\(UUID().uuidString.lowercased())",
                workItemID.rawValue,
                actionItemID.rawValue,
                sourceFingerprint,
                kind,
                detail,
                milliseconds(date)
            ]
        )
    }

    private static func validate(_ key: AIAnalysisCacheKey) throws {
        guard isFingerprint(key.fingerprint) else { throw AIAnalysisRepositoryError.invalidFingerprint }
        guard key.selectedModelID.map(isValidModelID) ?? true else { throw AIAnalysisRepositoryError.invalidModelID }
        guard isValidModelID(key.effectiveModelID) else { throw AIAnalysisRepositoryError.invalidModelID }
        guard key.promptVersion > 0, key.outputSchemaVersion > 0 else {
            throw AIAnalysisRepositoryError.invalidVersion
        }
    }

    private static func isValidAuthorizedAction(
        _ action: ActionItem,
        analysis: StoredAIAnalysis
    ) -> Bool {
        action.workItemID == analysis.key.workItemID
            && action.origin == .copilot
            && action.state == .open
            && action.sourceFingerprint == analysis.key.fingerprint
            && !action.id.rawValue.isEmpty
            && action.id.rawValue.utf8.count <= 512
            && !action.title.isEmpty
            && action.title.utf8.count <= 500
            && action.detail?.utf8.count ?? 0 <= 10_000
            && !action.evidenceIDs.isEmpty
            && Set(action.evidenceIDs).count == action.evidenceIDs.count
            && (action.dueAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
            && action.createdAt.timeIntervalSinceReferenceDate.isFinite
            && action.updatedAt.timeIntervalSinceReferenceDate.isFinite
    }

    private static func analysis(_ row: Row, expectedKey: AIAnalysisCacheKey) throws -> StoredAIAnalysis {
        guard let id: String = row["id"], !id.isEmpty,
              let fingerprint: String = row["fingerprint"], fingerprint == expectedKey.fingerprint,
              let modelID: String = row["model_id"], modelID == expectedKey.effectiveModelID,
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
