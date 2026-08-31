import CryptoKit
import Foundation
import GRDB

enum DerivedIntelligenceRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleSynchronizationScope
    case staleSourceRevision
    case invalidEvaluationDate
    case invalidSourceRevision
    case invalidCoverage
    case duplicateWorkItem
    case duplicateReason
    case duplicateAICandidate
    case duplicateAIExclusion
    case candidateExclusionConflict
    case invalidAICandidate
    case invalidAICandidateExclusion
    case invalidEvidence
    case invalidSearchDocument
    case incompleteWorkItemSnapshot
    case workItemScopeMismatch
    case invalidPersistedData
}

struct DerivedIntelligencePersistenceItem: Sendable {
    let workItemID: WorkItemID
    let attentionReasons: [AttentionReason]
    let score: AttentionScore
    let searchDocument: SearchDocument
}

struct DerivedIntelligencePersistenceSnapshot: Sendable {
    let scope: SynchronizationScope
    /// An opaque, bounded revision for the fully committed normalized input
    /// snapshot. It is intentionally supplied by the synchronization owner:
    /// derived intelligence must not fabricate a source revision from a view.
    let sourceRevision: String
    let evaluatedAt: Date
    let coverage: CoverageEvaluation
    let coverageState: DerivedIntelligenceCoverageState
    /// This carries adapter-level source admission state which is stricter
    /// than coverage alone. A provisional input may be useful for deterministic
    /// presentation but must not authorize an AI candidate.
    let isProvisional: Bool
    let items: [DerivedIntelligencePersistenceItem]
    let aiCandidates: [DerivedAICandidate]
    let aiCandidateExclusions: [DerivedAICandidateExclusion]

    init(
        scope: SynchronizationScope,
        sourceRevision: String = "",
        evaluatedAt: Date,
        coverage: CoverageEvaluation = .unknown,
        coverageState: DerivedIntelligenceCoverageState = .unknown,
        isProvisional: Bool = true,
        items: [DerivedIntelligencePersistenceItem],
        aiCandidates: [DerivedAICandidate] = [],
        aiCandidateExclusions: [DerivedAICandidateExclusion] = []
    ) {
        self.scope = scope
        self.sourceRevision = sourceRevision
        self.evaluatedAt = evaluatedAt
        self.coverage = coverage
        self.coverageState = coverageState
        self.isProvisional = isProvisional
        self.items = items
        self.aiCandidates = aiCandidates
        self.aiCandidateExclusions = aiCandidateExclusions
    }
}

extension CoverageEvaluation {
    /// A missing source contract is unknown, not complete. This default exists
    /// only to keep older call sites compiling while they are upgraded to pass
    /// the committed source revision and actual coverage output; `replace`
    /// rejects an empty source revision.
    static let unknown = CoverageEvaluation(
        freshness: FreshnessState(status: .partial, detail: "Coverage was not supplied."),
        missing: []
    )
}

struct DerivedIntelligencePersistedRun: Equatable, Sendable {
    let scope: SynchronizationScope
    let sourceRevision: String
    let evaluatedAt: Date
    let coverage: CoverageEvaluation
    let coverageState: DerivedIntelligenceCoverageState
    let isProvisional: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope
            && lhs.sourceRevision == rhs.sourceRevision
            && lhs.evaluatedAt == rhs.evaluatedAt
            && lhs.coverage.freshness == rhs.coverage.freshness
            && lhs.coverage.missing == rhs.coverage.missing
            && lhs.coverageState == rhs.coverageState
            && lhs.isProvisional == rhs.isProvisional
    }
}

struct DerivedIntelligencePersistedCandidate: Equatable, Sendable {
    let candidate: DerivedAICandidate?
    let exclusion: DerivedAICandidateExclusion?
}

struct DerivedIntelligencePersistedProjection: Equatable, Sendable {
    let run: DerivedIntelligencePersistedRun
    let candidates: [DerivedIntelligencePersistedCandidate]
}

