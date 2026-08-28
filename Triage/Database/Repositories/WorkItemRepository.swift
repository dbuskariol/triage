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
            try Row.fetchAll(
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
            ).map { try Self.workItem(from: $0, accountID: accountID, organizationID: organizationID) }
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
        organizationID: OrganizationID
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
            attentionReasons: [],
            actionItems: [],
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
}
