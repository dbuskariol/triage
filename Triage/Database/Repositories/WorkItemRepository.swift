import Foundation
import GRDB

enum WorkItemRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
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
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            return try Row.fetchAll(
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
                    LEFT JOIN repositories ON repositories.id = github_nodes.repository_id
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
                let members = try Self.members(in: database, workItemID: row["id"])
                let contextLinks = try Self.contextLinks(in: database, workItemID: row["id"])
                let relations = try Self.relations(
                    in: database,
                    accountID: accountID,
                    workItemID: row["id"]
                )
                return try Self.workItem(
                    from: row,
                    accountID: accountID,
                    organizationID: organizationID,
                    attentionReasons: reasons,
                    actionItems: actions,
                    members: members,
                    contextLinks: contextLinks,
                    relations: relations
                )
            }
    }
    }

    func ensureWorkItem(for node: NormalizedGitHubNode) async throws -> WorkItemID {
        try ensureAccountScope(node.accountID)
        return try await vault.write { database in
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

    private func ensureAccountScope(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw WorkItemRepositoryError.accountScopeMismatch
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
        relations: [WorkRelation]
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
            freshness: FreshnessState(status: .fresh),
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
            url: url
        )
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

        private nonisolated static func members(
            in database: Database,
            workItemID: String
        ) throws -> [WorkItemMember] {
            try Row.fetchAll(
                database,
                sql: """
                    SELECT work_item_members.github_node_id, work_item_members.role
                    FROM work_item_members
                    WHERE work_item_members.work_item_id = ?
                    ORDER BY work_item_members.role, work_item_members.github_node_id
                    """,
                arguments: [workItemID]
            ).map { row in
                guard let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let role = WorkItemMemberRole(rawValue: row["role"])
                else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                return WorkItemMember(
                    id: nodeID,
                    role: role,
                    content: try content(in: database, nodeID: nodeID),
                    evidence: []
                )
            }
        }

        private nonisolated static func contextLinks(
            in database: Database,
            workItemID: String
        ) throws -> [WorkItemContextLink] {
            try Row.fetchAll(
                database,
                sql: """
                    SELECT github_node_id, relation
                    FROM work_item_context_links
                    WHERE work_item_id = ?
                    ORDER BY relation, github_node_id
                    """,
                arguments: [workItemID]
            ).map { row in
                guard let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let relation = WorkRelationKind(rawValue: row["relation"])
                else {
                    throw WorkItemRepositoryError.invalidPersistedData
                }
                return WorkItemContextLink(
                    id: nodeID,
                    relation: relation,
                    content: try content(in: database, nodeID: nodeID),
                    evidence: []
                )
            }
        }

    private nonisolated static func relations(
        in database: Database,
        accountID: AccountID,
        workItemID: String
    ) throws -> [WorkRelation] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT relations.id, relations.subject_node_id, relations.object_node_id,
                       relations.kind, relations.confidence, relations.observed_at_ms
                FROM relations
                JOIN work_item_members
                    ON work_item_members.github_node_id = relations.subject_node_id
                WHERE relations.account_id = ? AND work_item_members.work_item_id = ?
                ORDER BY relations.subject_node_id, relations.kind, relations.object_node_id, relations.id
                """,
            arguments: [accountID.rawValue, workItemID]
        ).map { row in
            guard let subjectNodeID = GitHubNodeID(rawValue: row["subject_node_id"]),
                  let kind = WorkRelationKind(rawValue: row["kind"]),
                  let confidence = RelationConfidence(rawValue: row["confidence"]),
                  let observedAt = date(milliseconds: row["observed_at_ms"])
            else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
            let relationID: String = row["id"]
            return WorkRelation(
                kind: kind,
                subjectNodeID: subjectNodeID,
                objectNodeID: (row["object_node_id"] as String?).flatMap(GitHubNodeID.init(rawValue:)),
                confidence: confidence,
                evidence: try relationEvidence(in: database, relationID: relationID),
                observedAt: observedAt
            )
        }
    }

    private nonisolated static func relationEvidence(
        in database: Database,
        relationID: String
    ) throws -> [EvidenceReference] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT evidence_id, source, source_node_id, source_event_id,
                       source_revision, observed_at_ms, excerpt
                FROM relation_evidence
                WHERE relation_id = ?
                ORDER BY evidence_id
                """,
            arguments: [relationID]
        ).map { row in
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

        private nonisolated static func content(
            in database: Database,
            nodeID: GitHubNodeID
        ) throws -> GitHubContentSummary {
            guard let row = try Row.fetchOne(
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
                        repositories.html_url AS repository_html_url,
                        actors.id AS actor_id, actors.github_node_id AS actor_node_id,
                        actors.login AS actor_login, actors.display_name AS actor_display_name,
                        actors.avatar_url AS actor_avatar_url
                    FROM github_nodes
                    LEFT JOIN repositories ON repositories.id = github_nodes.repository_id
                    LEFT JOIN actors ON actors.id = github_nodes.author_id
                    WHERE github_nodes.github_node_id = ?
                    """,
                arguments: [nodeID.rawValue]
            ) else {
                throw WorkItemRepositoryError.invalidPersistedData
            }
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
