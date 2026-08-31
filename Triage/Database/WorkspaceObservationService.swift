import Foundation
import GRDB

/// Immutable, database-derived data used to present one organization workspace.
///
/// The value deliberately contains no `Database`, `DatabasePool`, or GRDB row
/// types. It is safe to move across actors and is the only data the UI should
/// retain from a vault observation.
struct WorkspaceObservationSnapshot: Equatable, Sendable {
    let scope: SynchronizationScope
    let revision: WorkspaceObservationRevision
    let workItems: [WorkspaceWorkItemPresentation]
    let menuCounts: WorkspaceMenuCounts
    let freshness: FreshnessState
    let organizationVisibilityFreshness: FreshnessState
    let isRefreshing: Bool
    let selectedItemEvidence: WorkspaceSelectedItemEvidence?
}

/// The minimal observation backing an Inbox page chain. It intentionally
/// excludes the workspace's compact row projection, counts, and selected-item
/// evidence so a large local graph cannot delay an Inbox-first render.
struct InboxPageObservationSnapshot: Equatable, Sendable {
    let scope: SynchronizationScope
    let revision: WorkspaceObservationRevision
    let freshness: FreshnessState
}

/// A durable projection revision. All fields are fetched by one GRDB
/// observation closure, so a snapshot never combines values from two commits.
struct WorkspaceObservationRevision: Equatable, Sendable {
    let schedulerGeneration: UInt64?
    let durableStateUpdatedAt: Date?
    let newestWorkItemUpdateAt: Date?
    /// Changes whenever a current-revision coverage record changes, even if
    /// the resulting coarse freshness label stays the same.
    let coverageFingerprint: String
    /// Tracks every persisted relation that can change Inbox eligibility or
    /// rank without touching the owning work-item row. The database updates
    /// this scope-local generation in the same transaction as its source
    /// write, so page observation remains bounded even for large workspaces.
    let inboxPresentationFingerprint: String
    /// Keeps a presentation's optional derived timestamp revision-fenced with
    /// the work rows it summarizes.
    let derivedEvaluatedAt: Date?
    /// Prevents the full-graph presentation from publishing stale account
    /// organization visibility after a current-credential inventory receipt
    /// changes while its graph is loading.
    let organizationVisibilityValidatedAt: Date?
}

/// The compact read model for a workspace row. Detail rendering continues to
/// fetch richer content only for the selected item.
struct WorkspaceWorkItemPresentation: Equatable, Sendable, Identifiable {
    let id: WorkItemID
    let primaryNodeID: GitHubNodeID
    let title: String
    let state: WorkItemState
    let sourceKind: GitHubContentKind
    let sourceURL: URL?
    let repositoryName: String?
    let repositoryOwner: String?
    let isPinned: Bool
    let priority: WorkPriority
    let workflowStatus: LocalWorkStatus
    let score: Int
    /// These revision fields are intentionally not rendered by the compact
    /// list, but remain part of its Equatable observation value. Without
    /// them GRDB's `removeDuplicates()` can hide a local-note/follow-up,
    /// score-breakdown, or secondary membership/context edit from the full
    /// graph presentation loaded by the observer.
    let workflowLocalNote: String?
    let workflowFollowUpAt: Date?
    let scoreBreakdown: Data?
    let nestedReferenceFingerprint: String
    let openActionItemCount: Int
    let attentionReasonCount: Int
    let lastRelevantActivityAt: Date
}

struct WorkspaceMenuCounts: Equatable, Sendable {
    let inbox: Int
    let myWork: Int
    let reviews: Int
    let waiting: Int
    let snoozed: Int
    let allWork: Int

    func count(for section: AppSection) -> Int {
        switch section {
        case .inbox: inbox
        case .myWork: myWork
        case .reviews: reviews
        case .waiting: waiting
        case .snoozed: snoozed
        case .allWork: allWork
        }
    }
}

/// Exact provenance supporting relations attached to the currently selected
/// work item. Legacy evidence remains explicitly labelled as unverified by
/// the database migration and is never upgraded by this projection.
struct WorkspaceSelectedItemEvidence: Equatable, Sendable {
    let workItemID: WorkItemID
    let evidence: [EvidenceReference]
}

enum WorkspaceObservationError: Error, Equatable, Sendable {
    case invalidPersistedData
    case invalidScope
    case selectedItemScopeMismatch
}

/// A narrow vault-internal subscription surface. `AccountVault` owns the
/// actual `DatabasePool`; this bridge intentionally exposes only Sendable
/// snapshots to its clients.
struct WorkspaceDatabaseObservationBridge: Sendable {
    typealias Start = @Sendable (
        SynchronizationScope,
        WorkItemID?,
        @escaping @Sendable (Error) -> Void,
        @escaping @Sendable (WorkspaceObservationSnapshot) -> Void
    ) -> AnyDatabaseCancellable

