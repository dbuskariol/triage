import CryptoKit
import Foundation
import GRDB

enum ProjectV2RepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case projectScopeMismatch
    case staleSynchronizationScope
    case invalidRawAuthority
    case conflictingRawPage
}

actor ProjectV2Repository {
    private let vault: AccountVault
    init(vault: AccountVault) { self.vault = vault }

    func replaceProjects(
        _ projects: [GitHubProjectV2Record], rawPages: [GitHubProjectV2RawPage],
        scope: SynchronizationScope, accountID: AccountID, organization: GitHubOrganization,
        streamID: SyncStreamID, observedAt: Date, parserVersion: Int = 1,
        coverageRecords: [CoverageRecord] = []
    ) async throws {
        guard accountID == vault.accountID, scope.accountID == accountID,
              scope.organizationID == organization.id else { throw ProjectV2RepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validateOrganization(accountID: accountID, organization: organization, in: database)
            try Self.saveRaw(rawPages, scope: scope, feature: .projects, streamID: streamID,
                             sourceNodeID: organization.nodeID, accountID: accountID,
                             allowedItemNodeIDs: [],
                             requiresCompleteTraversal: coverageRecords.contains { $0.status == .complete },
                             observedAt: observedAt, parserVersion: parserVersion, in: database)
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
            // Inventory omission is not deletion authority. Preserve prior
            // projects until a dedicated authoritative tombstone contract exists.
            try Self.saveCoverage(coverageRecords, accountID: accountID, attemptedAt: observedAt, in: database)
        }
    }

    func replaceItems(
        _ items: [GitHubProjectV2ItemRecord], project: GitHubProjectV2Record, rawPages: [GitHubProjectV2RawPage],
        scope: SynchronizationScope, accountID: AccountID, organization: GitHubOrganization,
        streamID: SyncStreamID, observedAt: Date, parserVersion: Int = 1,
        coverageRecords: [CoverageRecord] = [],
        redactedItemNodeIDs: Set<GitHubNodeID> = []
    ) async throws {
        guard accountID == vault.accountID, scope.accountID == accountID,
              scope.organizationID == organization.id else { throw ProjectV2RepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validateOrganization(accountID: accountID, organization: organization, in: database)
            let projectCount = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM projects JOIN github_nodes ON github_nodes.github_node_id = projects.github_node_id
                WHERE projects.github_node_id = ? AND projects.organization_id = ? AND github_nodes.account_id = ?
                """, arguments: [project.nodeID.rawValue, organization.id.rawValue, accountID.rawValue]) ?? 0
            guard projectCount == 1 else { throw ProjectV2RepositoryError.projectScopeMismatch }
            guard items.allSatisfy({ $0.projectNodeID == project.nodeID }),
                  Set(items.map(\.nodeID)).count == items.count
            else { throw GitHubProjectV2NormalizationError.duplicateItemID }
            guard redactedItemNodeIDs.isSubset(of: Set(items.map(\.nodeID))) else {
                throw ProjectV2RepositoryError.invalidRawAuthority
            }
            try Self.saveRaw(rawPages, scope: scope, feature: .projectItems, streamID: streamID,
                             sourceNodeID: project.nodeID, accountID: accountID,
                             allowedItemNodeIDs: Set(items.map(\.nodeID)),
                             requiresCompleteTraversal: coverageRecords.contains { $0.status == .complete },
                             observedAt: observedAt, parserVersion: parserVersion, in: database)
            for item in items {
                let isRedacted = redactedItemNodeIDs.contains(item.nodeID)
                let linkedContentNodeID = isRedacted ? nil : try Self.linkedContentNodeID(
                    reference: item.contentNodeID,
                    accountID: accountID,
                    organizationID: organization.id,
                    in: database
                )
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
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(github_node_id) DO UPDATE SET project_node_id = excluded.project_node_id,
                      content_node_id = CASE WHEN ? THEN project_items.content_node_id ELSE excluded.content_node_id END,
                      content_node_reference = CASE WHEN ? THEN project_items.content_node_reference ELSE excluded.content_node_reference END,
                      content_kind = CASE WHEN ? THEN project_items.content_kind ELSE excluded.content_kind END,
                      updated_at_ms = excluded.updated_at_ms
                    """, arguments: [item.nodeID.rawValue, item.projectNodeID.rawValue, linkedContentNodeID?.rawValue,
                                     item.contentNodeID?.rawValue,
                                     item.contentKind?.rawValue, Self.milliseconds(item.updatedAt),
                                     isRedacted, isRedacted, isRedacted])
                if item.fieldValuesComplete && !isRedacted {
                    try database.execute(sql: "DELETE FROM project_field_values WHERE project_item_node_id = ?", arguments: [item.nodeID.rawValue])
                    for field in item.fieldValues {
                        try Self.insertFieldValue(field, itemNodeID: item.nodeID, context: field.context, in: database)
                    }
                } else {
                    // A partial field-value connection, or a redacted item
                    // containing an otherwise complete field connection,
                    // cannot replace the prior authoritative collection.
                    // Retain every received value as explicit provisional
                    // context, inserting only previously unseen fields and
                    // annotating an existing field without changing its
                    // authoritative value.
                    for field in item.fieldValues {
                        let provisionalContext = isRedacted
                            ? Self.redactedContext(for: field)
                            : Self.provisionalContext(for: field)
                        let existing = try Int.fetchOne(
                            database,
                            sql: """
                                SELECT COUNT(*) FROM project_field_values
                                WHERE project_item_node_id = ? AND field_name = ?
                                """,
                            arguments: [item.nodeID.rawValue, field.fieldName]
                        ) ?? 0
                        if existing == 0 {
                            try Self.insertFieldValue(
                                field,
                                itemNodeID: item.nodeID,
                                context: provisionalContext,
                                in: database
                            )
                        } else {
                            try database.execute(
                                sql: """
                                    UPDATE project_field_values
                                    SET context = CASE
                                        WHEN instr(context, ?) > 0 THEN context
                                        ELSE context || ' | ' || ?
                                    END
                                    WHERE project_item_node_id = ? AND field_name = ?
                                    """,
                                arguments: [
                                    provisionalContext, provisionalContext,
                                    item.nodeID.rawValue, field.fieldName
                                ]
                            )
                        }
                    }
                }
            }
            // A successful page collection can still omit inaccessible or
            // redacted items; omission must not physically delete cached work.
            try Self.resolveContentReferences(accountID: accountID, organizationID: organization.id, in: database)
            try Self.saveCoverage(coverageRecords, accountID: accountID, attemptedAt: observedAt, in: database)
        }
    }

    func recordFailedPage(_ page: GitHubProjectV2RawPage, scope: SynchronizationScope,
                          accountID: AccountID, organization: GitHubOrganization, feature: CoverageFeature,
                          streamID: SyncStreamID, sourceNodeID: GitHubNodeID,
                          observedAt: Date, diagnostic: String, parserVersion: Int = 1) async throws {
        try await recordFailure(
            pages: [page], scope: scope, accountID: accountID, organization: organization,
            feature: feature, streamID: streamID, sourceNodeID: sourceNodeID, observedAt: observedAt,
            diagnostic: diagnostic, parserVersion: parserVersion, coverageRecord: nil
        )
    }

    func recordFailure(
        pages: [GitHubProjectV2RawPage], scope: SynchronizationScope,
        accountID: AccountID, organization: GitHubOrganization, feature: CoverageFeature,
        streamID: SyncStreamID, sourceNodeID: GitHubNodeID, observedAt: Date,
        diagnostic: String, parserVersion: Int = 1, coverageRecord: CoverageRecord?
    ) async throws {
        guard accountID == vault.accountID, scope.accountID == accountID,
              scope.organizationID == organization.id else { throw ProjectV2RepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validateOrganization(accountID: accountID, organization: organization, in: database)
            for snapshot in try Self.preparedRaw(
                pages, scope: scope, feature: feature, streamID: streamID, sourceNodeID: sourceNodeID,
                accountID: accountID, allowedItemNodeIDs: [], requiresCompleteTraversal: false,
                observedAt: observedAt, parserVersion: parserVersion
            ) {
                try Self.save(snapshot, rejectingConflictAt: observedAt, in: database)
                try NormalizationFailureRepository.record(.init(id: UUID(), accountID: accountID, rawSnapshotID: snapshot.id,
                    githubNodeID: snapshot.githubNodeID, endpoint: snapshot.endpoint, parserVersion: parserVersion, occurredAt: observedAt,
                    redactedDiagnostic: String(diagnostic.prefix(4_096))), in: database)
            }
            if let coverageRecord {
                try Self.saveCoverage([coverageRecord], accountID: accountID, attemptedAt: observedAt, in: database)
            }
        }
    }

    func resolveContentReferences(accountID: AccountID, organizationID: OrganizationID) async throws {
        guard accountID == vault.accountID else { throw ProjectV2RepositoryError.accountScopeMismatch }
        try await vault.writeTransaction { database in
            try Self.resolveContentReferences(
                accountID: accountID,
                organizationID: organizationID,
                in: database
            )
        }
    }

    func validateCurrentScope(_ scope: SynchronizationScope) async throws {
        guard scope.accountID == vault.accountID else { throw ProjectV2RepositoryError.accountScopeMismatch }
        try await vault.read { database in try Self.validateCurrentScope(scope, in: database) }
    }

    private nonisolated static func saveRaw(
        _ pages: [GitHubProjectV2RawPage], scope: SynchronizationScope, feature: CoverageFeature,
        streamID: SyncStreamID, sourceNodeID: GitHubNodeID, accountID: AccountID,
        allowedItemNodeIDs: Set<GitHubNodeID>, requiresCompleteTraversal: Bool,
        observedAt: Date, parserVersion: Int, in database: Database
    ) throws {
        for snapshot in try preparedRaw(pages, scope: scope, feature: feature, streamID: streamID,
                                        sourceNodeID: sourceNodeID, accountID: accountID,
                                        allowedItemNodeIDs: allowedItemNodeIDs,
                                        requiresCompleteTraversal: requiresCompleteTraversal,
                                        observedAt: observedAt, parserVersion: parserVersion) {
            try save(snapshot, rejectingConflictAt: observedAt, in: database)
        }
    }

    private nonisolated static func saveCoverage(
        _ records: [CoverageRecord], accountID: AccountID, attemptedAt: Date, in database: Database
    ) throws {
        for record in records {
            try CoverageRepository.save(
                record,
                attemptedAt: attemptedAt,
                expectedAccountID: accountID,
                in: database
            )
        }
    }

    private nonisolated static func linkedContentNodeID(
        reference: GitHubNodeID?, accountID: AccountID, organizationID: OrganizationID, in database: Database
    ) throws -> GitHubNodeID? {
        guard let reference else { return nil }
        let value = try String.fetchOne(database, sql: """
            SELECT github_node_id
            FROM github_nodes
            WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
              AND kind IN (?, ?, ?)
            """, arguments: [
                reference.rawValue, accountID.rawValue, organizationID.rawValue,
                GitHubContentKind.issue.rawValue, GitHubContentKind.pullRequest.rawValue,
                GitHubContentKind.projectDraftIssue.rawValue
            ])
        return value.flatMap(GitHubNodeID.init(rawValue:))
    }

    private nonisolated static func insertFieldValue(
        _ field: GitHubProjectV2FieldValueRecord,
        itemNodeID: GitHubNodeID,
        context: String,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO project_field_values (
                  project_item_node_id, field_name, display_value, date_value_ms,
                  actor_node_id, value_kind, context
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                itemNodeID.rawValue, field.fieldName, field.displayValue,
                field.dateValue.map(milliseconds), field.actorNodeID?.rawValue,
                field.valueKind, context
            ]
        )
    }

    private nonisolated static func provisionalContext(
        for field: GitHubProjectV2FieldValueRecord
    ) -> String {
        let display = field.displayValue.map { String($0.prefix(1_024)) } ?? "none"
        return String(
            "provisional collection observation: \(field.valueKind); \(field.context); display=\(display)"
                .prefix(2_048)
        )
    }

    private nonisolated static func redactedContext(
        for field: GitHubProjectV2FieldValueRecord
    ) -> String {
        let display = field.displayValue.map { String($0.prefix(1_024)) } ?? "none"
        return String(
            "provisional redacted-item observation: \(field.valueKind); \(field.context); display=\(display)"
                .prefix(2_048)
        )
    }

    private nonisolated static func resolveContentReferences(
        accountID: AccountID, organizationID: OrganizationID, in database: Database
    ) throws {
        try database.execute(sql: """
            UPDATE project_items
            SET content_node_id = content_node_reference
            WHERE content_node_reference IS NOT NULL
              AND EXISTS (
                SELECT 1
                FROM projects
                JOIN github_nodes AS project_nodes
                  ON project_nodes.github_node_id = projects.github_node_id
                WHERE projects.github_node_id = project_items.project_node_id
                  AND projects.organization_id = ?
                  AND project_nodes.account_id = ?
                  AND project_nodes.organization_id = ?
                  AND project_nodes.kind = ?
              )
              AND EXISTS (
                SELECT 1 FROM github_nodes
                WHERE github_nodes.github_node_id = project_items.content_node_reference
                  AND github_nodes.account_id = ?
                  AND github_nodes.organization_id = ?
                  AND github_nodes.kind IN (?, ?, ?)
              )
            """, arguments: [
                organizationID.rawValue, accountID.rawValue, organizationID.rawValue,
                GitHubContentKind.project.rawValue,
                accountID.rawValue, organizationID.rawValue,
                GitHubContentKind.issue.rawValue, GitHubContentKind.pullRequest.rawValue,
                GitHubContentKind.projectDraftIssue.rawValue
            ])
    }

    private nonisolated static func validateOrganization(accountID: AccountID, organization: GitHubOrganization, in database: Database) throws {
        let count = try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM account_organizations JOIN organizations ON organizations.id = account_organizations.organization_id
            WHERE account_organizations.account_id = ? AND organizations.id = ? AND organizations.github_organization_id = ?
              AND lower(organizations.login) = lower(?)
            """, arguments: [accountID.rawValue, organization.id.rawValue, String(organization.githubOrganizationID), organization.login]) ?? 0
        guard count == 1 else { throw ProjectV2RepositoryError.organizationScopeMismatch }
    }

    private nonisolated static func validateCurrentScope(_ scope: SynchronizationScope, in database: Database) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope,
                OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw ProjectV2RepositoryError.staleSynchronizationScope
        }
    }

    private nonisolated static func preparedRaw(
        _ pages: [GitHubProjectV2RawPage], scope: SynchronizationScope, feature: CoverageFeature,
        streamID: SyncStreamID, sourceNodeID: GitHubNodeID, accountID: AccountID,
        allowedItemNodeIDs: Set<GitHubNodeID>, requiresCompleteTraversal: Bool,
        observedAt: Date, parserVersion: Int
    ) throws -> [RawAPISnapshot] {
        guard (feature == .projects || feature == .projectItems),
              Set(pages.map(\.requestKey)).count == pages.count else {
            throw ProjectV2RepositoryError.invalidRawAuthority
        }
        try validateTraversal(
            pages,
            feature: feature,
            sourceNodeID: sourceNodeID,
            allowedItemNodeIDs: allowedItemNodeIDs,
            requiresCompleteTraversal: requiresCompleteTraversal
        )
        return try pages.map { page in
            guard page.payload.count <= RawAPISnapshotRepository.maximumPayloadBytes,
                  isProjectRequest(page.requestKey, endpoint: page.endpoint, feature: feature, sourceNodeID: sourceNodeID)
            else { throw ProjectV2RepositoryError.invalidRawAuthority }
            let identity = ConditionalRequestIdentity(
                scope: scope, feature: feature, streamID: streamID, requestKey: page.requestKey
            )
            // Item-field GraphQL pages are fetched before their item may be
            // normalized. The project is therefore the immutable collection
            // object retained in `githubNodeID`; the exact item target remains
            // durably bound by `requestKey` (for example, `item=PVTI_…`).
            return RawAPISnapshot(
                id: snapshotID(identity: identity, payload: page.payload, observedAt: observedAt, parserVersion: parserVersion), accountID: accountID,
                githubNodeID: sourceNodeID, endpoint: page.endpoint, eTag: nil,
                parserVersion: parserVersion, observedAt: observedAt, payload: page.payload,
                requestIdentity: identity
            )
        }
    }

    private nonisolated static func isProjectRequest(
        _ requestKey: String, endpoint: String, feature: CoverageFeature, sourceNodeID: GitHubNodeID
    ) -> Bool {
        let allowedPrefix: String
        switch feature {
        case .projects:
            allowedPrefix = "graphql:TriageOrganizationProjectsV2/organization=\(sourceNodeID.rawValue)/after="
        case .projectItems:
            let projectPrefix = "graphql:TriageProjectV2Items/project=\(sourceNodeID.rawValue)/after="
            let fieldPrefix = "graphql:TriageProjectV2ItemFieldValues/item="
            guard requestKey.hasPrefix(projectPrefix) || requestKey.hasPrefix(fieldPrefix) else { return false }
            allowedPrefix = requestKey.hasPrefix(projectPrefix) ? projectPrefix : fieldPrefix
        default:
            return false
        }
        guard requestKey.hasPrefix(allowedPrefix), let separator = requestKey.range(of: "/after=", options: .backwards) else {
            return false
        }
        let cursor = String(requestKey[separator.upperBound...])
        guard cursor == "none" || (Data(base64Encoded: cursor).flatMap { String(data: $0, encoding: .utf8) }?.isEmpty == false) else {
            return false
        }
        let endpointPrefix = String(requestKey[..<separator.lowerBound]) + "/page="
        guard endpoint.hasPrefix(endpointPrefix), let page = Int(endpoint.dropFirst(endpointPrefix.count)), page > 0 else {
            return false
        }
        return true
    }

    private enum ProjectRawOperation: Equatable {
        case projects
        case items
        case fieldValues
    }

    private struct ProjectRawRequest {
        let operation: ProjectRawOperation
        let target: GitHubNodeID
        let base: String
        let cursor: String?
    }

    private struct ProjectRawPageInfo {
        let hasNextPage: Bool
        let endCursor: String?
    }

    private nonisolated static func validateTraversal(
        _ pages: [GitHubProjectV2RawPage],
        feature: CoverageFeature,
        sourceNodeID: GitHubNodeID,
        allowedItemNodeIDs: Set<GitHubNodeID>,
        requiresCompleteTraversal: Bool
    ) throws {
        guard !pages.isEmpty else {
            guard !requiresCompleteTraversal else {
                throw ProjectV2RepositoryError.invalidRawAuthority
            }
            return
        }
        var seenBases = Set<String>()
        var fieldTargets = Set<GitHubNodeID>()
        var sawRootTraversal = false
        var currentBase: String?
        var currentIndex = 0
        var priorInfo: ProjectRawPageInfo?
        var sawFieldGroup = false

        for page in pages {
            let request = try projectRawRequest(page.requestKey)
            switch (feature, request.operation) {
            case (.projects, .projects):
                guard request.target == sourceNodeID, seenBases.isEmpty || currentBase == request.base else {
                    throw ProjectV2RepositoryError.invalidRawAuthority
                }
                sawRootTraversal = true
            case (.projectItems, .items):
                guard request.target == sourceNodeID, !sawFieldGroup else {
                    throw ProjectV2RepositoryError.invalidRawAuthority
                }
                sawRootTraversal = true
            case (.projectItems, .fieldValues):
                sawFieldGroup = true
                if !allowedItemNodeIDs.isEmpty {
                    guard allowedItemNodeIDs.contains(request.target) else {
                        throw ProjectV2RepositoryError.invalidRawAuthority
                    }
                }
                fieldTargets.insert(request.target)
            default:
                throw ProjectV2RepositoryError.invalidRawAuthority
            }

            if currentBase != request.base {
                if requiresCompleteTraversal, let priorInfo, priorInfo.hasNextPage {
                    throw ProjectV2RepositoryError.invalidRawAuthority
                }
                guard seenBases.insert(request.base).inserted, request.cursor == nil else {
                    throw ProjectV2RepositoryError.invalidRawAuthority
                }
                currentBase = request.base
                currentIndex = 1
                priorInfo = nil
            } else {
                currentIndex += 1
                guard let priorInfo, priorInfo.hasNextPage,
                      let expectedCursor = priorInfo.endCursor,
                      request.cursor == expectedCursor else {
                    throw ProjectV2RepositoryError.invalidRawAuthority
                }
            }
            guard page.endpoint == request.base + "/page=\(currentIndex)" else {
                throw ProjectV2RepositoryError.invalidRawAuthority
            }
            if requiresCompleteTraversal || currentIndex > 0 {
                do {
                    priorInfo = try projectRawPageInfo(
                        page.payload,
                        operation: request.operation,
                        expectedTarget: request.target
                    )
                } catch {
                    // Failed traversals retain their terminal malformed page as
                    // raw evidence, but it can never authorize complete state.
                    guard !requiresCompleteTraversal else { throw error }
                    priorInfo = nil
                }
            }
        }
        if requiresCompleteTraversal {
            guard sawRootTraversal, priorInfo?.hasNextPage == false else {
                throw ProjectV2RepositoryError.invalidRawAuthority
            }
            if feature == .projectItems {
                guard fieldTargets == allowedItemNodeIDs else {
                    throw ProjectV2RepositoryError.invalidRawAuthority
                }
            }
        }
    }

    private nonisolated static func projectRawRequest(_ key: String) throws -> ProjectRawRequest {
        guard let separator = key.range(of: "/after=", options: .backwards) else {
            throw ProjectV2RepositoryError.invalidRawAuthority
        }
        let base = String(key[..<separator.lowerBound])
        let component = String(key[separator.upperBound...])
        let cursor: String?
        if component == "none" {
            cursor = nil
        } else {
            guard let data = Data(base64Encoded: component),
                  let decoded = String(data: data, encoding: .utf8),
                  !decoded.isEmpty else {
                throw ProjectV2RepositoryError.invalidRawAuthority
            }
            cursor = decoded
        }
        let specifications: [(String, ProjectRawOperation)] = [
            ("graphql:TriageOrganizationProjectsV2/organization=", .projects),
            ("graphql:TriageProjectV2Items/project=", .items),
            ("graphql:TriageProjectV2ItemFieldValues/item=", .fieldValues)
        ]
        for (prefix, operation) in specifications where base.hasPrefix(prefix) {
            guard let target = GitHubNodeID(rawValue: String(base.dropFirst(prefix.count))) else {
                throw ProjectV2RepositoryError.invalidRawAuthority
            }
            return ProjectRawRequest(operation: operation, target: target, base: base, cursor: cursor)
        }
        throw ProjectV2RepositoryError.invalidRawAuthority
    }

    private nonisolated static func projectRawPageInfo(
        _ payload: Data,
        operation: ProjectRawOperation,
        expectedTarget: GitHubNodeID
    ) throws -> ProjectRawPageInfo {
        guard payload.count <= RawAPISnapshotRepository.maximumPayloadBytes,
              let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              root["errors"] == nil,
              let data = root["data"] as? [String: Any],
              let node = data["node"] as? [String: Any],
              node["id"] as? String == expectedTarget.rawValue else {
            throw ProjectV2RepositoryError.invalidRawAuthority
        }
        let connectionKey: String = switch operation {
        case .projects: "projectsV2"
        case .items: "items"
        case .fieldValues: "fieldValues"
        }
        guard let connection = node[connectionKey] as? [String: Any],
              let pageInfo = connection["pageInfo"] as? [String: Any],
              let hasNextPage = pageInfo["hasNextPage"] as? Bool else {
            throw ProjectV2RepositoryError.invalidRawAuthority
        }
        let endCursor = pageInfo["endCursor"] as? String
        guard !hasNextPage || endCursor?.isEmpty == false else {
            throw ProjectV2RepositoryError.invalidRawAuthority
        }
        return ProjectRawPageInfo(hasNextPage: hasNextPage, endCursor: endCursor)
    }

    private nonisolated static func save(
        _ snapshot: RawAPISnapshot, rejectingConflictAt observedAt: Date, in database: Database
    ) throws {
        guard let identity = snapshot.requestIdentity else { throw ProjectV2RepositoryError.invalidRawAuthority }
        let values = try Data.fetchAll(database, sql: """
            SELECT payload FROM raw_api_snapshots
            WHERE account_id = ? AND authority_organization_id = ? AND authority_feature = ?
              AND authority_stream_id = ? AND authority_request_key = ?
              AND authority_credential_revision = ? AND authority_capability_revision = ?
              AND observed_at_ms = ?
            """, arguments: [
                snapshot.accountID.rawValue, identity.scope.organizationID.rawValue, identity.feature.rawValue,
                identity.streamID.rawValue, identity.requestKey, identity.scope.credentialRevision.rawValue,
                identity.scope.capabilityRevision.rawValue, milliseconds(observedAt)
            ])
        guard values.allSatisfy({ $0 == snapshot.payload }) else {
            throw ProjectV2RepositoryError.conflictingRawPage
        }
        try RawAPISnapshotRepository.save(snapshot, in: database)
    }

    private nonisolated static func snapshotID(
        identity: ConditionalRequestIdentity, payload: Data, observedAt: Date, parserVersion: Int
    ) -> RawAPISnapshotID {
        let payloadDigest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let material = [identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue,
                        identity.feature.rawValue, identity.streamID.rawValue, identity.requestKey,
                        identity.scope.credentialRevision.rawValue, identity.scope.capabilityRevision.rawValue,
                        String(milliseconds(observedAt)), String(parserVersion), payloadDigest].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return RawAPISnapshotID(rawValue: "project-v2:\(digest)")!
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
}
