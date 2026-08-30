import Foundation
import GRDB

enum ProjectV2RepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case projectScopeMismatch
}

actor ProjectV2Repository {
    private let vault: AccountVault
    init(vault: AccountVault) { self.vault = vault }

    func replaceProjects(
        _ projects: [GitHubProjectV2Record], rawPages: [GitHubProjectV2RawPage],
        accountID: AccountID, organization: GitHubOrganization, observedAt: Date, parserVersion: Int = 1
    ) async throws {
        guard accountID == vault.accountID else { throw ProjectV2RepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateOrganization(accountID: accountID, organization: organization, in: database)
            try Self.saveRaw(rawPages, accountID: accountID, observedAt: observedAt, parserVersion: parserVersion, in: database)
            guard Set(projects.map(\.nodeID)).count == projects.count else { throw GitHubProjectV2NormalizationError.duplicateProjectID }
            for project in projects {
                try GitHubNodeRepository.save(.init(nodeID: project.nodeID, accountID: accountID, organizationID: organization.id,
                    repositoryID: nil, kind: .project, numericID: nil, number: project.number, title: project.title,
                    state: project.state, url: project.url, bodyMarkdown: project.description, authorID: nil,
                    createdAt: project.updatedAt, updatedAt: project.updatedAt, closedAt: project.state == .closed ? project.updatedAt : nil,
                    mergedAt: nil, sourceRevision: project.updatedAt.ISO8601Format(), observedAt: observedAt, accessibility: .accessible), in: database)
                try database.execute(sql: """
                    INSERT INTO projects (github_node_id, organization_id, number, title, state, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(github_node_id) DO UPDATE SET organization_id = excluded.organization_id, number = excluded.number,
                      title = excluded.title, state = excluded.state, updated_at_ms = excluded.updated_at_ms
                    """, arguments: [project.nodeID.rawValue, organization.id.rawValue, project.number, project.title,
                                     project.state.rawValue, Self.milliseconds(project.updatedAt)])
            }
            try Self.deleteAbsentProjects(projects.map(\.nodeID), accountID: accountID, organizationID: organization.id, in: database)
        }
    }

    func replaceItems(
        _ items: [GitHubProjectV2ItemRecord], project: GitHubProjectV2Record, rawPages: [GitHubProjectV2RawPage],
        accountID: AccountID, organization: GitHubOrganization, observedAt: Date, parserVersion: Int = 1
    ) async throws {
        guard accountID == vault.accountID else { throw ProjectV2RepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateOrganization(accountID: accountID, organization: organization, in: database)
            let projectCount = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM projects JOIN github_nodes ON github_nodes.github_node_id = projects.github_node_id
                WHERE projects.github_node_id = ? AND projects.organization_id = ? AND github_nodes.account_id = ?
                """, arguments: [project.nodeID.rawValue, organization.id.rawValue, accountID.rawValue]) ?? 0
            guard projectCount == 1 else { throw ProjectV2RepositoryError.projectScopeMismatch }
            guard items.allSatisfy({ $0.projectNodeID == project.nodeID }),
                  Set(items.map(\.nodeID)).count == items.count else { throw GitHubProjectV2NormalizationError.duplicateItemID }
            try Self.saveRaw(rawPages, accountID: accountID, observedAt: observedAt, parserVersion: parserVersion, in: database)
            for item in items {
                // ProjectV2Item has no source URL; its project URL is retained with an immutable item fragment.
                let itemURL = URL(string: project.url.absoluteString + "#item-\(item.nodeID.rawValue)")!
                try GitHubNodeRepository.save(.init(nodeID: item.nodeID, accountID: accountID, organizationID: organization.id,
                    repositoryID: nil, kind: .projectItem, numericID: nil, number: nil, title: item.nodeID.rawValue,
                    state: .unknown, url: itemURL, bodyMarkdown: nil, authorID: nil, createdAt: item.updatedAt,
                    updatedAt: item.updatedAt, closedAt: nil, mergedAt: nil, sourceRevision: item.updatedAt.ISO8601Format(),
                    observedAt: observedAt, accessibility: .accessible), in: database)
                try database.execute(sql: """
                    INSERT INTO project_items (
                      github_node_id, project_node_id, content_node_id, content_node_reference, content_kind, updated_at_ms
                    ) VALUES (?, ?, NULL, ?, ?, ?)
                    ON CONFLICT(github_node_id) DO UPDATE SET project_node_id = excluded.project_node_id,
                      content_node_id = NULL, content_node_reference = excluded.content_node_reference,
                      content_kind = excluded.content_kind, updated_at_ms = excluded.updated_at_ms
                    """, arguments: [item.nodeID.rawValue, item.projectNodeID.rawValue, item.contentNodeID?.rawValue,
                                     item.contentKind?.rawValue, Self.milliseconds(item.updatedAt)])
                if item.fieldValuesComplete {
                    try database.execute(sql: "DELETE FROM project_field_values WHERE project_item_node_id = ?", arguments: [item.nodeID.rawValue])
                    for field in item.fieldValues {
                        try database.execute(sql: """
                            INSERT INTO project_field_values (
                              project_item_node_id, field_name, display_value, date_value_ms, actor_node_id, value_kind, context
                            ) VALUES (?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [item.nodeID.rawValue, field.fieldName, field.displayValue,
                                             field.dateValue.map(Self.milliseconds), field.actorNodeID?.rawValue, field.valueKind, field.context])
                    }
                }
            }
            try Self.deleteAbsentItems(items.map(\.nodeID), accountID: accountID, projectID: project.nodeID, in: database)
        }
    }

    func recordFailedPage(_ page: GitHubProjectV2RawPage, accountID: AccountID, observedAt: Date, diagnostic: String, parserVersion: Int = 1) async throws {
        guard accountID == vault.accountID else { throw ProjectV2RepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            let snapshot = RawAPISnapshot(id: .make(), accountID: accountID, githubNodeID: nil, endpoint: page.endpoint,
                                          eTag: nil, parserVersion: parserVersion, observedAt: observedAt, payload: page.payload)
            try RawAPISnapshotRepository.save(snapshot, in: database)
            try NormalizationFailureRepository.record(.init(id: UUID(), accountID: accountID, rawSnapshotID: snapshot.id,
                githubNodeID: nil, endpoint: page.endpoint, parserVersion: parserVersion, occurredAt: observedAt,
                redactedDiagnostic: String(diagnostic.prefix(4_096))), in: database)
        }
    }

    private nonisolated static func saveRaw(_ pages: [GitHubProjectV2RawPage], accountID: AccountID, observedAt: Date, parserVersion: Int, in database: Database) throws {
        for page in pages {
            try RawAPISnapshotRepository.save(.init(id: .make(), accountID: accountID, githubNodeID: nil, endpoint: page.endpoint,
                eTag: nil, parserVersion: parserVersion, observedAt: observedAt, payload: page.payload), in: database)
        }
    }

    private nonisolated static func validateOrganization(accountID: AccountID, organization: GitHubOrganization, in database: Database) throws {
        let count = try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM account_organizations JOIN organizations ON organizations.id = account_organizations.organization_id
            WHERE account_organizations.account_id = ? AND organizations.id = ? AND organizations.github_organization_id = ?
              AND lower(organizations.login) = lower(?)
            """, arguments: [accountID.rawValue, organization.id.rawValue, String(organization.githubOrganizationID), organization.login]) ?? 0
        guard count == 1 else { throw ProjectV2RepositoryError.organizationScopeMismatch }
    }

    private nonisolated static func deleteAbsentProjects(_ ids: [GitHubNodeID], accountID: AccountID, organizationID: OrganizationID, in database: Database) throws {
        try deleteAbsent(ids, sql: "DELETE FROM github_nodes WHERE account_id = ? AND organization_id = ? AND kind = ?",
                         arguments: [accountID.rawValue, organizationID.rawValue, GitHubContentKind.project.rawValue], in: database)
    }
    private nonisolated static func deleteAbsentItems(_ ids: [GitHubNodeID], accountID: AccountID, projectID: GitHubNodeID, in database: Database) throws {
        try deleteAbsent(ids, sql: "DELETE FROM github_nodes WHERE account_id = ? AND kind = ? AND github_node_id IN (SELECT github_node_id FROM project_items WHERE project_node_id = ?)",
                         arguments: [accountID.rawValue, GitHubContentKind.projectItem.rawValue, projectID.rawValue], in: database)
    }
    private nonisolated static func deleteAbsent(_ ids: [GitHubNodeID], sql: String, arguments: [DatabaseValueConvertible?], in database: Database) throws {
        guard !ids.isEmpty else { try database.execute(sql: sql, arguments: StatementArguments(arguments)); return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try database.execute(sql: sql + " AND github_node_id NOT IN (\(placeholders))",
            arguments: StatementArguments(arguments + ids.map(\.rawValue)))
    }
    private nonisolated static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
}
