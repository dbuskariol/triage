import Foundation
import GRDB

enum WorkItemRepositoryError: Error, Equatable, Sendable {
    case invalidPersistedData
}

actor WorkItemRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func fetch(
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> [WorkItem] {
        try await vault.read { database in
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        work_items.id, work_items.primary_node_id, work_items.state,
                        work_items.last_relevant_activity_at_ms,
                        github_nodes.kind, github_nodes.title, github_nodes.html_url,
                        github_nodes.repository_id,
                        workflow_states.status AS workflow_status,
                        workflow_states.pinned AS workflow_pinned,
                        workflow_states.priority AS workflow_priority,
                        workflow_states.snoozed_until_ms,
                        workflow_states.follow_up_at_ms,
                        workflow_states.local_note,
                        workflow_states.updated_at_ms AS workflow_updated_at_ms,
                        attention_scores.score
                    FROM work_items
                    JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                    LEFT JOIN workflow_states ON workflow_states.work_item_id = work_items.id
                    LEFT JOIN attention_scores ON attention_scores.work_item_id = work_items.id
                    WHERE work_items.account_id = ? AND work_items.organization_id = ?
                    ORDER BY work_items.last_relevant_activity_at_ms DESC, work_items.id
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            ).map { row in
                let reasons = try Self.attentionReasons(
                    in: database,
                    workItemID: row["id"]
                )
                let actions = try Self.actionItems(in: database, workItemID: row["id"])
                return try Self.workItem(
                    from: row,
                    accountID: accountID,
                    organizationID: organizationID,
                    attentionReasons: reasons,
                    actionItems: actions
                )
            }
        }
    }

    func ensureWorkItem(for node: NormalizedGitHubNode) async throws -> WorkItemID {
        try await vault.write { database in
            if let existingID: String = try String.fetchOne(
                database,
                sql: """
                    SELECT id FROM work_items
                    WHERE account_id = ? AND primary_node_id = ?
                    """,
                arguments: [node.accountID.rawValue, node.nodeID.rawValue]
            ) {
                try database.execute(
                    sql: """
                        UPDATE work_items
                        SET state = ?, last_relevant_activity_at_ms = ?, updated_at_ms = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        node.state == .open || node.state == .draft ? WorkItemState.active.rawValue : WorkItemState.resolved.rawValue,
                        Self.milliseconds(node.updatedAt),
                        Self.milliseconds(node.observedAt),
                        existingID
                    ]
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
    }

    private nonisolated static func workItem(
        from row: Row,
        accountID: AccountID,
        organizationID: OrganizationID,
        attentionReasons: [AttentionReason],
        actionItems: [ActionItem]
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
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: attentionReasons,
            actionItems: actionItems,
            workflow: workflow,
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: activity,
            score: AttentionScore(value: row["score"] ?? 0, breakdown: [:])
        )
    }

    private nonisolated static func date(milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func attentionReasons(
        in database: Database,
        workItemID: String
    ) throws -> [AttentionReason] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT id, rule_id, rule_version, category, strength, title, explanation, evaluated_at_ms
                FROM attention_reasons
                WHERE work_item_id = ?
                ORDER BY strength DESC, id
                """,
            arguments: [workItemID]
        ).map { row in
            guard let category = AttentionCategory(rawValue: row["category"]),
                  let evaluatedAt = date(milliseconds: row["evaluated_at_ms"])
            else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            let reasonID: String = row["id"]
            return AttentionReason(
                id: reasonID,
                category: category,
                ruleID: row["rule_id"],
                ruleVersion: row["rule_version"],
                strength: row["strength"],
                title: row["title"],
                explanation: row["explanation"],
                evidence: try evidence(in: database, reasonID: reasonID),
                evaluatedAt: evaluatedAt
            )
        }
    }

    private nonisolated static func evidence(
        in database: Database,
        reasonID: String
    ) throws -> [EvidenceReference] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT evidence_id, source, source_node_id, source_event_id, source_revision, observed_at_ms, excerpt
                FROM attention_reason_evidence
                WHERE attention_reason_id = ?
                ORDER BY evidence_id
                """,
            arguments: [reasonID]
        ).compactMap { row in
            guard let id = EvidenceID(rawValue: row["evidence_id"]),
                  let source = EvidenceSource(rawValue: row["source"]),
                  let observedAt = date(milliseconds: row["observed_at_ms"])
            else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            return EvidenceReference(
                id: id,
                source: source,
                nodeID: (row["source_node_id"] as String?).flatMap(GitHubNodeID.init(rawValue:)),
                eventID: (row["source_event_id"] as String?).flatMap(GitHubEventID.init(rawValue:)),
                sourceRevision: row["source_revision"],
                observedAt: observedAt,
                excerpt: row["excerpt"]
            )
        }
    }

    private nonisolated static func actionItems(
            in database: Database,
            workItemID: String
        ) throws -> [ActionItem] {
            guard let typedWorkItemID = WorkItemID(rawValue: workItemID) else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT id, title, detail, origin, state, priority, due_at_ms, source_fingerprint,
                           created_at_ms, updated_at_ms, completed_at_ms, dismissed_at_ms
                    FROM action_items
                    WHERE work_item_id = ?
                    ORDER BY state, due_at_ms, id
                    """,
                arguments: [workItemID]
            ).map { row in
                guard let id = ActionItemID(rawValue: row["id"]),
                      let origin = ActionItemOrigin(rawValue: row["origin"]),
                      let state = ActionItemState(rawValue: row["state"]),
                      let priority = WorkPriority(rawValue: row["priority"]),
                      let createdAt = date(milliseconds: row["created_at_ms"]),
                      let updatedAt = date(milliseconds: row["updated_at_ms"])
                else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                let evidenceIDs = try String.fetchAll(
                    database,
                    sql: "SELECT evidence_id FROM action_item_evidence WHERE action_item_id = ? ORDER BY evidence_id",
                    arguments: [id.rawValue]
                ).compactMap(EvidenceID.init(rawValue:))
                return ActionItem(
                    id: id,
                    workItemID: typedWorkItemID,
                    title: row["title"],
                    detail: row["detail"],
                    origin: origin,
                    state: state,
                    priority: priority,
                    dueAt: date(milliseconds: row["due_at_ms"]),
                    evidenceIDs: evidenceIDs,
                    sourceFingerprint: row["source_fingerprint"],
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    completedAt: date(milliseconds: row["completed_at_ms"]),
                    dismissedAt: date(milliseconds: row["dismissed_at_ms"])
                )
        }
    }
}