    typealias InboxStart = @Sendable (
        SynchronizationScope,
        @escaping @Sendable (Error) -> Void,
        @escaping @Sendable (InboxPageObservationSnapshot) -> Void
    ) -> AnyDatabaseCancellable

    private let start: Start
    private let startInbox: InboxStart

    init(start: @escaping Start, startInbox: @escaping InboxStart) {
        self.start = start
        self.startInbox = startInbox
    }

    func subscribeInbox(
        scope: SynchronizationScope,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (InboxPageObservationSnapshot) -> Void
    ) -> AnyDatabaseCancellable {
        startInbox(scope, onError, onChange)
    }

    func subscribe(
        scope: SynchronizationScope,
        selectedWorkItemID: WorkItemID?,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (WorkspaceObservationSnapshot) -> Void
    ) -> AnyDatabaseCancellable {
        start(scope, selectedWorkItemID, onError, onChange)
    }
}

/// Value-only GRDB observations for the workspace shell. A single
/// `ValueObservation` computes every value in a snapshot so work rows,
/// coverage/freshness, counts, selected evidence, and revision metadata are
/// transactionally consistent.
struct WorkspaceDatabaseObservationService: Sendable {
    private let bridge: WorkspaceDatabaseObservationBridge

    init(bridge: WorkspaceDatabaseObservationBridge) {
        self.bridge = bridge
    }

