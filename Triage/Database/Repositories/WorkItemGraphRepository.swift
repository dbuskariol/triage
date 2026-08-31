import Foundation
import GRDB

enum WorkItemGraphRepositoryError: Error, Equatable, Sendable {
    case duplicateMember
    case duplicateContextLink
    case invalidMemberRole
    case invalidContextRelation
    case workItemScopeMismatch
    case nodeScopeMismatch
}

struct WorkItemMemberReference: Equatable, Sendable {
    let nodeID: GitHubNodeID
    let role: WorkItemMemberRole
}

struct WorkItemContextReference: Equatable, Sendable {
    let nodeID: GitHubNodeID
    let relation: WorkRelationKind
}

actor WorkItemGraphRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    /// Replaces the complete grouping projection in one transaction so removed
    /// relationships cannot remain visible after a subsequent synchronization.
    func replace(
        workItemID: WorkItemID,
        members: [WorkItemMemberReference],
        contextLinks: [WorkItemContextReference]
    ) async throws {
        guard Set(members.map(\.nodeID)).count == members.count else {
            throw WorkItemGraphRepositoryError.duplicateMember
        }
        guard Set(contextLinks.map { "\($0.nodeID.rawValue)\u{0}\($0.relation.rawValue)" }).count
            == contextLinks.count
        else {
            throw WorkItemGraphRepositoryError.duplicateContextLink
        }

        try await vault.write { database in
            try Self.replace(
                workItemID: workItemID,
                members: members,
                contextLinks: contextLinks,
                vault: vault,
                in: database
            )
        }
    }

    /// Shares the exact replacement contract with the normalized-refresh graph
    /// projection, which must update member/context rows in the same
    /// transaction as a deterministic work-item merge.
    nonisolated static func replace(
        workItemID: WorkItemID,
        members: [WorkItemMemberReference],
        contextLinks: [WorkItemContextReference],
        vault: AccountVault,
        in database: Database
    ) throws {
        guard Set(members.map(\.nodeID)).count == members.count else {
            throw WorkItemGraphRepositoryError.duplicateMember
        }
        guard Set(contextLinks.map { "\($0.nodeID.rawValue)\u{0}\($0.relation.rawValue)" }).count
            == contextLinks.count
        else {
            throw WorkItemGraphRepositoryError.duplicateContextLink
        }
        try validateWorkItemScope(workItemID, vault: vault, in: database)
        try validateNodeScope(
            Set(members.map(\.nodeID) + contextLinks.map(\.nodeID)),
            vault: vault,
            in: database
        )
        try database.execute(
            sql: "DELETE FROM work_item_members WHERE work_item_id = ?",
            arguments: [workItemID.rawValue]
        )
        for member in members {
            try database.execute(
                sql: """
                    INSERT INTO work_item_members (work_item_id, github_node_id, role)
                    VALUES (?, ?, ?)
                    """,
                arguments: [workItemID.rawValue, member.nodeID.rawValue, member.role.rawValue]
            )
        }
        try database.execute(
            sql: "DELETE FROM work_item_context_links WHERE work_item_id = ?",
            arguments: [workItemID.rawValue]
        )
        for contextLink in contextLinks {
            try database.execute(
                sql: """
                    INSERT INTO work_item_context_links (work_item_id, github_node_id, relation)
                    VALUES (?, ?, ?)
                    """,
                arguments: [workItemID.rawValue, contextLink.nodeID.rawValue, contextLink.relation.rawValue]
            )
        }
    }

    private nonisolated static func validateWorkItemScope(
        _ workItemID: WorkItemID,
        vault: AccountVault,
        in database: Database
    ) throws {
        let matchingCount = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM work_items WHERE id = ? AND account_id = ?",
            arguments: [workItemID.rawValue, vault.accountID.rawValue]
        ) ?? 0
        guard matchingCount == 1 else {
            throw WorkItemGraphRepositoryError.workItemScopeMismatch
        }
    }

    private nonisolated static func validateNodeScope(
        _ nodeIDs: Set<GitHubNodeID>,
        vault: AccountVault,
        in database: Database
    ) throws {
        guard !nodeIDs.isEmpty else {
            return
        }
        let placeholders = Array(repeating: "?", count: nodeIDs.count).joined(separator: ", ")
        let arguments = StatementArguments(
            [vault.accountID.rawValue] + nodeIDs.map(\.rawValue).sorted()
        )
        let matchingCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM github_nodes
                WHERE account_id = ? AND github_node_id IN (\(placeholders))
                """,
            arguments: arguments
        ) ?? 0
        guard matchingCount == nodeIDs.count else {
            throw WorkItemGraphRepositoryError.nodeScopeMismatch
        }
    }
}
