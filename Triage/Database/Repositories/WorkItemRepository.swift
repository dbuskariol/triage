import Foundation
import GRDB

enum WorkItemRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case inboxPageCursorScopeMismatch
    case invalidPersistedData
}

/// The immutable ordering key for a persisted Inbox page. It is scoped to the
/// same credential/capability authority as the read so a cursor can never be
/// replayed into a different organization view.
struct InboxPageCursor: Codable, Equatable, Sendable {
    let scope: SynchronizationScope
    let isPinned: Bool
    let priority: WorkPriority
    let score: Int
    let earliestOpenActionDueAt: Date?
    let lastRelevantActivityAt: Date
    let workItemID: WorkItemID
}

struct InboxPage: Sendable {
    let items: [WorkItem]
    let nextCursor: InboxPageCursor?
    let hasMore: Bool
}

actor WorkItemRepository {
    private let vault: AccountVault
    private let queryObserver: (@Sendable () -> Void)?

    /// `queryObserver` is an internal test seam for guarding the bounded
    /// graph-load query budget. Production callers use the default `nil`.
    init(vault: AccountVault, queryObserver: (@Sendable () -> Void)? = nil) {
        self.vault = vault
        self.queryObserver = queryObserver
    }

    func fetch(
        accountID: AccountID,
        organizationID: OrganizationID,
        authorityScope: SynchronizationScope? = nil
    ) async throws -> [WorkItem] {
        try ensureAccountScope(accountID)
        if let authorityScope,
           authorityScope.accountID != accountID || authorityScope.organizationID != organizationID {
            throw WorkItemRepositoryError.accountScopeMismatch
        }
        try Task.checkCancellation()
        let queryObserver = self.queryObserver
        let items: [WorkItem] = try await vault.read { database -> [WorkItem] in
            try Task.checkCancellation()
            let currentDerivedSourceRevision = try authorityScope.map {
                try Self.currentDerivedSourceRevision(for: $0, in: database)
            }
            queryObserver?()
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        work_items.id, work_items.primary_node_id, work_items.state,
                        work_items.last_relevant_activity_at_ms,
                        github_nodes.kind, github_nodes.title, github_nodes.html_url,
                        github_nodes.repository_id,
                        repositories.github_node_id AS repository_node_id,
                        repositories.owner_login AS repository_owner_login,
                        repositories.name AS repository_name,
                        repositories.is_private AS repository_is_private,
                        repositories.is_archived AS repository_is_archived,
                        repositories.has_discussions AS repository_has_discussions,
                        repositories.has_discussions_known AS repository_has_discussions_known,
                        repositories.html_url AS repository_html_url,
                        workflow_states.status AS workflow_status,
                        workflow_states.pinned AS workflow_pinned,
                        workflow_states.priority AS workflow_priority,
                        workflow_states.snoozed_until_ms,
                        workflow_states.follow_up_at_ms,
                        workflow_states.local_note,
                        workflow_states.updated_at_ms AS workflow_updated_at_ms,
                        attention_scores.score,
                        attention_scores.breakdown_json AS score_breakdown_json
                    FROM work_items
                    JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                        AND github_nodes.account_id = work_items.account_id
                        AND github_nodes.organization_id = work_items.organization_id
                    LEFT JOIN repositories ON repositories.id = github_nodes.repository_id
                    LEFT JOIN workflow_states ON workflow_states.work_item_id = work_items.id
                    LEFT JOIN attention_scores ON attention_scores.work_item_id = work_items.id
                    LEFT JOIN work_item_group_memberships
                      ON work_item_group_memberships.constituent_work_item_id = work_items.id
                     AND work_item_group_memberships.account_id = work_items.account_id
                     AND work_item_group_memberships.organization_id = work_items.organization_id
                    WHERE work_items.account_id = ? AND work_items.organization_id = ?
                      AND (
                          work_item_group_memberships.constituent_work_item_id IS NULL
                          OR work_item_group_memberships.canonical_work_item_id = work_items.id
                      )
                    ORDER BY work_items.last_relevant_activity_at_ms DESC, work_items.id
                """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
            return try Self.loadGraph(
                from: rows,
                accountID: accountID,
                organizationID: organizationID,
                authorityScope: authorityScope,
                currentDerivedSourceRevision: currentDerivedSourceRevision,
                freshness: FreshnessState(status: .fresh),
                onQuery: queryObserver,
                in: database
            )
        }
        try Task.checkCancellation()
        return items
    }

    /// Loads one persisted-rank Inbox page. Eligibility is evaluated in SQL
    /// from exactly the same durable workflow, rule, and action state used by
    /// `InboxEligibilityRule`; the selected rows are then decoded through the
    /// normal authoritative graph loader. A caller supplies the scoped
    /// freshness state that accompanies this cached presentation so this read
    /// cannot silently turn partial or stale coverage into a fresh Inbox.
    func fetchInboxPage(
        scope: SynchronizationScope,
        at date: Date,
        freshness: FreshnessState,
        limit: Int
    ) async throws -> [WorkItem] {
        try await fetchInboxPage(
            scope: scope,
            at: date,
            freshness: freshness,
            limit: limit,
            after: nil
        ).items
    }

    /// Loads one stable keyset page of Inbox work. `nextCursor` is present
    /// exactly when `hasMore` is true; callers must carry it into `after` for
    /// the next page rather than deriving an offset from mutable cached data.
    func fetchInboxPage(
        scope: SynchronizationScope,
        at date: Date,
        freshness: FreshnessState,
        limit: Int,
        after cursor: InboxPageCursor?
    ) async throws -> InboxPage {
        try ensureAccountScope(scope.accountID)
        if let cursor, cursor.scope != scope {
            throw WorkItemRepositoryError.inboxPageCursorScopeMismatch
        }
        guard limit > 0 else {
            return InboxPage(items: [], nextCursor: nil, hasMore: false)
        }
        try Task.checkCancellation()

        let queryObserver = self.queryObserver
        // Snooze deadlines are persisted in integer milliseconds, but inbox
        // eligibility compares their decoded `Date` values against the exact
        // caller-supplied instant. Keep this bound as a floating-point
        // millisecond value so a deadline at 1.001s remains snoozed at
        // 1.0006s, matching `WorkflowState.isSnoozed(at:)`.
        let now = date.timeIntervalSince1970 * 1_000
        let requestedRowCount: Int
        let didOverflowLimit: Bool
        (requestedRowCount, didOverflowLimit) = limit.addingReportingOverflow(1)
        let pageRowLimit = didOverflowLimit ? limit : requestedRowCount
        let result: InboxPageLoad = try await vault.read { database in
            try Task.checkCancellation()
            queryObserver?()
            let currentDerivedSourceRevision = try Self.currentDerivedSourceRevision(
                for: scope,
                in: database
            )
            let cursorPredicate = cursor == nil ? "" : Self.inboxPageCursorPredicate
            var arguments: [DatabaseValueConvertible] = [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue,
                currentDerivedSourceRevision,
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                now
            ]
            if let cursor {
                arguments += Self.inboxPageCursorArguments(cursor)
            }
            arguments.append(pageRowLimit)
            let rows = try Row.fetchAll(
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
                          AND rule_evaluations.source_revision = ?
                          AND EXISTS (
                              SELECT 1
                              FROM rule_evaluation_evidence
                              WHERE rule_evaluation_evidence.rule_evaluation_id = rule_evaluations.id
                                AND \(Self.currentRuleEvidencePredicate)
                          )
                          AND NOT EXISTS (
                              SELECT 1
                              FROM rule_evaluation_evidence
                              WHERE rule_evaluation_evidence.rule_evaluation_id = rule_evaluations.id
                                AND NOT \(Self.currentRuleEvidencePredicate)
                          )
                    ), inbox_roots AS (
                    SELECT
                        work_items.id, work_items.primary_node_id, work_items.state,
                        work_items.last_relevant_activity_at_ms,
                        github_nodes.kind, github_nodes.title, github_nodes.html_url,
                        github_nodes.repository_id,
                        repositories.github_node_id AS repository_node_id,
                        repositories.owner_login AS repository_owner_login,
                        repositories.name AS repository_name,
                        repositories.is_private AS repository_is_private,
                        repositories.is_archived AS repository_is_archived,
                        repositories.has_discussions AS repository_has_discussions,
                        repositories.has_discussions_known AS repository_has_discussions_known,
                        repositories.html_url AS repository_html_url,
                        workflow_states.status AS workflow_status,
                        workflow_states.pinned AS workflow_pinned,
                        workflow_states.priority AS workflow_priority,
                        workflow_states.snoozed_until_ms,
                        workflow_states.follow_up_at_ms,
                        workflow_states.local_note,
                        workflow_states.updated_at_ms AS workflow_updated_at_ms,
                        attention_scores.score,
                        attention_scores.breakdown_json AS score_breakdown_json,
                        COALESCE(workflow_states.pinned, 0) AS inbox_pinned,
                        CASE workflow_states.priority
                            WHEN 1 THEN 1
                            WHEN 3 THEN 3
                            ELSE 2
                        END AS inbox_priority,
                        COALESCE(attention_scores.score, 0) AS inbox_score,
                        CASE WHEN (
                            SELECT MIN(grouped_actions.due_at_ms)
                            FROM action_items AS grouped_actions
                            LEFT JOIN work_item_group_memberships
                              ON work_item_group_memberships.constituent_work_item_id = grouped_actions.work_item_id
                            WHERE COALESCE(
                                      work_item_group_memberships.canonical_work_item_id,
                                      grouped_actions.work_item_id
                                  ) = work_items.id
                              AND grouped_actions.state = 'open'
                        ) IS NULL THEN 1 ELSE 0 END AS inbox_due_is_nil,
                        (
                            SELECT MIN(grouped_actions.due_at_ms)
                            FROM action_items AS grouped_actions
                            LEFT JOIN work_item_group_memberships
                              ON work_item_group_memberships.constituent_work_item_id = grouped_actions.work_item_id
                            WHERE COALESCE(
                                      work_item_group_memberships.canonical_work_item_id,
                                      grouped_actions.work_item_id
                                  ) = work_items.id
                              AND grouped_actions.state = 'open'
                        ) AS inbox_due_at_ms
                    FROM work_items
                    JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                        AND github_nodes.account_id = work_items.account_id
                        AND github_nodes.organization_id = work_items.organization_id
                    LEFT JOIN repositories ON repositories.id = github_nodes.repository_id
                    LEFT JOIN workflow_states ON workflow_states.work_item_id = work_items.id
                    LEFT JOIN attention_scores ON attention_scores.work_item_id = work_items.id
                    LEFT JOIN work_item_group_memberships
                      ON work_item_group_memberships.constituent_work_item_id = work_items.id
                     AND work_item_group_memberships.account_id = work_items.account_id
                     AND work_item_group_memberships.organization_id = work_items.organization_id
                    WHERE work_items.account_id = ? AND work_items.organization_id = ?
                      AND (
                          work_item_group_memberships.constituent_work_item_id IS NULL
                          OR work_item_group_memberships.canonical_work_item_id = work_items.id
                      )
                      AND work_items.state != 'inaccessible'
                      AND COALESCE(workflow_states.snoozed_until_ms > ?, 0) = 0
                      AND COALESCE(workflow_states.status, 'active') != 'archived'
                      AND (
                          (
                              COALESCE(workflow_states.status, 'active') = 'waiting'
                              AND EXISTS (
                                  SELECT 1 FROM current_rule_evaluations
                                  WHERE current_rule_evaluations.work_item_id = work_items.id
                                    AND current_rule_evaluations.rule_id IN ('awaitedActorResponded', 'followUpDue')
                              )
                          )
                          OR (
                              COALESCE(workflow_states.status, 'active') != 'waiting'
                              AND (
                                  work_items.state != 'resolved'
                                  OR EXISTS (
                                      SELECT 1 FROM action_items
                                      LEFT JOIN work_item_group_memberships
                                        ON work_item_group_memberships.constituent_work_item_id = action_items.work_item_id
                                      WHERE COALESCE(
                                                work_item_group_memberships.canonical_work_item_id,
                                                action_items.work_item_id
                                            ) = work_items.id
                                        AND action_items.state = 'open'
                                  )
                              )
                              AND (
                                  COALESCE(workflow_states.pinned, 0) = 1
                                  OR EXISTS (
                                      SELECT 1 FROM current_rule_evaluations
                                      WHERE current_rule_evaluations.work_item_id = work_items.id
                                  )
                                  OR EXISTS (
                                      SELECT 1 FROM action_items
                                      LEFT JOIN work_item_group_memberships
                                        ON work_item_group_memberships.constituent_work_item_id = action_items.work_item_id
                                      WHERE COALESCE(
                                                work_item_group_memberships.canonical_work_item_id,
                                                action_items.work_item_id
                                            ) = work_items.id
                                        AND action_items.state = 'open'
                                  )
                              )
                          )
                      )
                    )
                    SELECT *
                    FROM inbox_roots
                    \(cursorPredicate)
                    ORDER BY
                        inbox_pinned DESC,
                        inbox_priority DESC,
                        inbox_score DESC,
                        inbox_due_is_nil ASC,
                        inbox_due_at_ms ASC,
                        last_relevant_activity_at_ms DESC,
                        id ASC
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments)
            )
            let hasMore = !didOverflowLimit && rows.count > limit
            let selectedRows = hasMore ? Array(rows.prefix(limit)) : rows
            let items = try Self.loadGraph(
                from: selectedRows,
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                authorityScope: scope,
                currentDerivedSourceRevision: currentDerivedSourceRevision,
                freshness: freshness,
                onQuery: queryObserver,
                in: database
            )
            return InboxPageLoad(items: items, hasMore: hasMore)
        }
        try Task.checkCancellation()
        let nextCursor = result.hasMore
            ? try result.items.last.map { try Self.inboxPageCursor(for: $0, scope: scope) }
            : nil
        return InboxPage(items: result.items, nextCursor: nextCursor, hasMore: result.hasMore)
    }

    func ensureWorkItem(for node: NormalizedGitHubNode) async throws -> WorkItemID {
        try ensureAccountScope(node.accountID)
        return try await vault.write { database in
            try Self.ensureWorkItem(for: node, in: database)
        }
    }

    func identifiers(
        for nodeIDs: Set<GitHubNodeID>,
        accountID: AccountID
    ) async throws -> [WorkItemID] {
        try ensureAccountScope(accountID)
        guard !nodeIDs.isEmpty else {
            return []
        }
        let nodeIDValues = nodeIDs.map(\.rawValue).sorted()
        return try await vault.read { database -> [WorkItemID] in
            var rawWorkItemIDs: [String] = []
            for batch in Self.batches(nodeIDValues) {
                try Task.checkCancellation()
                rawWorkItemIDs += try String.fetchAll(
                    database,
                    sql: """
                        SELECT id
                        FROM work_items
                        WHERE account_id = ? AND primary_node_id IN (\(Self.placeholders(for: batch)))
                        ORDER BY id
                        """,
                    arguments: StatementArguments([accountID.rawValue] + batch)
                )
            }
            return try rawWorkItemIDs.sorted().map { rawValue in
                guard let workItemID = WorkItemID(rawValue: rawValue) else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                return workItemID
            }
        }
    }

    nonisolated static func ensureWorkItem(
        for node: NormalizedGitHubNode,
        in database: Database
    ) throws -> WorkItemID {
        if let existing = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, organization_id FROM work_items
                    WHERE account_id = ? AND primary_node_id = ?
                    """,
                arguments: [node.accountID.rawValue, node.nodeID.rawValue]
            ),
            let existingID: String = existing["id"],
            let existingOrganizationID: String = existing["organization_id"]
        {
                let wasTransferred = existingOrganizationID != node.organizationID.rawValue
                try database.execute(
                    sql: """
                        UPDATE work_items
                        SET organization_id = ?, state = ?, last_relevant_activity_at_ms = ?, updated_at_ms = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        node.organizationID.rawValue,
                        node.state == .open || node.state == .draft ? WorkItemState.active.rawValue : WorkItemState.resolved.rawValue,
                        Self.milliseconds(node.updatedAt),
                        Self.milliseconds(node.observedAt),
                        existingID
                    ]
                )
                if wasTransferred {
                    // A transferred primary node keeps its durable Work Item
                    // and local workflow history, but every derived graph edge
                    // belonged to its former organization. Retain only the
                    // primary membership until the destination projection
                    // rebuilds the graph under its new authority.
                    try database.execute(
                        sql: "DELETE FROM work_item_members WHERE work_item_id = ? AND github_node_id != ?",
                        arguments: [existingID, node.nodeID.rawValue]
                    )
                    try database.execute(
                        sql: "DELETE FROM work_item_context_links WHERE work_item_id = ?",
                        arguments: [existingID]
                    )
                    try database.execute(
                        sql: """
                            DELETE FROM work_item_group_memberships
                            WHERE constituent_work_item_id = ? OR canonical_work_item_id = ?
                            """,
                        arguments: [existingID, existingID]
                    )
                    try database.execute(
                        sql: """
                            UPDATE github_nodes
                            SET organization_id = ?
                            WHERE github_node_id = ? AND account_id = ?
                            """,
                        arguments: [
                            node.organizationID.rawValue,
                            node.nodeID.rawValue,
                            node.accountID.rawValue
                        ]
                    )
                }
                try database.execute(
                    sql: """
                        INSERT INTO work_item_members (work_item_id, github_node_id, role)
                        VALUES (?, ?, ?)
                        ON CONFLICT(work_item_id, github_node_id) DO UPDATE SET role = excluded.role
                        """,
                    arguments: [existingID, node.nodeID.rawValue, WorkItemMemberRole.primary.rawValue]
                )
                guard let workItemID = WorkItemID(rawValue: existingID) else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                return workItemID
        }

        let workItemID = WorkItemID.make()
        try database.execute(
                sql: """
                    INSERT INTO work_items (
                        id, account_id, organization_id, primary_node_id, state,
                        last_relevant_activity_at_ms, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    workItemID.rawValue,
                    node.accountID.rawValue,
                    node.organizationID.rawValue,
                    node.nodeID.rawValue,
                    node.state == .open || node.state == .draft ? WorkItemState.active.rawValue : WorkItemState.resolved.rawValue,
                    Self.milliseconds(node.updatedAt),
                    Self.milliseconds(node.observedAt),
                    Self.milliseconds(node.observedAt)
                ]
        )
        try database.execute(
                sql: """
                    INSERT INTO work_item_members (work_item_id, github_node_id, role)
                    VALUES (?, ?, ?)
                    """,
                    arguments: [workItemID.rawValue, node.nodeID.rawValue, WorkItemMemberRole.primary.rawValue]
        )
        return workItemID
    }

    private func ensureAccountScope(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw WorkItemRepositoryError.accountScopeMismatch
        }
    }

    /// Decodes a complete graph for already bounded root rows. Keeping this
    /// loader shared means the Inbox page has the same child collections and
    /// exact evidence-authority filtering as the established full fetch.
    private nonisolated static func loadGraph(
        from rows: [Row],
        accountID: AccountID,
        organizationID: OrganizationID,
        authorityScope: SynchronizationScope?,
        currentDerivedSourceRevision: String?,
        freshness: FreshnessState,
        onQuery: (@Sendable () -> Void)?,
        in database: Database
    ) throws -> [WorkItem] {
        let workItemIDs = try rows.map { row -> String in
            guard let workItemID: String = row["id"] else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            return workItemID
        }
        guard !workItemIDs.isEmpty else { return [] }

        // A full work item graph is still the public repository contract, but
        // all dependent reads are bounded by the selected root rows.
        let reasons = try attentionReasons(
            in: database,
            workItemIDs: workItemIDs,
            authorityScope: authorityScope,
            currentDerivedSourceRevision: currentDerivedSourceRevision,
            onQuery: onQuery
        )
        try Task.checkCancellation()
        let actions = try actionItems(
            in: database, workItemIDs: workItemIDs, onQuery: onQuery
        )
        try Task.checkCancellation()
        let memberReferences = try memberReferences(
            in: database,
            workItemIDs: workItemIDs,
            authorityScope: authorityScope,
            onQuery: onQuery
        )
        let contextReferences = try contextReferences(
            in: database,
            workItemIDs: workItemIDs,
            authorityScope: authorityScope,
            onQuery: onQuery
        )
        let relatedNodeIDs = Set(memberReferences.map(\.nodeID) + contextReferences.map(\.nodeID))
        let content = try content(
            in: database,
            nodeIDs: relatedNodeIDs,
            authorityScope: authorityScope,
            onQuery: onQuery
        )
        let members = try members(memberReferences, contentByNodeID: content)
        let contextLinks = try contextLinks(contextReferences, contentByNodeID: content)
        try Task.checkCancellation()
        let relations = try relations(
            in: database,
            accountID: accountID,
            organizationID: organizationID,
            workItemIDs: workItemIDs,
            authorityScope: authorityScope,
            onQuery: onQuery
        )
        try Task.checkCancellation()

        return try rows.enumerated().map { index, row in
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            guard let workItemID: String = row["id"] else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            return try workItem(
                from: row,
                accountID: accountID,
                organizationID: organizationID,
                attentionReasons: reasons[workItemID] ?? [],
                actionItems: actions[workItemID] ?? [],
                members: members[workItemID] ?? [],
                contextLinks: contextLinks[workItemID] ?? [],
                relations: relations[workItemID] ?? [],
                freshness: freshness
            )
        }
    }

    private nonisolated static func workItem(
        from row: Row,
        accountID: AccountID,
        organizationID: OrganizationID,
        attentionReasons: [AttentionReason],
        actionItems: [ActionItem],
        members: [WorkItemMember],
        contextLinks: [WorkItemContextLink],
        relations: [WorkRelation],
        freshness: FreshnessState
    ) throws -> WorkItem {
        guard let id = WorkItemID(rawValue: row["id"]),
              let nodeID = GitHubNodeID(rawValue: row["primary_node_id"]),
              let state = WorkItemState(rawValue: row["state"]),
              let kind = GitHubContentKind(rawValue: row["kind"]),
              let sourceURL = URL(string: row["html_url"]),
              let activity = date(milliseconds: row["last_relevant_activity_at_ms"])
        else {
            throw WorkItemRepositoryError.invalidPersistedData
        }
        let workflow = WorkflowState(
            status: LocalWorkStatus(rawValue: row["workflow_status"] ?? "") ?? .active,
            isPinned: (row["workflow_pinned"] as Bool?) ?? false,
            priority: WorkPriority(rawValue: row["workflow_priority"] ?? 2) ?? .normal,
            snoozedUntil: date(milliseconds: row["snoozed_until_ms"]),
            followUpAt: date(milliseconds: row["follow_up_at_ms"]),
            localNote: row["local_note"],
            updatedAt: date(milliseconds: row["workflow_updated_at_ms"]) ?? activity
        )
        return WorkItem(
            id: id,
            accountID: accountID,
            organizationID: organizationID,
            primaryNodeID: nodeID,
            title: row["title"],
            state: state,
            sourceKind: kind,
            sourceURL: sourceURL,
            repository: try repository(from: row),
            members: members,
            contextLinks: contextLinks,
            relations: relations,
            attentionReasons: attentionReasons,
            actionItems: actionItems,
            workflow: workflow,
            freshness: freshness,
            lastRelevantActivityAt: activity,
            score: try attentionScore(from: row)
        )
    }

    private nonisolated static func date(milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

    private nonisolated static func attentionScore(from row: Row) throws -> AttentionScore {
        guard let value: Int = row["score"] else {
            return AttentionScore(value: 0, breakdown: [:])
        }
        guard let breakdownData: Data = row["score_breakdown_json"] else {
            throw WorkItemRepositoryError.invalidPersistedData
        }
        return AttentionScore(
            value: value,
            breakdown: try JSONDecoder().decode([String: Int].self, from: breakdownData)
        )
    }

    private nonisolated static func repository(from row: Row) throws -> RepositorySummary? {
        guard let rawID: String = row["repository_id"] else {
            return nil
        }
        guard let id = RepositoryID(rawValue: rawID),
              let rawNodeID: String = row["repository_node_id"],
              let nodeID = GitHubNodeID(rawValue: rawNodeID),
              let rawURL: String = row["repository_html_url"],
              let url = URL(string: rawURL)
        else {
            throw WorkItemRepositoryError.invalidPersistedData
        }
        return RepositorySummary(
            id: id,
            nodeID: nodeID,
            ownerLogin: row["repository_owner_login"],
            name: row["repository_name"],
            isPrivate: row["repository_is_private"],
            isArchived: row["repository_is_archived"],
            hasDiscussions: row["repository_has_discussions"],
            hasDiscussionsKnown: row["repository_has_discussions_known"],
            url: url
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private struct InboxPageLoad: Sendable {
        let items: [WorkItem]
        let hasMore: Bool
    }

    // This is the lexicographic continuation predicate for the exact persisted
    // rank below. It intentionally uses the normalized SQL priority, since a
    // corrupt stored priority decodes as `.normal` in `workflow(from:)`.
    private static let inboxPageCursorPredicate = """
        WHERE
            inbox_pinned < ?
            OR (inbox_pinned = ? AND inbox_priority < ?)
            OR (inbox_pinned = ? AND inbox_priority = ? AND inbox_score < ?)
            OR (
                inbox_pinned = ?
                AND inbox_priority = ?
                AND inbox_score = ?
                AND (
                    inbox_due_is_nil > ?
                    OR (
                        inbox_due_is_nil = ?
                        AND (
                            (
                                inbox_due_is_nil = 0
                                AND (
                                    inbox_due_at_ms > ?
                                    OR (
                                        inbox_due_at_ms = ?
                                        AND (
                                            last_relevant_activity_at_ms < ?
                                            OR (
                                                last_relevant_activity_at_ms = ?
                                                AND id > ?
                                            )
                                        )
                                    )
                                )
                            )
                            OR (
                                inbox_due_is_nil = 1
                                AND (
                                    last_relevant_activity_at_ms < ?
                                    OR (
                                        last_relevant_activity_at_ms = ?
                                        AND id > ?
                                    )
                                )
                            )
                        )
                    )
                )
            )
        """

    private nonisolated static func inboxPageCursorArguments(
        _ cursor: InboxPageCursor
    ) -> [DatabaseValueConvertible] {
        let pinned = cursor.isPinned ? 1 : 0
        let priority = cursor.priority.rawValue
        let score = cursor.score
        let dueBucket = cursor.earliestOpenActionDueAt == nil ? 1 : 0
        // This value is ignored for a nil due date, because that branch only
        // evaluates the activity/id suffix. Keeping it non-optional avoids a
        // SQLite NULL comparison from changing the keyset predicate.
        let dueAt = cursor.earliestOpenActionDueAt.map(milliseconds) ?? 0
        let activity = milliseconds(cursor.lastRelevantActivityAt)
        let id = cursor.workItemID.rawValue
        return [
            pinned,
            pinned, priority,
            pinned, priority, score,
            pinned, priority, score, dueBucket,
            dueBucket, dueAt, dueAt, activity, activity, id,
            activity, activity, id
        ]
    }

    private nonisolated static func inboxPageCursor(
        for item: WorkItem,
        scope: SynchronizationScope
    ) -> InboxPageCursor {
        InboxPageCursor(
            scope: scope,
            isPinned: item.workflow.isPinned,
            priority: item.workflow.priority,
            score: item.score.value,
            earliestOpenActionDueAt: item.openActionItems.compactMap(\.dueAt).min(),
            lastRelevantActivityAt: item.lastRelevantActivityAt,
            workItemID: item.id
        )
    }

    private static let maximumBatchSize = 500

    private struct MemberReference {
        let workItemID: String
        let nodeID: GitHubNodeID
        let role: WorkItemMemberRole
    }

    private struct ContextReference {
        let workItemID: String
        let nodeID: GitHubNodeID
        let relation: WorkRelationKind
    }

    private struct RelationReference {
        let workItemID: String
        let relationID: String
        let subjectNodeID: GitHubNodeID
        let kind: WorkRelationKind
        let objectNodeID: GitHubNodeID?
        let confidence: RelationConfidence
        let observedAt: Date
    }

    private nonisolated static func batches(_ values: [String]) -> [[String]] {
        stride(from: 0, to: values.count, by: maximumBatchSize).map { start in
            Array(values[start..<min(start + maximumBatchSize, values.count)])
        }
    }

    private nonisolated static func placeholders(for values: [String]) -> String {
        values.map { _ in "?" }.joined(separator: ",")
    }

    private nonisolated static func attentionReasons(
        in database: Database,
        workItemIDs: [String],
        authorityScope: SynchronizationScope?,
        currentDerivedSourceRevision: String?,
        onQuery: (@Sendable () -> Void)?
    ) throws -> [String: [AttentionReason]] {
        var rows: [Row] = []
        for batch in batches(workItemIDs) {
            try Task.checkCancellation()
            onQuery?()
            if let authorityScope {
                guard let currentDerivedSourceRevision else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                rows += try Row.fetchAll(
                    database,
                    sql: """
                        SELECT rule_evaluations.work_item_id, rule_evaluations.id,
                               rule_evaluations.rule_id, rule_evaluations.rule_version,
                               rule_evaluations.category, rule_evaluations.strength,
                               rule_evaluations.title, rule_evaluations.explanation,
                               rule_evaluations.evaluated_at_ms
                        FROM rule_evaluations
                        JOIN derived_intelligence_runs
                          ON derived_intelligence_runs.account_id = rule_evaluations.account_id
                         AND derived_intelligence_runs.organization_id = rule_evaluations.organization_id
                         AND derived_intelligence_runs.credential_revision = rule_evaluations.credential_revision
                         AND derived_intelligence_runs.capability_revision = rule_evaluations.capability_revision
                         AND derived_intelligence_runs.source_revision = rule_evaluations.source_revision
                        WHERE rule_evaluations.work_item_id IN (\(placeholders(for: batch)))
                          AND rule_evaluations.account_id = ?
                          AND rule_evaluations.organization_id = ?
                          AND rule_evaluations.credential_revision = ?
                          AND rule_evaluations.capability_revision = ?
                          AND rule_evaluations.source_revision = ?
                          AND EXISTS (
                              SELECT 1
                              FROM rule_evaluation_evidence
                              WHERE rule_evaluation_evidence.rule_evaluation_id = rule_evaluations.id
                                AND \(Self.currentRuleEvidencePredicate)
                          )
                          AND NOT EXISTS (
                              SELECT 1
                              FROM rule_evaluation_evidence
                              WHERE rule_evaluation_evidence.rule_evaluation_id = rule_evaluations.id
                                AND NOT \(Self.currentRuleEvidencePredicate)
                          )
                        ORDER BY rule_evaluations.work_item_id, rule_evaluations.strength DESC, rule_evaluations.id
                        """,
                    arguments: StatementArguments(batch + [
                        authorityScope.accountID.rawValue,
                        authorityScope.organizationID.rawValue,
                        authorityScope.credentialRevision.rawValue,
                        authorityScope.capabilityRevision.rawValue,
                        currentDerivedSourceRevision
                    ])
                )
            } else {
                rows += try Row.fetchAll(
                    database,
                    sql: """
                        SELECT work_item_id, id, rule_id, rule_version, category, strength, title, explanation, evaluated_at_ms
                        FROM attention_reasons
                        WHERE work_item_id IN (\(placeholders(for: batch)))
                        ORDER BY work_item_id, strength DESC, id
                        """,
                    arguments: StatementArguments(batch)
                )
            }
        }
        let evidence = try attentionEvidence(
            in: database,
            reasonIDs: try rows.map { row in
                guard let id: String = row["id"] else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                return id
            },
            authorityScope: authorityScope,
            onQuery: onQuery
        )
        var result: [String: [AttentionReason]] = [:]
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard let workItemID: String = row["work_item_id"],
                  let reasonID: String = row["id"],
                  let category = AttentionCategory(rawValue: row["category"]),
                  let evaluatedAt = date(milliseconds: row["evaluated_at_ms"])
            else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            result[workItemID, default: []].append(
                AttentionReason(
                    id: reasonID,
                    category: category,
                    ruleID: row["rule_id"],
                    ruleVersion: row["rule_version"],
                    strength: row["strength"],
                    title: row["title"],
                    explanation: row["explanation"],
                    evidence: evidence[reasonID] ?? [],
                    evaluatedAt: evaluatedAt
                )
            )
        }
        return result
    }

    private nonisolated static func attentionEvidence(
        in database: Database,
        reasonIDs: [String],
        authorityScope: SynchronizationScope?,
        onQuery: (@Sendable () -> Void)?
    ) throws -> [String: [EvidenceReference]] {
        guard !reasonIDs.isEmpty else { return [:] }
        var result: [String: [EvidenceReference]] = [:]
        for batch in batches(reasonIDs) {
            try Task.checkCancellation()
            onQuery?()
            if let authorityScope {
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT rule_evaluation_evidence.rule_evaluation_id AS attention_reason_id,
                               rule_evaluation_evidence.evidence_id,
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
                        JOIN rule_evaluations
                          ON rule_evaluations.id = rule_evaluation_evidence.rule_evaluation_id
                        JOIN derived_intelligence_runs
                          ON derived_intelligence_runs.account_id = rule_evaluations.account_id
                         AND derived_intelligence_runs.organization_id = rule_evaluations.organization_id
                         AND derived_intelligence_runs.credential_revision = rule_evaluations.credential_revision
                         AND derived_intelligence_runs.capability_revision = rule_evaluations.capability_revision
                         AND derived_intelligence_runs.source_revision = rule_evaluations.source_revision
                        WHERE rule_evaluation_evidence.rule_evaluation_id IN (\(placeholders(for: batch)))
                          AND rule_evaluations.account_id = ?
                          AND rule_evaluations.organization_id = ?
                          AND rule_evaluations.credential_revision = ?
                          AND rule_evaluations.capability_revision = ?
                          AND \(Self.currentRuleEvidencePredicate)
                        ORDER BY rule_evaluation_evidence.rule_evaluation_id,
                                 rule_evaluation_evidence.evidence_id
                        """,
                    arguments: StatementArguments(batch + [
                        authorityScope.accountID.rawValue,
                        authorityScope.organizationID.rawValue,
                        authorityScope.credentialRevision.rawValue,
                        authorityScope.capabilityRevision.rawValue
                    ])
                )
                for row in rows {
                    guard let reasonID: String = row["attention_reason_id"] else {
                        throw WorkItemRepositoryError.invalidPersistedData
                    }
                    let evidence = try evidenceReference(from: row)
                    guard isAuthorizedForPresentation(evidence, scope: authorityScope) else {
                        continue
                    }
                    result[reasonID, default: []].append(evidence)
                }
            } else {
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT attention_reason_id, evidence_id, source, source_node_id, source_event_id,
                               source_revision, observed_at_ms, excerpt
                        FROM attention_reason_evidence
                        WHERE attention_reason_id IN (\(placeholders(for: batch)))
                        ORDER BY attention_reason_id, evidence_id
                        """,
                    arguments: StatementArguments(batch)
                )
                for row in rows {
                    guard let reasonID: String = row["attention_reason_id"],
                          let id = EvidenceID(rawValue: row["evidence_id"]),
                          let source = EvidenceSource(rawValue: row["source"]),
                          let observedAt = date(milliseconds: row["observed_at_ms"])
                    else {
                        throw WorkItemRepositoryError.invalidPersistedData
                    }
                    result[reasonID, default: []].append(
                        EvidenceReference(
                            id: id,
                            source: source,
                            locator: .legacyUnverified,
                            authority: .legacyUnverified,
                            nodeID: (row["source_node_id"] as String?).flatMap(GitHubNodeID.init(rawValue:)),
                            eventID: (row["source_event_id"] as String?).flatMap(GitHubEventID.init(rawValue:)),
                            sourceRevision: row["source_revision"],
                            confidence: .provisional,
                            confirmation: .provisional,
                            observedAt: observedAt,
                            excerpt: row["excerpt"]
                        )
                    )
                }
            }
        }
        return result
    }

    private nonisolated static func actionItems(
        in database: Database,
        workItemIDs: [String],
        onQuery: (@Sendable () -> Void)?
    ) throws -> [String: [ActionItem]] {
        var rows: [Row] = []
        for batch in batches(workItemIDs) {
            try Task.checkCancellation()
            onQuery?()
            rows += try Row.fetchAll(
                database,
                sql: """
                    SELECT action_items.work_item_id,
                           COALESCE(work_item_group_memberships.canonical_work_item_id, action_items.work_item_id)
                             AS canonical_work_item_id,
                           action_items.id, action_items.title, action_items.detail, action_items.origin,
                           action_items.state, action_items.priority, action_items.due_at_ms, action_items.source_fingerprint,
                           created_at_ms, updated_at_ms, completed_at_ms, dismissed_at_ms
                    FROM action_items
                    LEFT JOIN work_item_group_memberships
                      ON work_item_group_memberships.constituent_work_item_id = action_items.work_item_id
                    WHERE action_items.work_item_id IN (\(placeholders(for: batch)))
                       OR work_item_group_memberships.canonical_work_item_id IN (\(placeholders(for: batch)))
                    ORDER BY canonical_work_item_id, action_items.work_item_id, action_items.state,
                             action_items.due_at_ms, action_items.id
                    """,
                arguments: StatementArguments(batch + batch)
            )
        }
        let evidence = try actionEvidence(
            in: database,
            actionItemIDs: try rows.map { row in
                guard let id: String = row["id"] else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                return id
            },
            onQuery: onQuery
        )
        var result: [String: [ActionItem]] = [:]
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard let workItemID: String = row["work_item_id"],
                  let canonicalWorkItemID: String = row["canonical_work_item_id"],
                  let typedWorkItemID = WorkItemID(rawValue: workItemID),
                  let id = ActionItemID(rawValue: row["id"]),
                  let origin = ActionItemOrigin(rawValue: row["origin"]),
                  let state = ActionItemState(rawValue: row["state"]),
                  let priority = WorkPriority(rawValue: row["priority"]),
                  let createdAt = date(milliseconds: row["created_at_ms"]),
                  let updatedAt = date(milliseconds: row["updated_at_ms"])
            else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            result[canonicalWorkItemID, default: []].append(
                ActionItem(
                    id: id,
                    workItemID: typedWorkItemID,
                    title: row["title"],
                    detail: row["detail"],
                    origin: origin,
                    state: state,
                    priority: priority,
                    dueAt: date(milliseconds: row["due_at_ms"]),
                    evidenceIDs: evidence[id.rawValue] ?? [],
                    sourceFingerprint: row["source_fingerprint"],
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    completedAt: date(milliseconds: row["completed_at_ms"]),
                    dismissedAt: date(milliseconds: row["dismissed_at_ms"])
                )
            )
        }
        return result
    }

    private nonisolated static func actionEvidence(
        in database: Database,
        actionItemIDs: [String],
        onQuery: (@Sendable () -> Void)?
    ) throws -> [String: [EvidenceID]] {
        guard !actionItemIDs.isEmpty else { return [:] }
        var result: [String: [EvidenceID]] = [:]
        for batch in batches(actionItemIDs) {
            try Task.checkCancellation()
            onQuery?()
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT action_item_id, evidence_id
                    FROM action_item_evidence
                    WHERE action_item_id IN (\(placeholders(for: batch)))
                    ORDER BY action_item_id, evidence_id
                    """,
                arguments: StatementArguments(batch)
            )
            for row in rows {
                guard let actionItemID: String = row["action_item_id"] else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                if let evidenceID = EvidenceID(rawValue: row["evidence_id"]) {
                    result[actionItemID, default: []].append(evidenceID)
                }
            }
        }
        return result
    }

    private nonisolated static func memberReferences(
        in database: Database,
        workItemIDs: [String],
        authorityScope: SynchronizationScope?,
        onQuery: (@Sendable () -> Void)?
    ) throws -> [MemberReference] {
        var result: [MemberReference] = []
        for batch in batches(workItemIDs) {
            try Task.checkCancellation()
            onQuery?()
            let scopeFilter: String
            let arguments: StatementArguments
            if let authorityScope {
                scopeFilter = "AND github_nodes.account_id = ? AND github_nodes.organization_id = ?"
                arguments = StatementArguments(
                    batch + [authorityScope.accountID.rawValue, authorityScope.organizationID.rawValue]
                )
            } else {
                scopeFilter = ""
                arguments = StatementArguments(batch)
            }
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT work_item_members.work_item_id AS work_item_id,
                           work_item_members.github_node_id AS github_node_id,
                           work_item_members.role AS role
                    FROM work_item_members
                    JOIN github_nodes
                      ON github_nodes.github_node_id = work_item_members.github_node_id
                    WHERE work_item_members.work_item_id IN (\(placeholders(for: batch)))
                    \(scopeFilter)
                    ORDER BY work_item_members.work_item_id,
                             work_item_members.role,
                             work_item_members.github_node_id
                    """,
                arguments: arguments
            )
            for row in rows {
                guard let workItemID: String = row["work_item_id"],
                      let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let role = WorkItemMemberRole(rawValue: row["role"])
                else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                result.append(MemberReference(workItemID: workItemID, nodeID: nodeID, role: role))
            }
        }
        return result
    }

    private nonisolated static func contextReferences(
        in database: Database,
        workItemIDs: [String],
        authorityScope: SynchronizationScope?,
        onQuery: (@Sendable () -> Void)?
    ) throws -> [ContextReference] {
        var result: [ContextReference] = []
        for batch in batches(workItemIDs) {
            try Task.checkCancellation()
            onQuery?()
            let scopeFilter: String
            let arguments: StatementArguments
            if let authorityScope {
                scopeFilter = "AND github_nodes.account_id = ? AND github_nodes.organization_id = ?"
                arguments = StatementArguments(
                    batch + [authorityScope.accountID.rawValue, authorityScope.organizationID.rawValue]
                )
            } else {
                scopeFilter = ""
                arguments = StatementArguments(batch)
            }
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT work_item_context_links.work_item_id AS work_item_id,
                           work_item_context_links.github_node_id AS github_node_id,
                           work_item_context_links.relation AS relation
                    FROM work_item_context_links
                    JOIN github_nodes
                      ON github_nodes.github_node_id = work_item_context_links.github_node_id
                    WHERE work_item_context_links.work_item_id IN (\(placeholders(for: batch)))
                    \(scopeFilter)
                    ORDER BY work_item_context_links.work_item_id,
                             work_item_context_links.relation,
                             work_item_context_links.github_node_id
                    """,
                arguments: arguments
            )
            for row in rows {
                guard let workItemID: String = row["work_item_id"],
                      let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let relation = WorkRelationKind(rawValue: row["relation"])
                else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                result.append(ContextReference(workItemID: workItemID, nodeID: nodeID, relation: relation))
            }
        }
        return result
    }

    private nonisolated static func members(
        _ references: [MemberReference],
        contentByNodeID: [GitHubNodeID: GitHubContentSummary]
    ) throws -> [String: [WorkItemMember]] {
        var result: [String: [WorkItemMember]] = [:]
        for (index, reference) in references.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard let content = contentByNodeID[reference.nodeID] else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            result[reference.workItemID, default: []].append(
                WorkItemMember(id: reference.nodeID, role: reference.role, content: content, evidence: [])
            )
        }
        return result
    }

    private nonisolated static func contextLinks(
        _ references: [ContextReference],
        contentByNodeID: [GitHubNodeID: GitHubContentSummary]
    ) throws -> [String: [WorkItemContextLink]] {
        var result: [String: [WorkItemContextLink]] = [:]
        for (index, reference) in references.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard let content = contentByNodeID[reference.nodeID] else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            result[reference.workItemID, default: []].append(
                WorkItemContextLink(id: reference.nodeID, relation: reference.relation, content: content, evidence: [])
            )
        }
        return result
    }

    private nonisolated static func relations(
        in database: Database,
        accountID: AccountID,
        organizationID: OrganizationID,
        workItemIDs: [String],
        authorityScope: SynchronizationScope?,
        onQuery: (@Sendable () -> Void)?
    ) throws -> [String: [WorkRelation]] {
        var references: [RelationReference] = []
        for batch in batches(workItemIDs) {
            try Task.checkCancellation()
            onQuery?()
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT work_item_members.work_item_id, relations.id, relations.subject_node_id,
                           relations.object_node_id, relations.kind, relations.confidence,
                           relations.observed_at_ms
                    FROM relations
                    JOIN work_item_members
                      ON work_item_members.github_node_id = relations.subject_node_id
                    JOIN github_nodes
                      ON github_nodes.github_node_id = relations.subject_node_id
                     AND github_nodes.account_id = ?
                     AND github_nodes.organization_id = ?
                    WHERE relations.account_id = ?
                      AND work_item_members.work_item_id IN (\(placeholders(for: batch)))
                    ORDER BY work_item_members.work_item_id, relations.subject_node_id,
                             relations.kind, relations.object_node_id, relations.id
                    """,
                arguments: StatementArguments([
                    accountID.rawValue, organizationID.rawValue, accountID.rawValue
                ] + batch)
            )
            for row in rows {
                guard let workItemID: String = row["work_item_id"],
                      let relationID: String = row["id"],
                      let subjectNodeID = GitHubNodeID(rawValue: row["subject_node_id"]),
                      let kind = WorkRelationKind(rawValue: row["kind"]),
                      let confidence = RelationConfidence(rawValue: row["confidence"]),
                      let observedAt = date(milliseconds: row["observed_at_ms"])
                else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                let objectNodeValue: String? = row["object_node_id"]
                guard objectNodeValue.flatMap(GitHubNodeID.init(rawValue:)) != nil || objectNodeValue == nil else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                references.append(
                    RelationReference(
                        workItemID: workItemID,
                        relationID: relationID,
                        subjectNodeID: subjectNodeID,
                        kind: kind,
                        objectNodeID: objectNodeValue.flatMap(GitHubNodeID.init(rawValue:)),
                        confidence: confidence,
                        observedAt: observedAt
                    )
                )
            }
        }
        let evidence = try relationEvidence(
            in: database,
            relationIDs: references.map(\.relationID),
            authorityScope: authorityScope,
            onQuery: onQuery
        )
        let evidenceNodeIDs = Set(evidence.values.flatMap { $0.compactMap(\.nodeID) })
        let evidenceNodeRevisions: [GitHubNodeID: String]
        if evidenceNodeIDs.isEmpty {
            evidenceNodeRevisions = [:]
        } else {
            onQuery?()
            let identifiers = evidenceNodeIDs.map(\.rawValue).sorted()
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT github_node_id, source_revision
                    FROM github_nodes
                    WHERE account_id = ? AND organization_id = ?
                      AND github_node_id IN (\(placeholders(for: identifiers)))
                    """,
                arguments: StatementArguments([accountID.rawValue, organizationID.rawValue] + identifiers)
            )
            evidenceNodeRevisions = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let sourceRevision: String = row["source_revision"],
                      !sourceRevision.isEmpty
                else { return nil }
                return (nodeID, sourceRevision)
            })
        }
        var result: [String: [WorkRelation]] = [:]
        for (index, reference) in references.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            let relationEvidence = (evidence[reference.relationID] ?? []).filter { evidence in
                switch evidence.authority {
                case .github:
                    guard let evidenceNodeID = evidence.nodeID,
                          let sourceRevision = evidence.sourceRevision
                    else { return false }
                    return evidenceNodeRevisions[evidenceNodeID] == sourceRevision
                case .localWorkflow:
                    return true
                case .legacyUnverified:
                    return authorityScope == nil
                }
            }
            // Account-only relation rows are not sufficient authority. When
            // presentation has an active scope, a relation must carry at
            // least one exact current-scope GitHub or local-workflow proof.
            if authorityScope != nil, relationEvidence.isEmpty { continue }
            result[reference.workItemID, default: []].append(
                WorkRelation(
                    kind: reference.kind,
                    subjectNodeID: reference.subjectNodeID,
                    objectNodeID: reference.objectNodeID,
                    confidence: reference.confidence,
                    evidence: relationEvidence,
                    observedAt: reference.observedAt
                )
            )
        }
        return result
    }

    private nonisolated static func relationEvidence(
        in database: Database,
        relationIDs: [String],
        authorityScope: SynchronizationScope?,
        onQuery: (@Sendable () -> Void)?
    ) throws -> [String: [EvidenceReference]] {
        guard !relationIDs.isEmpty else { return [:] }
        var result: [String: [EvidenceReference]] = [:]
        for batch in batches(relationIDs) {
            try Task.checkCancellation()
            onQuery?()
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT relation_id, evidence_id, source, source_node_id, source_event_id,
                           source_revision, source_locator_kind, source_locator,
                           authority_kind, authority_account_id, authority_organization_id,
                           authority_feature, authority_stream_id,
                           authority_credential_revision, authority_capability_revision,
                           raw_snapshot_id, confidence, confirmation, observed_at_ms, excerpt
                    FROM relation_evidence
                    WHERE relation_id IN (\(placeholders(for: batch)))
                    ORDER BY relation_id, observed_at_ms, source, source_locator_kind, source_locator, evidence_id
                    """,
                arguments: StatementArguments(batch)
            )
            for row in rows {
                guard let relationID: String = row["relation_id"] else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                let evidence = try evidenceReference(from: row)
                guard isAuthorizedForPresentation(evidence, scope: authorityScope) else {
                    continue
                }
                result[relationID, default: []].append(evidence)
            }
        }
        return result
    }

    private nonisolated static func evidenceReference(from row: Row) throws -> EvidenceReference {
        let values: RelationEvidenceValues
        do {
            values = try RelationEvidenceValues(row: row)
        } catch {
            throw WorkItemRepositoryError.invalidPersistedData
        }
        guard let id = EvidenceID(rawValue: values.id),
              let source = EvidenceSource(rawValue: values.source),
              let locator = EvidenceLocator(kind: values.locatorKind, value: values.locatorValue),
              let confidence = RelationConfidence(rawValue: values.confidence),
              let confirmation = EvidenceConfirmation(rawValue: values.confirmation),
              let observedAt = date(milliseconds: values.observedAtMilliseconds),
              let authority = evidenceAuthority(kind: values.authorityKind, values: values),
              isValidRelationEvidence(source: source, locator: locator, authority: authority),
              values.sourceNodeID.flatMap(GitHubNodeID.init(rawValue:)) != nil || values.sourceNodeID == nil,
              values.sourceEventID.flatMap(GitHubEventID.init(rawValue:)) != nil || values.sourceEventID == nil,
              values.rawSnapshotID.flatMap(RawAPISnapshotID.init(rawValue:)) != nil || values.rawSnapshotID == nil
        else {
            throw WorkItemRepositoryError.invalidPersistedData
        }
        return EvidenceReference(
            id: id,
            source: source,
            locator: locator,
            authority: authority,
            nodeID: values.sourceNodeID.flatMap(GitHubNodeID.init(rawValue:)),
            eventID: values.sourceEventID.flatMap(GitHubEventID.init(rawValue:)),
            sourceRevision: values.sourceRevision,
            rawSnapshotID: values.rawSnapshotID.flatMap(RawAPISnapshotID.init(rawValue:)),
            confidence: confidence,
            confirmation: confirmation,
            observedAt: observedAt,
            excerpt: values.excerpt
        )
    }

    private struct RelationEvidenceValues {
        let id: String
        let source: String
        let sourceNodeID: String?
        let sourceEventID: String?
        let sourceRevision: String?
        let locatorKind: String
        let locatorValue: String
        let authorityKind: String
        let authorityAccountID: String?
        let authorityOrganizationID: String?
        let authorityFeature: String?
        let authorityStreamID: String?
        let authorityCredentialRevision: String?
        let authorityCapabilityRevision: String?
        let rawSnapshotID: String?
        let confidence: String
        let confirmation: String
        let observedAtMilliseconds: Int64
        let excerpt: String?

        init(row: Row) throws {
            id = try row.decode(String.self, forColumn: "evidence_id")
            source = try row.decode(String.self, forColumn: "source")
            sourceNodeID = try row.decode(String?.self, forColumn: "source_node_id")
            sourceEventID = try row.decode(String?.self, forColumn: "source_event_id")
            sourceRevision = try row.decode(String?.self, forColumn: "source_revision")
            locatorKind = try row.decode(String.self, forColumn: "source_locator_kind")
            locatorValue = try row.decode(String.self, forColumn: "source_locator")
            authorityKind = try row.decode(String.self, forColumn: "authority_kind")
            authorityAccountID = try row.decode(String?.self, forColumn: "authority_account_id")
            authorityOrganizationID = try row.decode(String?.self, forColumn: "authority_organization_id")
            authorityFeature = try row.decode(String?.self, forColumn: "authority_feature")
            authorityStreamID = try row.decode(String?.self, forColumn: "authority_stream_id")
            authorityCredentialRevision = try row.decode(String?.self, forColumn: "authority_credential_revision")
            authorityCapabilityRevision = try row.decode(String?.self, forColumn: "authority_capability_revision")
            rawSnapshotID = try row.decode(String?.self, forColumn: "raw_snapshot_id")
            confidence = try row.decode(String.self, forColumn: "confidence")
            confirmation = try row.decode(String.self, forColumn: "confirmation")
            observedAtMilliseconds = try row.decode(Int64.self, forColumn: "observed_at_ms")
            excerpt = try row.decode(String?.self, forColumn: "excerpt")
        }
    }

    private nonisolated static func evidenceAuthority(
        kind: String,
        values: RelationEvidenceValues
    ) -> EvidenceAuthority? {
        switch kind {
        case "github":
            guard let accountValue = values.authorityAccountID,
                  let organizationValue = values.authorityOrganizationID,
                  let featureValue = values.authorityFeature,
                  let streamValue = values.authorityStreamID,
                  let credentialValue = values.authorityCredentialRevision,
                  let capabilityValue = values.authorityCapabilityRevision,
                  let accountID = AccountID(rawValue: accountValue),
                  let organizationID = OrganizationID(rawValue: organizationValue),
                  let feature = CoverageFeature(rawValue: featureValue),
                  let streamID = SyncStreamID(rawValue: streamValue),
                  let credentialRevision = CredentialRevision(rawValue: credentialValue),
                  let capabilityRevision = CapabilityRevision(rawValue: capabilityValue)
            else { return nil }
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
            guard let accountValue = values.authorityAccountID,
                  let organizationValue = values.authorityOrganizationID,
                  let accountID = AccountID(rawValue: accountValue),
                  let organizationID = OrganizationID(rawValue: organizationValue)
            else { return nil }
            return .localWorkflow(accountID: accountID, organizationID: organizationID)
        case "legacyUnverified":
            return .legacyUnverified
        default:
            return nil
        }
    }

    private nonisolated static func isValidRelationEvidence(
        source: EvidenceSource,
        locator: EvidenceLocator,
        authority: EvidenceAuthority
    ) -> Bool {
        switch (source, locator, authority) {
        case (.localWorkflow, .localWorkflow, .localWorkflow):
            true
        case (.localWorkflow, _, _):
            false
        case (.legacyUnverified, .legacyUnverified, .legacyUnverified):
            true
        case (.legacyUnverified, _, _):
            false
        case (_, .endpoint, .github), (_, .query, .github):
            true
        case (_, .legacyUnverified, .legacyUnverified):
            true
        default:
            false
        }
    }

    private nonisolated static func isAuthorizedForPresentation(
        _ evidence: EvidenceReference,
        scope: SynchronizationScope?
    ) -> Bool {
        guard let scope else { return true }
        return switch evidence.authority {
        case let .github(evidenceScope, _, _):
            evidenceScope == scope
        case let .localWorkflow(accountID, organizationID):
            accountID == scope.accountID && organizationID == scope.organizationID
        case .legacyUnverified:
            false
        }
    }

    /// Active-scope rule publication is stricter than historical rendering:
    /// every proof must be confirmed and a GitHub proof must name a currently
    /// normalized node with the same source revision.  Historical callers do
    /// not use this predicate and retain migration readability.
    private static let currentRuleEvidencePredicate = """
        (
            (
                rule_evaluation_evidence.authority_kind = 'github'
                AND rule_evaluation_evidence.authority_account_id = rule_evaluations.account_id
                AND rule_evaluation_evidence.authority_organization_id = rule_evaluations.organization_id
                AND rule_evaluation_evidence.authority_credential_revision = rule_evaluations.credential_revision
                AND rule_evaluation_evidence.authority_capability_revision = rule_evaluations.capability_revision
                AND rule_evaluation_evidence.confidence = 'confirmed'
                AND rule_evaluation_evidence.confirmation = 'confirmed'
                AND EXISTS (
                    SELECT 1
                    FROM github_nodes AS evidence_nodes
                    WHERE evidence_nodes.github_node_id = rule_evaluation_evidence.source_node_id
                      AND evidence_nodes.account_id = rule_evaluations.account_id
                      AND evidence_nodes.organization_id = rule_evaluations.organization_id
                      AND evidence_nodes.source_revision = rule_evaluation_evidence.source_revision
                )
            ) OR (
                rule_evaluation_evidence.authority_kind = 'localWorkflow'
                AND rule_evaluation_evidence.authority_account_id = rule_evaluations.account_id
                AND rule_evaluation_evidence.authority_organization_id = rule_evaluations.organization_id
                AND rule_evaluation_evidence.confidence = 'confirmed'
                AND rule_evaluation_evidence.confirmation = 'confirmed'
            )
        )
        """

    private nonisolated static func currentDerivedSourceRevision(
        for scope: SynchronizationScope,
        in database: Database
    ) throws -> String {
        do {
            return try DerivedIntelligenceRepository.currentSourceRevision(scope: scope, in: database)
        } catch {
            throw WorkItemRepositoryError.invalidPersistedData
        }
    }

        private nonisolated static func content(
            in database: Database,
            nodeIDs: Set<GitHubNodeID>,
            authorityScope: SynchronizationScope?,
            onQuery: (@Sendable () -> Void)?
        ) throws -> [GitHubNodeID: GitHubContentSummary] {
            guard !nodeIDs.isEmpty else { return [:] }
            var result: [GitHubNodeID: GitHubContentSummary] = [:]
            for batch in batches(nodeIDs.map(\.rawValue).sorted()) {
                try Task.checkCancellation()
                onQuery?()
                let scopeFilter: String
                let arguments: StatementArguments
                if let authorityScope {
                    scopeFilter = "AND github_nodes.account_id = ? AND github_nodes.organization_id = ?"
                    arguments = StatementArguments(
                        batch + [authorityScope.accountID.rawValue, authorityScope.organizationID.rawValue]
                    )
                } else {
                    scopeFilter = ""
                    arguments = StatementArguments(batch)
                }
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT
                            github_nodes.github_node_id, github_nodes.kind, github_nodes.number,
                            github_nodes.title, github_nodes.state, github_nodes.html_url,
                            github_nodes.created_at_ms, github_nodes.updated_at_ms,
                            github_nodes.closed_at_ms, github_nodes.merged_at_ms,
                            github_nodes.repository_id,
                            repositories.github_node_id AS repository_node_id,
                            repositories.owner_login AS repository_owner_login,
                            repositories.name AS repository_name,
                            repositories.is_private AS repository_is_private,
                            repositories.is_archived AS repository_is_archived,
                            repositories.has_discussions AS repository_has_discussions,
                            repositories.has_discussions_known AS repository_has_discussions_known,
                            repositories.html_url AS repository_html_url,
                            actors.id AS actor_id, actors.github_node_id AS actor_node_id,
                            actors.login AS actor_login, actors.display_name AS actor_display_name,
                            actors.avatar_url AS actor_avatar_url
                        FROM github_nodes
                        LEFT JOIN repositories ON repositories.id = github_nodes.repository_id
                        LEFT JOIN actors ON actors.id = github_nodes.author_id
                        WHERE github_nodes.github_node_id IN (\(placeholders(for: batch)))
                        \(scopeFilter)
                        """,
                    arguments: arguments
                )
                for row in rows {
                    guard let nodeID = GitHubNodeID(rawValue: row["github_node_id"]) else {
                        throw WorkItemRepositoryError.invalidPersistedData
                    }
                    result[nodeID] = try content(from: row, nodeID: nodeID)
                }
            }
            return result
        }

        private nonisolated static func content(
            from row: Row,
            nodeID: GitHubNodeID
        ) throws -> GitHubContentSummary {
            guard let kind = GitHubContentKind(rawValue: row["kind"]),
                  let state = GitHubItemState(rawValue: row["state"]),
                  let url = URL(string: row["html_url"]),
                  let createdAt = date(milliseconds: row["created_at_ms"]),
                  let updatedAt = date(milliseconds: row["updated_at_ms"])
            else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            return GitHubContentSummary(
                id: nodeID,
                kind: kind,
                repository: try repository(from: row),
                number: row["number"],
                title: row["title"],
                state: state,
                author: try actor(from: row),
                url: url,
                createdAt: createdAt,
                updatedAt: updatedAt,
                closedAt: date(milliseconds: row["closed_at_ms"]),
                mergedAt: date(milliseconds: row["merged_at_ms"])
            )
        }

        private nonisolated static func actor(from row: Row) throws -> ActorSummary? {
            guard let rawID: String = row["actor_id"] else {
                return nil
            }
            guard let id = ActorID(rawValue: rawID),
                  let rawNodeID: String = row["actor_node_id"],
                  let nodeID = GitHubNodeID(rawValue: rawNodeID)
            else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            let avatarURL = (row["actor_avatar_url"] as String?).flatMap(URL.init(string:))
            return ActorSummary(
                id: id,
                nodeID: nodeID,
                login: row["actor_login"],
                displayName: row["actor_display_name"],
                avatarURL: avatarURL
            )
        }
    }
