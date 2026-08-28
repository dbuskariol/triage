import Foundation
import GRDB

enum GitHubNodeDetailsRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case nodeScopeMismatch
    case nodeKindMismatch
}

actor GitHubNodeDetailsRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ hydratedNode: HydratedGitHubNode, accountID: AccountID, observedAt: Date) async throws {
        guard accountID == vault.accountID, hydratedNode.node.accountID == vault.accountID else {
            throw GitHubNodeDetailsRepositoryError.accountScopeMismatch
        }
        let observedAtMilliseconds = Self.milliseconds(observedAt)
        try await vault.write { database in
            let detailsKind: GitHubContentKind = switch hydratedNode.details {
            case .issue: .issue
            case .pullRequest: .pullRequest
            }
            guard detailsKind == hydratedNode.node.kind else {
                throw GitHubNodeDetailsRepositoryError.nodeKindMismatch
            }
            let existingKind: String? = try String.fetchOne(
                database,
                sql: "SELECT kind FROM github_nodes WHERE github_node_id = ? AND account_id = ?",
                arguments: [hydratedNode.node.nodeID.rawValue, accountID.rawValue]
            )
            guard existingKind == nil || existingKind == hydratedNode.node.kind.rawValue else {
                throw GitHubNodeDetailsRepositoryError.nodeKindMismatch
            }
            try GitHubNodeRepository.save(hydratedNode.node, in: database)

            switch hydratedNode.details {
            case let .issue(isLocked, commentsCount, assigneeNodeIDs, labelNodeIDs, labelNames):
                try database.execute(
                    sql: """
                        INSERT INTO issues (
                            github_node_id, locked, comments_count, assignee_node_ids_json,
                            label_node_ids_json, label_names_json, milestone_node_id, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
                        ON CONFLICT(github_node_id) DO UPDATE SET
                            locked = excluded.locked,
                            comments_count = excluded.comments_count,
                            assignee_node_ids_json = excluded.assignee_node_ids_json,
                            label_node_ids_json = excluded.label_node_ids_json,
                            label_names_json = excluded.label_names_json,
                            updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [
                        hydratedNode.node.nodeID.rawValue,
                        isLocked,
                        commentsCount,
                        try JSONEncoder().encode(assigneeNodeIDs.map(\.rawValue)),
                        try JSONEncoder().encode(labelNodeIDs.map(\.rawValue)),
                        try JSONEncoder().encode(labelNames),
                        observedAtMilliseconds
                    ]
                )
            case let .pullRequest(
                isDraft,
                mergeableState,
                headRef,
                baseRef,
                reviewDecision,
                assigneeNodeIDs,
                labelNodeIDs,
                labelNames
            ):
                try database.execute(
                    sql: """
                        INSERT INTO pull_requests (
                            github_node_id, is_draft, mergeable_state, head_ref, base_ref,
                            review_decision, assignee_node_ids_json, label_node_ids_json,
                            label_names_json, unresolved_thread_count, latest_commit_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?)
                        ON CONFLICT(github_node_id) DO UPDATE SET
                            is_draft = excluded.is_draft,
                            mergeable_state = excluded.mergeable_state,
                            head_ref = excluded.head_ref,
                            base_ref = excluded.base_ref,
                            review_decision = excluded.review_decision,
                            assignee_node_ids_json = excluded.assignee_node_ids_json,
                            label_node_ids_json = excluded.label_node_ids_json,
                            label_names_json = excluded.label_names_json,
                            updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [
                        hydratedNode.node.nodeID.rawValue,
                        isDraft,
                        mergeableState,
                        headRef,
                        baseRef,
                        reviewDecision,
                        try JSONEncoder().encode(assigneeNodeIDs.map(\.rawValue)),
                        try JSONEncoder().encode(labelNodeIDs.map(\.rawValue)),
                        try JSONEncoder().encode(labelNames),
                        observedAtMilliseconds
                    ]
                )
            }
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