    /// The stream keeps at most the most recent projection. A slow UI is never
    /// allowed to retain stale intermediate projections or a database handle.
    func values(
        for scope: SynchronizationScope,
        selectedWorkItemID: WorkItemID?
    ) -> AsyncThrowingStream<WorkspaceObservationSnapshot, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancellable = bridge.subscribe(
                scope: scope,
                selectedWorkItemID: selectedWorkItemID,
                onError: { error in continuation.finish(throwing: error) },
                onChange: { snapshot in
                    if case .terminated = continuation.yield(snapshot) {
                        // `onTermination` also cancels, but this immediate path
                        // releases the GRDB observer when a consumer goes away
                        // between scheduling and delivery.
                        continuation.finish()
                    }
                }
            )
            continuation.onTermination = { @Sendable _ in cancellable.cancel() }
        }
    }

    /// A lightweight database subscription for page-first Inbox presentation.
    /// It keeps only the newest revision just like the complete observer.
    func inboxPageValues(
        for scope: SynchronizationScope
    ) -> AsyncThrowingStream<InboxPageObservationSnapshot, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancellable = bridge.subscribeInbox(
                scope: scope,
                onError: { error in continuation.finish(throwing: error) },
                onChange: { snapshot in
                    if case .terminated = continuation.yield(snapshot) {
                        continuation.finish()
                    }
                }
            )
            continuation.onTermination = { @Sendable _ in cancellable.cancel() }
        }
    }

    /// Construct this only inside the persistence layer (normally from the
    /// account vault). The returned bridge leaks no reader or connection to
    /// consumers.
    static func bridge(
        in reader: some DatabaseReader,
        accountID: AccountID
    ) -> WorkspaceDatabaseObservationBridge {
        WorkspaceDatabaseObservationBridge(start: { scope, selectedWorkItemID, onError, onChange in
            guard scope.accountID == accountID else {
                onError(WorkspaceObservationError.invalidScope)
                return AnyDatabaseCancellable(cancel: {})
            }
            let cancellable: AnyDatabaseCancellable = ValueObservation
                .tracking { database in
                    try snapshot(
                        in: database,
                        scope: scope,
                        selectedWorkItemID: selectedWorkItemID
                    )
                }
                .removeDuplicates()
                .start(
                    in: reader,
                    scheduling: .task,
                    onError: onError,
                    onChange: onChange
                )
            return cancellable
        }, startInbox: { scope, onError, onChange in
            guard scope.accountID == accountID else {
                onError(WorkspaceObservationError.invalidScope)
                return AnyDatabaseCancellable(cancel: {})
            }
            return ValueObservation
                .tracking { database in
                    try inboxPageSnapshot(in: database, scope: scope)
                }
                .removeDuplicates()
                .start(
                    in: reader,
                    scheduling: .task,
                    onError: onError,
                    onChange: onChange
                )
        })
    }

    nonisolated static func snapshot(
        in database: Database,
        scope: SynchronizationScope,
        selectedWorkItemID: WorkItemID?
    ) throws -> WorkspaceObservationSnapshot {
        let coverage = try CoverageRepository.currentRecords(for: scope, in: database)
        let durable = try durableState(in: database, scope: scope)
        let scheduler = try schedulerState(in: database, scope: scope)
        let rows = try workItemPresentations(in: database, scope: scope)
        let counts = try menuCounts(in: database, scope: scope)
        let evidence = try selectedEvidence(
            in: database,
            scope: scope,
            selectedWorkItemID: selectedWorkItemID
        )
        let newestWorkItemUpdateAt = try Int64.fetchOne(
            database,
            sql: """
                SELECT MAX(updated_at_ms)
                FROM work_items
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        ).map(date(milliseconds:))
        let derivedEvaluatedAt = try Int64.fetchOne(
            database,
            sql: """
                SELECT evaluated_at_ms
                FROM derived_intelligence_runs
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                """,
            arguments: [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue
            ]
        ).map(date(milliseconds:))

        let freshness = freshness(
            durable: durable,
            persistedCoverage: coverage,
            scheduler: scheduler
        )
        let refreshing = scheduler?.activeAttemptID != nil
        let organizationVisibilityValidatedAt = try organizationVisibilityValidatedAt(
            in: database,
            scope: scope
        )
        return WorkspaceObservationSnapshot(
            scope: scope,
            revision: WorkspaceObservationRevision(
                schedulerGeneration: scheduler?.generation,
                durableStateUpdatedAt: durable?.updatedAt,
                newestWorkItemUpdateAt: newestWorkItemUpdateAt,
                coverageFingerprint: coverage.map(coverageSignature).joined(separator: "\n"),
                inboxPresentationFingerprint: try inboxPresentationFingerprint(
                    in: database,
                    scope: scope
                ),
                derivedEvaluatedAt: derivedEvaluatedAt,
                organizationVisibilityValidatedAt: organizationVisibilityValidatedAt
            ),
            workItems: rows,
            menuCounts: counts,
            freshness: refreshing
                ? FreshnessState(
                    status: .refreshing,
                    lastSuccessfulSyncAt: freshness.lastSuccessfulSyncAt,
                    nextRetryAt: freshness.nextRetryAt,
                    detail: freshness.detail
                )
                : freshness,
            organizationVisibilityFreshness: organizationVisibilityFreshness(
                validatedAt: organizationVisibilityValidatedAt
            ),
            isRefreshing: refreshing,
            selectedItemEvidence: evidence
        )
    }

    nonisolated static func inboxPageSnapshot(
        in database: Database,
        scope: SynchronizationScope
    ) throws -> InboxPageObservationSnapshot {
        let coverage = try CoverageRepository.currentRecords(for: scope, in: database)
        let durable = try durableState(in: database, scope: scope)
        let scheduler = try schedulerState(in: database, scope: scope)
        let freshness = freshness(
            durable: durable,
            persistedCoverage: coverage,
            scheduler: scheduler
        )
        let revision = try revision(in: database, scope: scope)
        return InboxPageObservationSnapshot(
            scope: scope,
            revision: revision,
            freshness: scheduler?.activeAttemptID == nil
                ? freshness
                : FreshnessState(
                    status: .refreshing,
                    lastSuccessfulSyncAt: freshness.lastSuccessfulSyncAt,
                    nextRetryAt: freshness.nextRetryAt,
                    detail: freshness.detail
                )
        )
    }

    /// A bounded fence for the asynchronous full-graph decode. This avoids
    /// rerunning the complete observation projection (rows, menu aggregation,
    /// and selected evidence) after every emission merely to reject a commit
    /// that landed while the graph was loading.
    nonisolated static func revision(
        in database: Database,
        scope: SynchronizationScope
    ) throws -> WorkspaceObservationRevision {
        let coverage = try CoverageRepository.currentRecords(for: scope, in: database)
        let durable = try durableState(in: database, scope: scope)
        let scheduler = try schedulerState(in: database, scope: scope)
        let newestWorkItemUpdateAt = try Int64.fetchOne(
            database,
            sql: """
                SELECT MAX(updated_at_ms)
                FROM work_items
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        ).map(date(milliseconds:))
        let derivedEvaluatedAt = try Int64.fetchOne(
            database,
            sql: """
                SELECT evaluated_at_ms
                FROM derived_intelligence_runs
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                """,
            arguments: [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue
            ]
        ).map(date(milliseconds:))
        let organizationVisibilityValidatedAt = try organizationVisibilityValidatedAt(
            in: database,
            scope: scope
        )
        return WorkspaceObservationRevision(
            schedulerGeneration: scheduler?.generation,
            durableStateUpdatedAt: durable?.updatedAt,
            newestWorkItemUpdateAt: newestWorkItemUpdateAt,
            coverageFingerprint: coverage.map(coverageSignature).joined(separator: "\n"),
            inboxPresentationFingerprint: try inboxPresentationFingerprint(
                in: database,
                scope: scope
            ),
            derivedEvaluatedAt: derivedEvaluatedAt,
            organizationVisibilityValidatedAt: organizationVisibilityValidatedAt
        )
    }
}

