import Foundation
import GRDB

enum WorkItemGraphRepositoryError: Error, Equatable, Sendable {
    case duplicateMember
    case duplicateContextLink
    case invalidMemberRole
    case invalidContextRelation
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
                    arguments: [
                        workItemID.rawValue,
                        contextLink.nodeID.rawValue,
                        contextLink.relation.rawValue,
                    ]
                )
            }
        }
    }
}
