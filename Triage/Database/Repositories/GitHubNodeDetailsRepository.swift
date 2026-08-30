import Foundation
import GRDB

enum GitHubNodeDetailsRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case nodeScopeMismatch
    case nodeKindMismatch
    case invalidHydrationCandidate
}

struct GitHubHydrationCandidate: Equatable, Sendable {
    let nodeID: GitHubNodeID
    let repositoryID: RepositoryID
    let kind: GitHubContentKind
}

actor GitHubNodeDetailsRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ hydratedNode: HydratedGitHubNode, accountID: AccountID, observedAt: Date) async throws {
        guard accountID == vault.accountID else {
            throw GitHubNodeDetailsRepositoryError.accountScopeMismatch
        }
        try await vault.write { database in
            try Self.save(
                hydratedNode,
                accountID: accountID,
                observedAtMilliseconds: Self.milliseconds(observedAt),
                in: database
            )
        }
    }

    func writeTransaction<Value: Sendable>(
        accountID: AccountID,
        _ operation: @Sendable (Database) throws -> Value
    ) async throws -> Value {
        guard accountID == vault.accountID else {
            throw GitHubNodeDetailsRepositoryError.accountScopeMismatch
        }
        return try await vault.writeTransaction(operation)
    }

    func hydrationCandidates(
        nodeIDs: Set<GitHubNodeID>,
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> [GitHubHydrationCandidate] {
        guard accountID == vault.accountID else {
            throw GitHubNodeDetailsRepositoryError.accountScopeMismatch
        }
        guard !nodeIDs.isEmpty else { return [] }
        return try await vault.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT github_node_id, repository_id, kind
                    FROM github_nodes
                    WHERE account_id = ? AND organization_id = ?
                      AND github_node_id IN (\(databaseQuestionMarks(count: nodeIDs.count)))
                    ORDER BY github_node_id
                    """,
                arguments: StatementArguments(
                    [accountID.rawValue, organizationID.rawValue]
                        + nodeIDs.map(\.rawValue).sorted()
                )
            )
            let candidates = try rows.map { row -> GitHubHydrationCandidate in
                guard let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let repositoryID = RepositoryID(rawValue: row["repository_id"]),
                      let kindValue: String = row["kind"],
                      let kind = GitHubContentKind(rawValue: kindValue),
                      kind == .issue || kind == .pullRequest
                else {
                    throw GitHubNodeDetailsRepositoryError.invalidHydrationCandidate
                }
                return GitHubHydrationCandidate(
                    nodeID: nodeID,
                    repositoryID: repositoryID,
                    kind: kind
                )
            }
            guard candidates.count == nodeIDs.count,
                  Set(candidates.map(\.nodeID)) == nodeIDs
            else {
                throw GitHubNodeDetailsRepositoryError.invalidHydrationCandidate
            }
            return candidates
        }
    }

    nonisolated static func save(
        _ hydratedNode: HydratedGitHubNode,
        accountID: AccountID,
        observedAtMilliseconds: Int64,
        in database: Database
    ) throws {
        guard hydratedNode.node.accountID == accountID else {
            throw GitHubNodeDetailsRepositoryError.accountScopeMismatch
        }
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

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