private extension WorkspaceDatabaseObservationService {
    /// A scope-local generation maintained by database triggers for every
    /// Inbox eligibility/ranking dependency that is owned outside
    /// `work_items`. Reading its primary-key row is constant-time and, unlike
    /// an in-memory counter, observes writes committed by another process.
    ///
    /// A missing row is the valid initial state for a scope whose dependencies
    /// have not changed since the migration installed the triggers.
    static func inboxPresentationFingerprint(
        in database: Database,
        scope: SynchronizationScope
    ) throws -> String {
        let generation = try Int64.fetchOne(
            database,
            sql: """
                SELECT generation
                FROM workspace_inbox_revisions
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        guard let generation else {
            return "0"
        }
        guard generation >= 0 else {
            throw WorkspaceObservationError.invalidPersistedData
        }
        return String(generation)
    }

    struct DurableProjection: Sendable {
        let state: AccountOrganizationDurableState
        let schedulerGeneration: UInt64
        let updatedAt: Date
    }

    struct SchedulerProjection: Sendable {
        let generation: UInt64
        let activeAttemptID: UUID?
    }

    struct DurableEnvelope: Decodable, Sendable {
        let formatVersion: Int
        let scope: SynchronizationScope
        let durableState: AccountOrganizationDurableState
    }

    static func durableState(
        in database: Database,
        scope: SynchronizationScope
    ) throws -> DurableProjection? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT scheduler_generation, state_payload, updated_at_ms
                FROM account_organization_durable_states
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                """,
            arguments: [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue
            ]
        ) else {
            return nil
        }
        guard let generation: Int64 = row["scheduler_generation"],
              generation >= 0,
              let payload: Data = row["state_payload"],
              let updatedAtMilliseconds: Int64 = row["updated_at_ms"]
        else {
            throw WorkspaceObservationError.invalidPersistedData
        }
        let envelope: DurableEnvelope
        do {
            envelope = try JSONDecoder().decode(DurableEnvelope.self, from: payload)
        } catch {
            throw WorkspaceObservationError.invalidPersistedData
        }
        guard envelope.formatVersion == AccountOrganizationDurableStateRepository.formatVersion,
              envelope.scope == scope
        else {
            throw WorkspaceObservationError.invalidPersistedData
        }
        return DurableProjection(
            state: envelope.durableState,
            schedulerGeneration: UInt64(generation),
            updatedAt: date(milliseconds: updatedAtMilliseconds)
        )
    }