actor DerivedIntelligenceRepository {
    static let maximumSearchDocumentBytes = 128 * 1_024

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    /// Replaces the complete derived projection for an organization in one
    /// transaction. The snapshot must enumerate every persisted work item in
    /// the organization so stale rule, score, and FTS rows cannot survive.
    func replace(_ snapshot: DerivedIntelligencePersistenceSnapshot) async throws {
        guard snapshot.scope.accountID == vault.accountID else {
            throw DerivedIntelligenceRepositoryError.accountScopeMismatch
        }
        try Self.validate(snapshot)
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(snapshot.scope, in: database)
            try Self.validateCompleteWorkItemSnapshot(snapshot, in: database)
            try Self.validateCurrentSourceRevision(snapshot, in: database)
            try Self.deleteDerivedRows(for: snapshot.scope, in: database)
            try Self.insertRun(snapshot, in: database)
            for item in snapshot.items.sorted(by: { $0.workItemID.rawValue < $1.workItemID.rawValue }) {
                try Self.insert(item, snapshot: snapshot, in: database)
            }
            try Self.insertAICandidates(snapshot, in: database)
        }
    }

    /// Reads only a projection whose account and capability revisions still
    /// match the selected organization. Any malformed durable row is rejected
    /// rather than being softened into an empty intelligence result.
    func projection(
        for scope: SynchronizationScope
    ) async throws -> DerivedIntelligencePersistedProjection? {
        guard scope.accountID == vault.accountID else {
            throw DerivedIntelligenceRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Self.validateCurrentScope(scope, in: database)
            guard let run = try Self.fetchRun(scope: scope, in: database) else {
                return nil
            }
            try Self.validateCurrentSourceRevision(
                scope: scope,
                expectedSourceRevision: run.sourceRevision,
                in: database
            )
            let candidates = try Self.fetchCandidates(scope: scope, in: database)
            try Self.validatePersistedEvaluations(scope: scope, sourceRevision: run.sourceRevision, in: database)
            try Self.validatePersistedCandidates(
                scope: scope,
                sourceRevision: run.sourceRevision,
                coverageState: run.coverageState,
                isProvisional: run.isProvisional,
                candidates: candidates,
                in: database
            )
            return DerivedIntelligencePersistedProjection(run: run, candidates: candidates)
        }
    }

    private nonisolated static func validate(_ snapshot: DerivedIntelligencePersistenceSnapshot) throws {
        guard snapshot.evaluatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DerivedIntelligenceRepositoryError.invalidEvaluationDate
        }
        guard boundedSourceRevision(snapshot.sourceRevision) else {
            throw DerivedIntelligenceRepositoryError.invalidSourceRevision
        }
        try validateCoverage(snapshot.coverage, state: snapshot.coverageState)
        guard Set(snapshot.items.map(\.workItemID)).count == snapshot.items.count else {
            throw DerivedIntelligenceRepositoryError.duplicateWorkItem
        }
        var reasonIDs = Set<String>()
        for item in snapshot.items {
            let document = item.searchDocument
            guard document.accountID == snapshot.scope.accountID,
                  document.organizationID == snapshot.scope.organizationID,
                  document.workItemID == item.workItemID,
                  documentBytes(document) <= maximumSearchDocumentBytes
            else {
                throw DerivedIntelligenceRepositoryError.invalidSearchDocument
            }
            for reason in item.attentionReasons {
                guard reasonIDs.insert(reason.id).inserted,
                      Set(reason.evidence.map(\.id)).count == reason.evidence.count
                else {
                    throw DerivedIntelligenceRepositoryError.duplicateReason
                }
                guard reason.evaluatedAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw DerivedIntelligenceRepositoryError.invalidEvaluationDate
                }
                for evidence in reason.evidence {
                    try validate(evidence: evidence, scope: snapshot.scope)
                }
            }
        }
        let itemByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.workItemID, $0) })
        guard Set(snapshot.aiCandidates.map(\.id)).count == snapshot.aiCandidates.count else {
            throw DerivedIntelligenceRepositoryError.duplicateAICandidate
        }
        guard Set(snapshot.aiCandidateExclusions.map(\.workItemID)).count
            == snapshot.aiCandidateExclusions.count
        else {
            throw DerivedIntelligenceRepositoryError.duplicateAIExclusion
        }
        let candidateWorkItemIDs = Set(snapshot.aiCandidates.map(\.workItemID))
        let excludedWorkItemIDs = Set(snapshot.aiCandidateExclusions.map(\.workItemID))
        guard candidateWorkItemIDs.isDisjoint(with: excludedWorkItemIDs) else {
            throw DerivedIntelligenceRepositoryError.candidateExclusionConflict
        }
        guard snapshot.aiCandidates.isEmpty
                || (snapshot.coverageState == .trusted && !snapshot.isProvisional)
        else {
            throw DerivedIntelligenceRepositoryError.invalidAICandidate
        }
        for candidate in snapshot.aiCandidates {
            guard boundedIdentifier(candidate.id),
                  let item = itemByID[candidate.workItemID],
                  candidate.score == item.score,
                  !candidate.triggerReasonIDs.isEmpty,
                  Set(candidate.triggerReasonIDs).count == candidate.triggerReasonIDs.count,
                  Set(item.attentionReasons.map(\.id)).isSuperset(of: candidate.triggerReasonIDs)
            else {
                throw DerivedIntelligenceRepositoryError.invalidAICandidate
            }
        }
        for exclusion in snapshot.aiCandidateExclusions {
            guard itemByID[exclusion.workItemID] != nil,
                  snapshot.coverageState == .trusted || exclusion.reason == .incompleteCoverage
            else {
                throw DerivedIntelligenceRepositoryError.invalidAICandidateExclusion
            }
        }
    }

    private nonisolated static func validateCoverage(
        _ coverage: CoverageEvaluation,
        state: DerivedIntelligenceCoverageState
    ) throws {
        guard coverage.freshness.lastSuccessfulSyncAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              coverage.freshness.nextRetryAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              coverage.missing.allSatisfy(validCoverageRequirement)
        else {
            throw DerivedIntelligenceRepositoryError.invalidCoverage
        }
        switch state {
        case .trusted:
            guard coverage.isComplete, coverage.freshness.status == .fresh else {
                throw DerivedIntelligenceRepositoryError.invalidCoverage
            }
        case .incomplete:
            guard !coverage.isComplete else {
                throw DerivedIntelligenceRepositoryError.invalidCoverage
            }
        case .unknown:
            // An empty requirement profile intentionally has no missing rows.
            // It remains unknown, never silently trusted.
            break
        }
    }

    private nonisolated static func validateCompleteWorkItemSnapshot(
        _ snapshot: DerivedIntelligencePersistenceSnapshot,
        in database: Database
    ) throws {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, primary_node_id
                FROM work_items
                WHERE account_id = ? AND organization_id = ?
                ORDER BY id
                """,
            arguments: [snapshot.scope.accountID.rawValue, snapshot.scope.organizationID.rawValue]
        )
        guard rows.count == snapshot.items.count else {
            throw DerivedIntelligenceRepositoryError.incompleteWorkItemSnapshot
        }
        let nodesByWorkItem = Dictionary(uniqueKeysWithValues: rows.map {
            (($0["id"] as String), ($0["primary_node_id"] as String))
        })
        for item in snapshot.items {
            guard nodesByWorkItem[item.workItemID.rawValue] == item.searchDocument.nodeID.rawValue else {
                throw DerivedIntelligenceRepositoryError.workItemScopeMismatch
            }
        }
    }

    /// The adapter's aggregate source revision is a SHA-256 digest of the
    /// primary-node revision list. Recompute it inside the replacement
    /// transaction so a normalized write that races between adapter fencing
    /// and derived persistence rolls the whole replacement back.
    private nonisolated static func validateCurrentSourceRevision(
        _ snapshot: DerivedIntelligencePersistenceSnapshot,
        in database: Database
    ) throws {
        try validateCurrentSourceRevision(
            scope: snapshot.scope,
            expectedSourceRevision: snapshot.sourceRevision,
            in: database
        )
    }

    private nonisolated static func validateCurrentSourceRevision(
        scope: SynchronizationScope,
        expectedSourceRevision: String,
        in database: Database
    ) throws {
        guard try currentSourceRevision(scope: scope, in: database) == expectedSourceRevision else {
            throw DerivedIntelligenceRepositoryError.staleSourceRevision
        }
    }

    private nonisolated static func currentSourceRevision(
        scope: SynchronizationScope,
        in database: Database
    ) throws -> String {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT work_items.id, github_nodes.source_revision
                FROM work_items
                JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                WHERE work_items.account_id = ? AND work_items.organization_id = ?
                  AND github_nodes.account_id = ? AND github_nodes.organization_id = ?
                ORDER BY work_items.id
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue
            ]
        )
        var material = Data("triage.derived-input.source-revision.v1".utf8)
        for row in rows {
            guard let workItemID: String = row["id"],
                  let sourceRevision: String = row["source_revision"],
                  boundedIdentifier(workItemID),
                  boundedSourceRevision(sourceRevision)
            else {
                throw DerivedIntelligenceRepositoryError.staleSourceRevision
            }
            appendLengthPrefixed(Data(workItemID.utf8), to: &material)
            appendLengthPrefixed(Data(sourceRevision.utf8), to: &material)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func deleteDerivedRows(
        for scope: SynchronizationScope,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                DELETE FROM attention_reasons
                WHERE rule_id NOT LIKE 'discovery.%'
                  AND work_item_id IN (
                      SELECT id FROM work_items
                      WHERE account_id = ? AND organization_id = ?
                  )
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        try database.execute(
            sql: """
                DELETE FROM attention_scores
                WHERE work_item_id IN (
                    SELECT id FROM work_items
                    WHERE account_id = ? AND organization_id = ?
                )
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        try database.execute(
            sql: """
                DELETE FROM search_documents
                WHERE rowid IN (
                    SELECT id FROM search_document_metadata
                    WHERE account_id = ? AND organization_id = ?
                )
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        try database.execute(
            sql: """
                DELETE FROM search_document_metadata
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        try database.execute(
            sql: "DELETE FROM rule_evaluations WHERE account_id = ? AND organization_id = ?",
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        try database.execute(
            sql: "DELETE FROM ai_action_candidates WHERE account_id = ? AND organization_id = ?",
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
    }

    private nonisolated static func insertRun(
        _ snapshot: DerivedIntelligencePersistenceSnapshot,
        in database: Database
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try database.execute(
            sql: """
                INSERT INTO derived_intelligence_runs (
                    account_id, organization_id, credential_revision, capability_revision,
                    source_revision, evaluated_at_ms, coverage_state, freshness_status,
                    is_provisional, freshness_last_successful_at_ms,
                    freshness_next_retry_at_ms,
                    freshness_detail, missing_coverage_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id, organization_id) DO UPDATE SET
                    credential_revision = excluded.credential_revision,
                    capability_revision = excluded.capability_revision,
                    source_revision = excluded.source_revision,
                    evaluated_at_ms = excluded.evaluated_at_ms,
                    coverage_state = excluded.coverage_state,
                    freshness_status = excluded.freshness_status,
                    is_provisional = excluded.is_provisional,
                    freshness_last_successful_at_ms = excluded.freshness_last_successful_at_ms,
                    freshness_next_retry_at_ms = excluded.freshness_next_retry_at_ms,
                    freshness_detail = excluded.freshness_detail,
                    missing_coverage_json = excluded.missing_coverage_json
                """,
            arguments: [
                snapshot.scope.accountID.rawValue,
                snapshot.scope.organizationID.rawValue,
                snapshot.scope.credentialRevision.rawValue,
                snapshot.scope.capabilityRevision.rawValue,
                snapshot.sourceRevision,
                milliseconds(snapshot.evaluatedAt),
                coverageStateValue(snapshot.coverageState),
                snapshot.coverage.freshness.status.rawValue,
                snapshot.isProvisional ? 1 : 0,
                snapshot.coverage.freshness.lastSuccessfulSyncAt.map(milliseconds),
                snapshot.coverage.freshness.nextRetryAt.map(milliseconds),
                snapshot.coverage.freshness.detail,
                try encoder.encode(snapshot.coverage.missing)
            ]
        )
    }

    private nonisolated static func insert(
        _ item: DerivedIntelligencePersistenceItem,
        snapshot: DerivedIntelligencePersistenceSnapshot,
        in database: Database
    ) throws {
        for reason in item.attentionReasons.sorted(by: reasonOrder) {
            try database.execute(
                sql: """
                    INSERT INTO attention_reasons (
                        id, work_item_id, rule_id, rule_version, category, strength,
                        title, explanation, evaluated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    reason.id,
                    item.workItemID.rawValue,
                    reason.ruleID,
                    reason.ruleVersion,
                    reason.category.rawValue,
                    reason.strength,
                    reason.title,
                    reason.explanation,
                    milliseconds(reason.evaluatedAt)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO rule_evaluations (
                        id, account_id, organization_id, work_item_id,
                        credential_revision, capability_revision, source_revision,
                        rule_id, rule_version, category, strength, title, explanation,
                        evaluated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    reason.id,
                    snapshot.scope.accountID.rawValue,
                    snapshot.scope.organizationID.rawValue,
                    item.workItemID.rawValue,
                    snapshot.scope.credentialRevision.rawValue,
                    snapshot.scope.capabilityRevision.rawValue,
                    snapshot.sourceRevision,
                    reason.ruleID,
                    reason.ruleVersion,
                    reason.category.rawValue,
                    reason.strength,
                    reason.title,
                    reason.explanation,
                    milliseconds(reason.evaluatedAt)
                ]
            )
            for evidence in reason.evidence.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
                try database.execute(
                    sql: """
                        INSERT INTO attention_reason_evidence (
                            attention_reason_id, evidence_id, source, source_node_id,
                            source_event_id, source_revision, observed_at_ms, excerpt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        reason.id,
                        evidence.id.rawValue,
                        evidence.source.rawValue,
                        evidence.nodeID?.rawValue,
                        evidence.eventID?.rawValue,
                        evidence.sourceRevision,
                        milliseconds(evidence.observedAt),
                        evidence.excerpt
                    ]
                )
                try insertRuleEvaluationEvidence(
                    evidence,
                    evaluationID: reason.id,
                    in: database
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try database.execute(
            sql: """
                INSERT INTO attention_scores (work_item_id, score, breakdown_json, evaluated_at_ms)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                item.workItemID.rawValue,
                item.score.value,
                try encoder.encode(item.score.breakdown),
                milliseconds(snapshot.evaluatedAt)
            ]
        )
        let document = item.searchDocument
        try database.execute(
            sql: """
                INSERT INTO search_documents (
                    title, body, repository, labels, people, project_values, action_text, local_note
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                document.title,
                document.body,
                document.repository,
                document.labels,
                document.people,
                document.projectValues,
                document.actionText,
                document.localNote
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO search_document_metadata (
                    id, account_id, organization_id, work_item_id, github_node_id, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                database.lastInsertedRowID,
                document.accountID.rawValue,
                document.organizationID.rawValue,
                document.workItemID.rawValue,
                document.nodeID.rawValue,
                milliseconds(snapshot.evaluatedAt)
            ]
        )
    }

    private nonisolated static func insertAICandidates(
        _ snapshot: DerivedIntelligencePersistenceSnapshot,
        in database: Database
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for candidate in snapshot.aiCandidates.sorted(by: { $0.workItemID.rawValue < $1.workItemID.rawValue }) {
            try database.execute(
                sql: """
                    INSERT INTO ai_action_candidates (
                        account_id, organization_id, work_item_id, credential_revision,
                        capability_revision, source_revision, candidate_id, disposition,
                        exclusion_reason, score, score_breakdown_json,
                        trigger_reason_ids_json, evaluated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'candidate', NULL, ?, ?, ?, ?)
                    """,
                arguments: [
                    snapshot.scope.accountID.rawValue,
                    snapshot.scope.organizationID.rawValue,
                    candidate.workItemID.rawValue,
                    snapshot.scope.credentialRevision.rawValue,
                    snapshot.scope.capabilityRevision.rawValue,
                    snapshot.sourceRevision,
                    candidate.id,
                    candidate.score.value,
                    try encoder.encode(candidate.score.breakdown),
                    try encoder.encode(candidate.triggerReasonIDs.sorted()),
                    milliseconds(snapshot.evaluatedAt)
                ]
            )
        }
        for exclusion in snapshot.aiCandidateExclusions.sorted(by: { $0.workItemID.rawValue < $1.workItemID.rawValue }) {
            try database.execute(
                sql: """
                    INSERT INTO ai_action_candidates (
                        account_id, organization_id, work_item_id, credential_revision,
                        capability_revision, source_revision, candidate_id, disposition,
                        exclusion_reason, score, score_breakdown_json,
                        trigger_reason_ids_json, evaluated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL, 'excluded', ?, NULL, NULL, NULL, ?)
                    """,
                arguments: [
                    snapshot.scope.accountID.rawValue,
                    snapshot.scope.organizationID.rawValue,
                    exclusion.workItemID.rawValue,
                    snapshot.scope.credentialRevision.rawValue,
                    snapshot.scope.capabilityRevision.rawValue,
                    snapshot.sourceRevision,
                    exclusionReasonValue(exclusion.reason),
                    milliseconds(snapshot.evaluatedAt)
                ]
            )
        }
    }

    private nonisolated static func validateCurrentScope(
        _ scope: SynchronizationScope,
        in database: Database
    ) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        } catch {
            throw DerivedIntelligenceRepositoryError.staleSynchronizationScope
        }
    }

    private nonisolated static func validate(
        evidence: EvidenceReference,
        scope: SynchronizationScope
    ) throws {
        guard boundedIdentifier(evidence.id.rawValue),
              evidence.observedAt.timeIntervalSinceReferenceDate.isFinite,
              evidence.nodeID.map({ boundedIdentifier($0.rawValue) }) ?? true,
              evidence.eventID.map({ boundedIdentifier($0.rawValue) }) ?? true,
              evidence.rawSnapshotID.map({ boundedIdentifier($0.rawValue) }) ?? true,
              evidence.sourceRevision.map(boundedSourceRevision) ?? true
        else {
            throw DerivedIntelligenceRepositoryError.invalidEvidence
        }
        switch (evidence.source, evidence.locator, evidence.authority) {
        case let (source, locator, .github(authorityScope, _, _))
            where source != .localWorkflow
                && source != .legacyUnverified
                && (locator.kind == "endpoint" || locator.kind == "query")
                && authorityScope == scope:
            return
        case let (.localWorkflow, .localWorkflow(locator), .localWorkflow(accountID, organizationID))
            where !locator.isEmpty && accountID == scope.accountID && organizationID == scope.organizationID:
            return
        case (.legacyUnverified, .legacyUnverified, .legacyUnverified)
            where evidence.confidence == .provisional && evidence.confirmation == .provisional:
            // Current coordinator rules can still surface explicitly labeled
            // pre-authority evidence. Preserve it for explanation, but never
            // upgrade it into source-scoped GitHub authority.
            return
        default:
            throw DerivedIntelligenceRepositoryError.invalidEvidence
        }
    }

    private nonisolated static func insertRuleEvaluationEvidence(
        _ evidence: EvidenceReference,
        evaluationID: String,
        in database: Database
    ) throws {
        let authority = evidenceAuthorityColumns(evidence.authority)
        try validateRawSnapshotReference(
            evidence,
            authority: authority,
            in: database
        )
        try database.execute(
            sql: """
                INSERT INTO rule_evaluation_evidence (
                    rule_evaluation_id, evidence_id, source, source_locator_kind,
                    source_locator, authority_kind, authority_account_id,
                    authority_organization_id, authority_feature, authority_stream_id,
                    authority_credential_revision, authority_capability_revision,
                    source_node_id, source_event_id, source_revision, raw_snapshot_id,
                    confidence, confirmation, observed_at_ms, excerpt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                evaluationID, evidence.id.rawValue, evidence.source.rawValue,
                evidence.locator.kind, evidence.locator.value, authority.kind,
                authority.accountID, authority.organizationID, authority.feature,
                authority.streamID, authority.credentialRevision, authority.capabilityRevision,
                evidence.nodeID?.rawValue, evidence.eventID?.rawValue,
                evidence.sourceRevision, evidence.rawSnapshotID?.rawValue,
                evidence.confidence.rawValue, evidence.confirmation.rawValue,
                milliseconds(evidence.observedAt), evidence.excerpt
            ]
        )
    }

    /// A raw snapshot is provenance, not an unscoped blob reference. When an
    /// evaluator carries one, bind it to the same GitHub authority tuple that
    /// admitted the evidence before the derived replacement can mutate any
    /// presentation row. Local and explicitly legacy evidence deliberately
    /// have no replayable GitHub snapshot authority.
    private nonisolated static func validateRawSnapshotReference(
        _ evidence: EvidenceReference,
        authority: (
            kind: String,
            accountID: String?,
            organizationID: String?,
            feature: String?,
            streamID: String?,
            credentialRevision: String?,
            capabilityRevision: String?
        ),
        in database: Database
    ) throws {
        guard let rawSnapshotID = evidence.rawSnapshotID else { return }
        guard authority.kind == "github",
              let accountID = authority.accountID,
              let organizationID = authority.organizationID,
              let feature = authority.feature,
              let streamID = authority.streamID,
              let credentialRevision = authority.credentialRevision,
              let capabilityRevision = authority.capabilityRevision,
              let row = try Row.fetchOne(
                  database,
                  sql: """
                      SELECT account_id, authority_organization_id, authority_feature,
                             authority_stream_id, authority_credential_revision,
                             authority_capability_revision
                      FROM raw_api_snapshots
                      WHERE id = ?
                      """,
                  arguments: [rawSnapshotID.rawValue]
              ),
              (row["account_id"] as String?) == accountID,
              (row["authority_organization_id"] as String?) == organizationID,
              (row["authority_feature"] as String?) == feature,
              (row["authority_stream_id"] as String?) == streamID,
              (row["authority_credential_revision"] as String?) == credentialRevision,
              (row["authority_capability_revision"] as String?) == capabilityRevision
        else {
            throw DerivedIntelligenceRepositoryError.invalidEvidence
        }
    }

    private nonisolated static func fetchRun(
        scope: SynchronizationScope,
        in database: Database
    ) throws -> DerivedIntelligencePersistedRun? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT source_revision, evaluated_at_ms, coverage_state, freshness_status,
                       is_provisional,
                       freshness_last_successful_at_ms, freshness_next_retry_at_ms,
                       freshness_detail, missing_coverage_json
                FROM derived_intelligence_runs
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ]
        ) else {
            return nil
        }
        guard let sourceRevision: String = row["source_revision"],
              boundedSourceRevision(sourceRevision),
              let evaluatedAt = date(milliseconds: row["evaluated_at_ms"]),
              let coverageState = coverageState(rawValue: row["coverage_state"]),
              let isProvisional = boolean(row["is_provisional"]),
              let freshnessStatus = FreshnessStatus(rawValue: row["freshness_status"]),
              let missing: Data = row["missing_coverage_json"]
        else {
            throw DerivedIntelligenceRepositoryError.invalidPersistedData
        }
        do {
            let coverage = CoverageEvaluation(
                freshness: FreshnessState(
                    status: freshnessStatus,
                    lastSuccessfulSyncAt: date(milliseconds: row["freshness_last_successful_at_ms"]),
                    nextRetryAt: date(milliseconds: row["freshness_next_retry_at_ms"]),
                    detail: row["freshness_detail"]
                ),
                missing: try JSONDecoder().decode([CoverageRequirement].self, from: missing)
            )
            try validateCoverage(coverage, state: coverageState)
            return DerivedIntelligencePersistedRun(
                scope: scope,
                sourceRevision: sourceRevision,
                evaluatedAt: evaluatedAt,
                coverage: coverage,
                coverageState: coverageState,
                isProvisional: isProvisional
            )
        } catch let error as DerivedIntelligenceRepositoryError {
            throw error
        } catch {
            throw DerivedIntelligenceRepositoryError.invalidPersistedData
        }
    }

    private nonisolated static func fetchCandidates(
        scope: SynchronizationScope,
        in database: Database
    ) throws -> [DerivedIntelligencePersistedCandidate] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT work_item_id, candidate_id, disposition, exclusion_reason, score,
                       score_breakdown_json, trigger_reason_ids_json
                FROM ai_action_candidates
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                ORDER BY work_item_id
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ]
        ).map { row in
            guard let workItemID = WorkItemID(rawValue: row["work_item_id"]),
                  let disposition: String = row["disposition"]
            else {
                throw DerivedIntelligenceRepositoryError.invalidPersistedData
            }
            switch disposition {
            case "candidate":
                guard let id: String = row["candidate_id"],
                      boundedIdentifier(id),
                      let score: Int = row["score"],
                      let breakdown: Data = row["score_breakdown_json"],
                      let reasons: Data = row["trigger_reason_ids_json"]
                else {
                    throw DerivedIntelligenceRepositoryError.invalidPersistedData
                }
                do {
                    let triggerReasonIDs = try JSONDecoder().decode([String].self, from: reasons)
                    guard !triggerReasonIDs.isEmpty,
                          Set(triggerReasonIDs).count == triggerReasonIDs.count
                    else {
                        throw DerivedIntelligenceRepositoryError.invalidPersistedData
                    }
                    return DerivedIntelligencePersistedCandidate(
                        candidate: DerivedAICandidate(
                            id: id,
                            workItemID: workItemID,
                            score: AttentionScore(
                                value: score,
                                breakdown: try JSONDecoder().decode([String: Int].self, from: breakdown)
                            ),
                            triggerReasonIDs: triggerReasonIDs
                        ),
                        exclusion: nil
                    )
                } catch let error as DerivedIntelligenceRepositoryError {
                    throw error
                } catch {
                    throw DerivedIntelligenceRepositoryError.invalidPersistedData
                }
            case "excluded":
                guard row["candidate_id"] as String? == nil,
                      row["score"] as Int? == nil,
                      row["score_breakdown_json"] as Data? == nil,
                      row["trigger_reason_ids_json"] as Data? == nil,
                      let rawReason: String = row["exclusion_reason"],
                      let reason = exclusionReason(rawValue: rawReason)
                else {
                    throw DerivedIntelligenceRepositoryError.invalidPersistedData
                }
                return DerivedIntelligencePersistedCandidate(
                    candidate: nil,
                    exclusion: DerivedAICandidateExclusion(workItemID: workItemID, reason: reason)
                )
            default:
                throw DerivedIntelligenceRepositoryError.invalidPersistedData
            }
        }
    }

    private nonisolated static func validatePersistedEvaluations(
        scope: SynchronizationScope,
        sourceRevision: String,
        in database: Database
    ) throws {
        let malformedCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM rule_evaluations
                WHERE account_id = ? AND organization_id = ?
                  AND (
                      credential_revision != ? OR capability_revision != ?
                      OR source_revision != ?
                      OR work_item_id NOT IN (
                          SELECT id FROM work_items
                          WHERE account_id = ? AND organization_id = ?
                      )
                  )
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                sourceRevision, scope.accountID.rawValue, scope.organizationID.rawValue
            ]
        ) ?? 0
        let unmatchedEvaluationCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM rule_evaluations
                LEFT JOIN attention_reasons
                  ON attention_reasons.id = rule_evaluations.id
                 AND attention_reasons.work_item_id = rule_evaluations.work_item_id
                 AND attention_reasons.rule_id = rule_evaluations.rule_id
                 AND attention_reasons.rule_version = rule_evaluations.rule_version
                 AND attention_reasons.category = rule_evaluations.category
                 AND attention_reasons.strength = rule_evaluations.strength
                 AND attention_reasons.title = rule_evaluations.title
                 AND attention_reasons.explanation = rule_evaluations.explanation
                 AND attention_reasons.evaluated_at_ms = rule_evaluations.evaluated_at_ms
                WHERE rule_evaluations.account_id = ?
                  AND rule_evaluations.organization_id = ?
                  AND attention_reasons.id IS NULL
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        ) ?? 0
        let unmatchedAttentionReasonCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM attention_reasons
                JOIN work_items ON work_items.id = attention_reasons.work_item_id
                LEFT JOIN rule_evaluations
                  ON rule_evaluations.id = attention_reasons.id
                 AND rule_evaluations.work_item_id = attention_reasons.work_item_id
                 AND rule_evaluations.account_id = work_items.account_id
                 AND rule_evaluations.organization_id = work_items.organization_id
                 AND rule_evaluations.credential_revision = ?
                 AND rule_evaluations.capability_revision = ?
                 AND rule_evaluations.source_revision = ?
                WHERE work_items.account_id = ?
                  AND work_items.organization_id = ?
                  AND attention_reasons.rule_id NOT LIKE 'discovery.%'
                  AND rule_evaluations.id IS NULL
                """,
            arguments: [
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                sourceRevision, scope.accountID.rawValue, scope.organizationID.rawValue
            ]
        ) ?? 0
        guard malformedCount == 0,
              unmatchedEvaluationCount == 0,
              unmatchedAttentionReasonCount == 0
        else {
            throw DerivedIntelligenceRepositoryError.invalidPersistedData
        }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT rule_evaluation_evidence.evidence_id,
                       rule_evaluation_evidence.source,
                       rule_evaluation_evidence.source_locator_kind,
                       rule_evaluation_evidence.source_locator,
                       rule_evaluation_evidence.authority_kind,
                       rule_evaluation_evidence.authority_account_id,
                       rule_evaluation_evidence.authority_organization_id,
                       rule_evaluation_evidence.authority_feature,
                       rule_evaluation_evidence.authority_stream_id,
                       rule_evaluation_evidence.authority_credential_revision,
                       rule_evaluation_evidence.authority_capability_revision,
                       rule_evaluation_evidence.source_node_id,
                       rule_evaluation_evidence.source_event_id,
                       rule_evaluation_evidence.source_revision,
                       rule_evaluation_evidence.raw_snapshot_id,
                       rule_evaluation_evidence.confidence,
                       rule_evaluation_evidence.confirmation,
                       rule_evaluation_evidence.observed_at_ms,
                       rule_evaluation_evidence.excerpt
                FROM rule_evaluation_evidence
                JOIN rule_evaluations ON rule_evaluations.id = rule_evaluation_evidence.rule_evaluation_id
                WHERE rule_evaluations.account_id = ? AND rule_evaluations.organization_id = ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        for row in rows {
            try validate(evidence: try evidence(from: row), scope: scope)
        }
    }

    private nonisolated static func validatePersistedCandidates(
        scope: SynchronizationScope,
        sourceRevision: String,
        coverageState: DerivedIntelligenceCoverageState,
        isProvisional: Bool,
        candidates: [DerivedIntelligencePersistedCandidate],
        in database: Database
    ) throws {
        let malformedCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM ai_action_candidates
                WHERE account_id = ? AND organization_id = ?
                  AND (
                      credential_revision != ? OR capability_revision != ?
                      OR source_revision != ?
                      OR work_item_id NOT IN (
                          SELECT id FROM work_items
                          WHERE account_id = ? AND organization_id = ?
                      )
                  )
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                sourceRevision, scope.accountID.rawValue, scope.organizationID.rawValue
            ]
        ) ?? 0
        let candidateIDs = candidates.compactMap { $0.candidate?.id }
        let candidateWorkItemIDs = candidates.compactMap { $0.candidate?.workItemID }
        let excludedWorkItemIDs = candidates.compactMap { $0.exclusion?.workItemID }
        let exclusionsAreIncompleteCoverage = candidates.compactMap { $0.exclusion }.allSatisfy {
            $0.reason == .incompleteCoverage
        }
        guard malformedCount == 0,
              Set(candidateIDs).count == candidateIDs.count,
              Set(candidateWorkItemIDs).isDisjoint(
                  with: Set(excludedWorkItemIDs)
              ),
              (coverageState == .trusted && !isProvisional)
                  || candidates.compactMap({ $0.candidate }).isEmpty,
              coverageState == .trusted || exclusionsAreIncompleteCoverage
        else {
            throw DerivedIntelligenceRepositoryError.invalidPersistedData
        }
    }

    private nonisolated static func evidence(from row: Row) throws -> EvidenceReference {
        let nodeValue: String? = row["source_node_id"]
        let eventValue: String? = row["source_event_id"]
        let rawSnapshotValue: String? = row["raw_snapshot_id"]
        guard let id = EvidenceID(rawValue: row["evidence_id"]),
              let source = EvidenceSource(rawValue: row["source"]),
              let locator = EvidenceLocator(kind: row["source_locator_kind"], value: row["source_locator"]),
              let authority = evidenceAuthority(from: row),
              let confidence = RelationConfidence(rawValue: row["confidence"]),
              let confirmation = EvidenceConfirmation(rawValue: row["confirmation"]),
              let observedAt = date(milliseconds: row["observed_at_ms"]),
              nodeValue.flatMap(GitHubNodeID.init(rawValue:)) != nil || nodeValue == nil,
              eventValue.flatMap(GitHubEventID.init(rawValue:)) != nil || eventValue == nil,
              rawSnapshotValue.flatMap(RawAPISnapshotID.init(rawValue:)) != nil || rawSnapshotValue == nil
        else {
            throw DerivedIntelligenceRepositoryError.invalidPersistedData
        }
        return EvidenceReference(
            id: id,
            source: source,
            locator: locator,
            authority: authority,
            nodeID: nodeValue.flatMap(GitHubNodeID.init(rawValue:)),
            eventID: eventValue.flatMap(GitHubEventID.init(rawValue:)),
            sourceRevision: row["source_revision"],
            rawSnapshotID: rawSnapshotValue.flatMap(RawAPISnapshotID.init(rawValue:)),
            confidence: confidence,
            confirmation: confirmation,
            observedAt: observedAt,
            excerpt: row["excerpt"]
        )
    }

    private nonisolated static func evidenceAuthority(from row: Row) -> EvidenceAuthority? {
        guard let kind: String = row["authority_kind"] else { return nil }
        switch kind {
        case "github":
            guard let accountID = AccountID(rawValue: row["authority_account_id"]),
                  let organizationID = OrganizationID(rawValue: row["authority_organization_id"]),
                  let feature = CoverageFeature(rawValue: row["authority_feature"]),
                  let streamID = SyncStreamID(rawValue: row["authority_stream_id"]),
                  let credentialRevision = CredentialRevision(rawValue: row["authority_credential_revision"]),
                  let capabilityRevision = CapabilityRevision(rawValue: row["authority_capability_revision"])
            else {
                return nil
            }
            return .github(
                scope: SynchronizationScope(
                    accountID: accountID,
                    organizationID: organizationID,
                    credentialRevision: credentialRevision,
                    capabilityRevision: capabilityRevision
                ),
                feature: feature,
                streamID: streamID
            )
        case "localWorkflow":
            guard let accountID = AccountID(rawValue: row["authority_account_id"]),
                  let organizationID = OrganizationID(rawValue: row["authority_organization_id"]),
                  row["authority_feature"] as String? == nil,
                  row["authority_stream_id"] as String? == nil,
                  row["authority_credential_revision"] as String? == nil,
                  row["authority_capability_revision"] as String? == nil
            else {
                return nil
            }
            return .localWorkflow(accountID: accountID, organizationID: organizationID)
        case "legacyUnverified":
            guard row["authority_account_id"] as String? == nil,
                  row["authority_organization_id"] as String? == nil,
                  row["authority_feature"] as String? == nil,
                  row["authority_stream_id"] as String? == nil,
                  row["authority_credential_revision"] as String? == nil,
                  row["authority_capability_revision"] as String? == nil
            else {
                return nil
            }
            return .legacyUnverified
        default:
            return nil
        }
    }

    private nonisolated static func evidenceAuthorityColumns(
        _ authority: EvidenceAuthority
    ) -> (
        kind: String,
        accountID: String?,
        organizationID: String?,
        feature: String?,
        streamID: String?,
        credentialRevision: String?,
        capabilityRevision: String?
    ) {
        switch authority {
        case let .github(scope, feature, streamID):
            (
                "github", scope.accountID.rawValue, scope.organizationID.rawValue,
                feature.rawValue, streamID.rawValue, scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue
            )
        case let .localWorkflow(accountID, organizationID):
            ("localWorkflow", accountID.rawValue, organizationID.rawValue, nil, nil, nil, nil)
        case .legacyUnverified:
            ("legacyUnverified", nil, nil, nil, nil, nil, nil)
        }
    }

    private nonisolated static func validCoverageRequirement(_ requirement: CoverageRequirement) -> Bool {
        guard boundedIdentifier(requirement.streamID.rawValue),
              requirement.intervalStart?.timeIntervalSinceReferenceDate.isFinite ?? true,
              requirement.intervalEnd?.timeIntervalSinceReferenceDate.isFinite ?? true
        else {
            return false
        }
        switch (requirement.intervalStart, requirement.intervalEnd) {
        case let (start?, end?): return start <= end
        case (nil, nil): return true
        default: return false
        }
    }

    private nonisolated static func coverageState(rawValue: String) -> DerivedIntelligenceCoverageState? {
        switch rawValue {
        case "trusted": .trusted
        case "incomplete": .incomplete
        case "unknown": .unknown
        default: nil
        }
    }

    private nonisolated static func coverageStateValue(_ state: DerivedIntelligenceCoverageState) -> String {
        switch state {
        case .trusted: "trusted"
        case .incomplete: "incomplete"
        case .unknown: "unknown"
        }
    }

    private nonisolated static func exclusionReason(rawValue: String) -> DerivedAICandidateExclusionReason? {
        switch rawValue {
        case "incompleteCoverage": .incompleteCoverage
        case "policyUnavailable": .policyUnavailable
        case "unchangedFingerprint": .unchangedFingerprint
        case "cachedAnalysis": .cachedAnalysis
        default: nil
        }
    }

    private nonisolated static func exclusionReasonValue(_ reason: DerivedAICandidateExclusionReason) -> String {
        switch reason {
        case .incompleteCoverage: "incompleteCoverage"
        case .policyUnavailable: "policyUnavailable"
        case .unchangedFingerprint: "unchangedFingerprint"
        case .cachedAnalysis: "cachedAnalysis"
        }
    }

    private nonisolated static func boundedIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains(where: { $0.properties.isWhitespace })
    }

    private nonisolated static func boundedSourceRevision(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 500 && !value.unicodeScalars.contains(where: { $0.properties.isWhitespace })
    }

    private nonisolated static func boolean(_ value: Int?) -> Bool? {
        switch value {
        case 0: false
        case 1: true
        default: nil
        }
    }

    private nonisolated static func appendLengthPrefixed(_ value: Data, to material: inout Data) {
        var length = UInt64(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
        material.append(value)
    }

    private nonisolated static func date(milliseconds: Int64?) -> Date? {
        guard let milliseconds else { return nil }
        let value = TimeInterval(milliseconds) / 1_000
        guard value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private nonisolated static func reasonOrder(_ left: AttentionReason, _ right: AttentionReason) -> Bool {
        left.strength == right.strength ? left.id < right.id : left.strength > right.strength
    }

    private nonisolated static func documentBytes(_ document: SearchDocument) -> Int {
        [
            document.title,
            document.body,
            document.repository,
            document.labels,
            document.people,
            document.projectValues,
            document.actionText,
            document.localNote
        ].reduce(0) { $0 + $1.utf8.count }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