    static func schedulerState(
        in database: Database,
        scope: SynchronizationScope
    ) throws -> SchedulerProjection? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT generation, active_attempt_id
                FROM organization_scheduler_states
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                """,
            arguments: [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue
            ]
        ) else {
            return nil
        }
        guard let generation: Int64 = row["generation"], generation >= 0 else {
            throw WorkspaceObservationError.invalidPersistedData
        }
        let attemptID = (row["active_attempt_id"] as String?).flatMap(UUID.init(uuidString:))
        if row["active_attempt_id"] != nil, attemptID == nil {
            throw WorkspaceObservationError.invalidPersistedData
        }
        return SchedulerProjection(generation: UInt64(generation), activeAttemptID: attemptID)
    }

    /// `/user/orgs` inventory is account-scoped source authority. A receipt
    /// for another credential revision must never authorize notifications for
    /// the currently selected organization.
    static func organizationVisibilityValidatedAt(
        in database: Database,
        scope: SynchronizationScope
    ) throws -> Date? {
        try Int64.fetchOne(
            database,
            sql: """
                SELECT validated_at_ms
                FROM account_organization_inventory_replay_receipts
                WHERE account_id = ? AND credential_revision = ?
                  AND request_key = 'GET /user/orgs?per_page=100'
            """,
            arguments: [scope.accountID.rawValue, scope.credentialRevision.rawValue]
        ).map(date(milliseconds:))
    }

    static func organizationVisibilityFreshness(validatedAt: Date?) -> FreshnessState {
        guard let validatedAt else {
            return FreshnessState(
                status: .partial,
                detail: "Organization visibility has not been validated for the current account access."
            )
        }
        return FreshnessState(status: .fresh, lastSuccessfulSyncAt: validatedAt)
    }

    static func freshness(
        durable: DurableProjection?,
        persistedCoverage: [CoverageRecord],
        scheduler: SchedulerProjection?
    ) -> FreshnessState {
        guard let durable,
              durable.schedulerGeneration == scheduler?.generation,
              sameCoverage(durable.state.cachedState?.coverage ?? [], persistedCoverage)
        else {
            return AccountOrganizationCachedState(
                coverage: persistedCoverage,
                coverageRequirements: nil,
                lastSuccessfulSyncAt: persistedCoverage.compactMap(\.lastSuccessfulAt).max()
            ).freshness
        }
        return durable.state.freshness
    }

    static func sameCoverage(
        _ left: [CoverageRecord],
        _ right: [CoverageRecord]
    ) -> Bool {
        left.count == right.count
            && left.map(coverageSignature).sorted() == right.map(coverageSignature).sorted()
    }

    static func coverageSignature(_ record: CoverageRecord) -> String {
        let parts: [String] = [
            record.accountID.rawValue,
            record.organizationID.rawValue,
            record.repositoryID?.rawValue ?? "",
            record.feature.rawValue,
            record.streamID.rawValue,
            record.intervalStart.map(milliseconds).map(String.init) ?? "",
            record.intervalEnd.map(milliseconds).map(String.init) ?? "",
            record.credentialRevision.rawValue,
            record.capabilityRevision.rawValue,
            record.status.rawValue,
            record.lastSuccessfulAt.map(milliseconds).map(String.init) ?? "",
            record.failureDetail ?? ""
        ]
        let framed: [String] = parts.map { part in
            String(part.utf8.count) + ":" + part
        }
        return framed.joined(separator: "|")
    }

    static func workItemPresentations(
        in database: Database,
        scope: SynchronizationScope
    ) throws -> [WorkspaceWorkItemPresentation] {
        try Row.fetchAll(
            database,
            sql: """
                WITH current_rule_evaluations AS (
                    SELECT rule_evaluations.id, rule_evaluations.work_item_id
                    FROM rule_evaluations
                    JOIN derived_intelligence_runs
                      ON derived_intelligence_runs.account_id = rule_evaluations.account_id
                     AND derived_intelligence_runs.organization_id = rule_evaluations.organization_id
                     AND derived_intelligence_runs.credential_revision = rule_evaluations.credential_revision
                     AND derived_intelligence_runs.capability_revision = rule_evaluations.capability_revision
                     AND derived_intelligence_runs.source_revision = rule_evaluations.source_revision
                    WHERE rule_evaluations.account_id = ?
                      AND rule_evaluations.organization_id = ?
                      AND rule_evaluations.credential_revision = ?
                      AND rule_evaluations.capability_revision = ?
                      AND EXISTS (
                          SELECT 1
                          FROM rule_evaluation_evidence
                          WHERE rule_evaluation_evidence.rule_evaluation_id = rule_evaluations.id
                            AND (
                                (
                                    rule_evaluation_evidence.authority_kind = 'github'
                                    AND rule_evaluation_evidence.authority_account_id = rule_evaluations.account_id
                                    AND rule_evaluation_evidence.authority_organization_id = rule_evaluations.organization_id
                                    AND rule_evaluation_evidence.authority_credential_revision = rule_evaluations.credential_revision
                                    AND rule_evaluation_evidence.authority_capability_revision = rule_evaluations.capability_revision
                                ) OR (
                                    rule_evaluation_evidence.authority_kind = 'localWorkflow'
                                    AND rule_evaluation_evidence.authority_account_id = rule_evaluations.account_id
                                    AND rule_evaluation_evidence.authority_organization_id = rule_evaluations.organization_id
                                )
                            )
                      )
                )
                SELECT
                    work_items.id, work_items.primary_node_id, work_items.state,
                    work_items.last_relevant_activity_at_ms,
                    github_nodes.kind, github_nodes.title, github_nodes.html_url,
                    repositories.owner_login AS repository_owner_login,
                    repositories.name AS repository_name,
                    workflow_states.status AS workflow_status,
                    workflow_states.pinned AS workflow_pinned,
                    workflow_states.priority AS workflow_priority,
                    workflow_states.local_note AS workflow_local_note,
                    workflow_states.follow_up_at_ms AS workflow_follow_up_at_ms,
                    attention_scores.score AS attention_score,
                    attention_scores.breakdown_json AS attention_score_breakdown_json,
                    COALESCE((
                        SELECT group_concat(github_node_id || ':' || role, char(30))
                        FROM work_item_members
                        WHERE work_item_id = work_items.id
                    ), '') || char(29) || COALESCE((
                        SELECT group_concat(github_node_id || ':' || relation, char(30))
                        FROM work_item_context_links
                        WHERE work_item_id = work_items.id
                    ), '') AS nested_reference_fingerprint,
                    (
                        SELECT COUNT(*)
                        FROM action_items
                        WHERE action_items.work_item_id = work_items.id
                          AND action_items.state = 'open'
                    ) AS open_action_item_count,
                    (
                        SELECT COUNT(*)
                        FROM current_rule_evaluations
                        WHERE current_rule_evaluations.work_item_id = work_items.id
                    ) AS attention_reason_count
                FROM work_items
                JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                LEFT JOIN repositories ON repositories.id = github_nodes.repository_id
                LEFT JOIN workflow_states ON workflow_states.work_item_id = work_items.id
                LEFT JOIN attention_scores ON attention_scores.work_item_id = work_items.id
                WHERE work_items.account_id = ? AND work_items.organization_id = ?
                ORDER BY work_items.last_relevant_activity_at_ms DESC, work_items.id
                """,
            arguments: [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue,
                scope.accountID.rawValue,
                scope.organizationID.rawValue
            ]
        ).map { row in
            guard let id = WorkItemID(rawValue: row["id"]),
                  let primaryNodeID = GitHubNodeID(rawValue: row["primary_node_id"]),
                  let state = WorkItemState(rawValue: row["state"]),
                  let sourceKind = GitHubContentKind(rawValue: row["kind"]),
                  let rawURL: String = row["html_url"],
                  let sourceURL = URL(string: rawURL),
                  let activity: Int64 = row["last_relevant_activity_at_ms"]
            else {
                throw WorkspaceObservationError.invalidPersistedData
            }
            guard let workflowStatus = LocalWorkStatus(rawValue: (row["workflow_status"] as String?) ?? "active"),
                  let priority = WorkPriority(rawValue: (row["workflow_priority"] as Int?) ?? WorkPriority.normal.rawValue)
            else {
                throw WorkspaceObservationError.invalidPersistedData
            }
            return WorkspaceWorkItemPresentation(
                id: id,
                primaryNodeID: primaryNodeID,
                title: row["title"],
                state: state,
                sourceKind: sourceKind,
                sourceURL: sourceURL,
                repositoryName: row["repository_name"],
                repositoryOwner: row["repository_owner_login"],
                isPinned: (row["workflow_pinned"] as Bool?) ?? false,
                priority: priority,
                workflowStatus: workflowStatus,
                score: (row["attention_score"] as Int?) ?? 0,
                workflowLocalNote: row["workflow_local_note"],
                workflowFollowUpAt: (row["workflow_follow_up_at_ms"] as Int64?).map(date(milliseconds:)),
                scoreBreakdown: row["attention_score_breakdown_json"],
                nestedReferenceFingerprint: row["nested_reference_fingerprint"],
                openActionItemCount: row["open_action_item_count"],
                attentionReasonCount: row["attention_reason_count"],
                lastRelevantActivityAt: date(milliseconds: activity)
            )
        }
    }

    static func menuCounts(
        in database: Database,
        scope: SynchronizationScope
    ) throws -> WorkspaceMenuCounts {
        let now = Int64((Date.now.timeIntervalSince1970 * 1_000).rounded())
        guard let row = try Row.fetchOne(
            database,
            sql: """
                WITH current_rule_evaluations AS (
                    SELECT rule_evaluations.id, rule_evaluations.work_item_id, rule_evaluations.rule_id
                    FROM rule_evaluations
                    JOIN derived_intelligence_runs
                      ON derived_intelligence_runs.account_id = rule_evaluations.account_id
                     AND derived_intelligence_runs.organization_id = rule_evaluations.organization_id
                     AND derived_intelligence_runs.credential_revision = rule_evaluations.credential_revision
                     AND derived_intelligence_runs.capability_revision = rule_evaluations.capability_revision
                     AND derived_intelligence_runs.source_revision = rule_evaluations.source_revision
                    WHERE rule_evaluations.account_id = ?
                      AND rule_evaluations.organization_id = ?
                      AND rule_evaluations.credential_revision = ?
                      AND rule_evaluations.capability_revision = ?
                      AND EXISTS (
                          SELECT 1
                          FROM rule_evaluation_evidence
                          WHERE rule_evaluation_evidence.rule_evaluation_id = rule_evaluations.id
                            AND (
                                (
                                    rule_evaluation_evidence.authority_kind = 'github'
                                    AND rule_evaluation_evidence.authority_account_id = rule_evaluations.account_id
                                    AND rule_evaluation_evidence.authority_organization_id = rule_evaluations.organization_id
                                    AND rule_evaluation_evidence.authority_credential_revision = rule_evaluations.credential_revision
                                    AND rule_evaluation_evidence.authority_capability_revision = rule_evaluations.capability_revision
                                ) OR (
                                    rule_evaluation_evidence.authority_kind = 'localWorkflow'
                                    AND rule_evaluation_evidence.authority_account_id = rule_evaluations.account_id
                                    AND rule_evaluation_evidence.authority_organization_id = rule_evaluations.organization_id
                                )
                            )
                      )
                ), workspace AS (
                    SELECT
                        work_items.id,
                        work_items.state,
                        COALESCE(workflow_states.status, 'active') AS workflow_status,
                        COALESCE(workflow_states.pinned, 0) AS workflow_pinned,
                        workflow_states.snoozed_until_ms,
                        EXISTS(
                            SELECT 1 FROM current_rule_evaluations
                            WHERE current_rule_evaluations.work_item_id = work_items.id
                        ) AS has_attention_reason,
                        EXISTS(
                            SELECT 1 FROM current_rule_evaluations
                            WHERE current_rule_evaluations.work_item_id = work_items.id
                              AND current_rule_evaluations.rule_id IN ('awaitedActorResponded', 'followUpDue')
                        ) AS has_waiting_wakeup,
                        EXISTS(
                            SELECT 1 FROM action_items
                            WHERE action_items.work_item_id = work_items.id
                              AND action_items.state = 'open'
                        ) AS has_open_action,
                        EXISTS(
                            SELECT 1
                            FROM relations
                            JOIN work_item_members
                              ON work_item_members.github_node_id = relations.subject_node_id
                            WHERE work_item_members.work_item_id = work_items.id
                              AND relations.account_id = work_items.account_id
                              AND relations.kind IN ('assigned', 'authored')
                        ) AS has_my_work_relation,
                        EXISTS(
                            SELECT 1
                            FROM relations
                            JOIN work_item_members
                              ON work_item_members.github_node_id = relations.subject_node_id
                            WHERE work_item_members.work_item_id = work_items.id
                              AND relations.account_id = work_items.account_id
                              AND relations.kind IN ('reviewRequestedDirectly', 'reviewRequestedFromTeam')
                        ) AS has_review_relation
                    FROM work_items
                    LEFT JOIN workflow_states
                      ON workflow_states.work_item_id = work_items.id
                    WHERE work_items.account_id = ? AND work_items.organization_id = ?
                ), dispositions AS (
                    SELECT *, CASE
                        WHEN state = 'inaccessible' THEN 'inaccessible'
                        WHEN snoozed_until_ms > ? THEN 'snoozed'
                        WHEN workflow_status = 'archived' THEN 'archived'
                        WHEN workflow_status = 'waiting' AND has_waiting_wakeup = 0 THEN 'waiting'
                        WHEN workflow_status = 'waiting' THEN 'inbox'
                        WHEN state = 'resolved' AND has_open_action = 0 THEN 'resolved'
                        WHEN workflow_pinned = 1 OR has_attention_reason = 1 OR has_open_action = 1 THEN 'inbox'
                        ELSE 'informational'
                    END AS disposition
                    FROM workspace
                )
                SELECT
                    COALESCE(SUM(disposition = 'inbox'), 0) AS inbox,
                    COALESCE(SUM(has_my_work_relation), 0) AS my_work,
                    COALESCE(SUM(has_review_relation), 0) AS reviews,
                    COALESCE(SUM(disposition = 'waiting'), 0) AS waiting,
                    COALESCE(SUM(disposition = 'snoozed'), 0) AS snoozed,
                    COUNT(*) AS all_work
                FROM dispositions
                """,
            arguments: [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue,
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                now
            ]
        ), let inbox: Int = row["inbox"],
           let myWork: Int = row["my_work"],
           let reviews: Int = row["reviews"],
           let waiting: Int = row["waiting"],
           let snoozed: Int = row["snoozed"],
           let allWork: Int = row["all_work"]
        else {
            throw WorkspaceObservationError.invalidPersistedData
        }
        return WorkspaceMenuCounts(
            inbox: inbox,
            myWork: myWork,
            reviews: reviews,
            waiting: waiting,
            snoozed: snoozed,
            allWork: allWork
        )
    }

    static func selectedEvidence(
        in database: Database,
        scope: SynchronizationScope,
        selectedWorkItemID: WorkItemID?
    ) throws -> WorkspaceSelectedItemEvidence? {
        guard let selectedWorkItemID else { return nil }
        let workItemExists = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM work_items
                    WHERE id = ? AND account_id = ? AND organization_id = ?
                )
                """,
            arguments: [
                selectedWorkItemID.rawValue,
                scope.accountID.rawValue,
                scope.organizationID.rawValue
            ]
        ) ?? false
        guard workItemExists else {
            return nil
        }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT DISTINCT
                    relation_evidence.evidence_id,
                    relation_evidence.source,
                    relation_evidence.source_locator_kind,
                    relation_evidence.source_locator,
                    relation_evidence.authority_kind,
                    relation_evidence.authority_account_id,
                    relation_evidence.authority_organization_id,
                    relation_evidence.authority_feature,
                    relation_evidence.authority_stream_id,
                    relation_evidence.authority_credential_revision,
                    relation_evidence.authority_capability_revision,
                    relation_evidence.source_node_id,
                    relation_evidence.source_event_id,
                    relation_evidence.source_revision,
                    relation_evidence.raw_snapshot_id,
                    relation_evidence.confidence,
                    relation_evidence.confirmation,
                    relation_evidence.observed_at_ms,
                    relation_evidence.excerpt
                FROM work_item_members
                JOIN relations
                  ON relations.subject_node_id = work_item_members.github_node_id
                 AND relations.account_id = ?
                JOIN relation_evidence ON relation_evidence.relation_id = relations.id
                WHERE work_item_members.work_item_id = ?
                  AND (
                    (
                        relation_evidence.authority_kind = 'legacyUnverified'
                        AND relation_evidence.authority_account_id = ?
                        AND relation_evidence.authority_organization_id = ?
                    ) OR (
                        relation_evidence.authority_account_id = ?
                        AND relation_evidence.authority_organization_id = ?
                        AND (
                            relation_evidence.authority_kind = 'localWorkflow'
                            OR (
                                relation_evidence.authority_kind = 'github'
                                AND relation_evidence.authority_credential_revision = ?
                                AND relation_evidence.authority_capability_revision = ?
                            )
                        )
                    )
                  )
                ORDER BY relation_evidence.observed_at_ms DESC, relation_evidence.evidence_id
                """,
            arguments: [
                scope.accountID.rawValue,
                selectedWorkItemID.rawValue,
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue
            ]
        )
        var evidenceByID: [EvidenceID: EvidenceReference] = [:]
        for row in rows {
            let evidence = try evidence(from: row, expectedScope: scope)
            if let existing = evidenceByID[evidence.id], existing != evidence {
                throw WorkspaceObservationError.invalidPersistedData
            }
            evidenceByID[evidence.id] = evidence
        }
        return WorkspaceSelectedItemEvidence(
            workItemID: selectedWorkItemID,
            evidence: evidenceByID.values.sorted { left, right in
                left.observedAt == right.observedAt
                    ? left.id.rawValue < right.id.rawValue
                    : left.observedAt > right.observedAt
            }
        )
    }

    static func evidence(
        from row: Row,
        expectedScope: SynchronizationScope
    ) throws -> EvidenceReference {
        guard let id = EvidenceID(rawValue: row["evidence_id"]),
              let source = EvidenceSource(rawValue: row["source"]),
              let locatorKind: String = row["source_locator_kind"],
              let locatorValue: String = row["source_locator"],
              let locator = EvidenceLocator(kind: locatorKind, value: locatorValue),
              let authorityKind: String = row["authority_kind"],
              let confidence = RelationConfidence(rawValue: row["confidence"]),
              let confirmation = EvidenceConfirmation(rawValue: row["confirmation"]),
              let observedAtMilliseconds: Int64 = row["observed_at_ms"]
        else {
            throw WorkspaceObservationError.invalidPersistedData
        }
        let authority: EvidenceAuthority
        switch authorityKind {
        case "github":
            guard let accountID = AccountID(rawValue: row["authority_account_id"]),
                  let organizationID = OrganizationID(rawValue: row["authority_organization_id"]),
                  let feature = CoverageFeature(rawValue: row["authority_feature"]),
                  let streamID = SyncStreamID(rawValue: row["authority_stream_id"]),
                  let credentialRevision = CredentialRevision(rawValue: row["authority_credential_revision"]),
                  let capabilityRevision = CapabilityRevision(rawValue: row["authority_capability_revision"])
            else {
                throw WorkspaceObservationError.invalidPersistedData
            }
            let scope = SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision
            )
            guard scope == expectedScope else {
                throw WorkspaceObservationError.invalidScope
            }
            authority = .github(scope: scope, feature: feature, streamID: streamID)
        case "localWorkflow":
            guard let accountID = AccountID(rawValue: row["authority_account_id"]),
                  let organizationID = OrganizationID(rawValue: row["authority_organization_id"]),
                  accountID == expectedScope.accountID,
                  organizationID == expectedScope.organizationID
            else {
                throw WorkspaceObservationError.invalidPersistedData
            }
            authority = .localWorkflow(accountID: accountID, organizationID: organizationID)
        case "legacyUnverified":
            authority = .legacyUnverified
        default:
            throw WorkspaceObservationError.invalidPersistedData
        }
        return EvidenceReference(
            id: id,
            source: source,
            locator: locator,
            authority: authority,
            nodeID: (row["source_node_id"] as String?).flatMap(GitHubNodeID.init(rawValue:)),
            eventID: (row["source_event_id"] as String?).flatMap(GitHubEventID.init(rawValue:)),
            sourceRevision: row["source_revision"],
            rawSnapshotID: (row["raw_snapshot_id"] as String?).flatMap(RawAPISnapshotID.init(rawValue:)),
            confidence: confidence,
            confirmation: confirmation,
            observedAt: date(milliseconds: observedAtMilliseconds),
            excerpt: row["excerpt"]
        )
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
