import Foundation
import GRDB

/// Produces the durable work-item graph immediately after normalized source
/// commits and before derived rules run. Strong, current-scope relations merge
/// their items; all remaining relations stay contextual links.
struct OrganizationWorkItemGraphProjectionService: Sendable {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    /// Reports the durable identity changes that a notification owner must
    /// reconcile. Notification delivery remains deliberately outside this
    /// graph transaction: a delivery is an external side effect, while the
    /// canonical membership mapping is local durable state.
    struct ProjectionResult: Equatable, Sendable {
        struct Canonicalization: Equatable, Sendable {
            let constituentWorkItemID: WorkItemID
            let canonicalWorkItemID: WorkItemID
        }

        let canonicalizations: [Canonicalization]

        var notificationCleanupConstituentWorkItemIDs: [WorkItemID] {
            canonicalizations
                .filter { $0.constituentWorkItemID != $0.canonicalWorkItemID }
                .map(\.constituentWorkItemID)
        }
    }

    @discardableResult
    func projectAfterNormalizedCommit(
        for scope: SynchronizationScope,
        at date: Date = .now
    ) async throws -> ProjectionResult {
        guard scope.accountID == vault.accountID else { throw CancellationError() }
        try Task.checkCancellation()
        return try await vault.writeTransaction { database in
            try Task.checkCancellation()
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
            let items = try Self.items(scope: scope, in: database)
            guard !items.isEmpty else {
                let sourceRevision = try Self.sourceRevision(scope: scope, in: database)
                try WorkItemCanonicalGroupRepository.replace(
                    [],
                    scope: scope,
                    sourceRevision: sourceRevision,
                    at: date,
                    in: database
                )
                try Self.recordRun(scope: scope, sourceRevision: sourceRevision, at: date, in: database)
                return ProjectionResult(canonicalizations: [])
            }
            // `closingIssuesReferences` is an explicit, bounded GraphQL
            // field. Persist it only when its exact raw response and the
            // matching current pull-request coverage receipt remain present.
            // This intentionally ignores text such as "fixes #123".
            try Self.reconcileCurrentHydrationResponsibilityRelations(scope: scope, in: database)
            try Self.reconcileCurrentRoleMentionRelations(scope: scope, in: database)
            try Self.reconcileCurrentHydrationClosingRelations(scope: scope, in: database)
            try Self.reconcileCurrentReviewContainmentRelations(scope: scope, in: database)
            try Self.reconcileCurrentReviewActorRelations(scope: scope, in: database)
            try Self.reconcileCurrentProjectItemWrapperRelations(scope: scope, in: database)
            let relations = try Self.currentRelations(scope: scope, in: database)
            let decisions = try Self.currentDecisions(scope: scope, in: database)
            let result = WorkItemGrouper().group(
                nodeIDs: items.map(\.primaryNodeID) + relations.flatMap { [$0.subjectNodeID] + ($0.objectNodeID.map { [$0] } ?? []) },
                relations: relations,
                decisions: decisions
            )
            let itemByPrimary = Dictionary(uniqueKeysWithValues: items.map { ($0.primaryNodeID, $0) })
            var canonicalizations = [ProjectionResult.Canonicalization]()
            for group in result.memberGroups {
                try Task.checkCancellation()
                let groupItems = group.compactMap { itemByPrimary[$0] }
                guard let target = groupItems.min(by: { $0.primaryNodeID.rawValue < $1.primaryNodeID.rawValue }) else {
                    continue
                }
                let contexts = Self.contextLinks(for: group, relations: relations)
                try WorkItemGraphRepository.replace(
                    workItemID: target.id,
                    members: group.sorted { $0.rawValue < $1.rawValue }.map {
                        .init(nodeID: $0, role: Self.memberRole(nodeID: $0, target: target.primaryNodeID, in: relations))
                    },
                    contextLinks: contexts,
                    vault: vault,
                    in: database
                )
                canonicalizations += groupItems.map {
                    .init(constituentWorkItemID: $0.id, canonicalWorkItemID: target.id)
                }
            }
            let sourceRevision = try Self.sourceRevision(scope: scope, in: database)
            try WorkItemCanonicalGroupRepository.replace(
                canonicalizations,
                scope: scope,
                sourceRevision: sourceRevision,
                at: date,
                in: database
            )
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
            try Self.recordRun(scope: scope, sourceRevision: sourceRevision, at: date, in: database)
            return ProjectionResult(canonicalizations: canonicalizations.sorted {
                $0.constituentWorkItemID.rawValue < $1.constituentWorkItemID.rawValue
            })
        }
    }

    private struct Item: Sendable { let id: WorkItemID; let primaryNodeID: GitHubNodeID }

    private struct HydrationClosingSource: Sendable {
        let pullRequestNodeID: GitHubNodeID
        let sourceRevision: String
        let rawSnapshotID: RawAPISnapshotID
        let requestKey: String
        let streamID: SyncStreamID
        let observedAt: Date
        let payload: Data
    }

    /// A single node's slice of the bounded `TriageHydrateNodes` response.
    /// The raw snapshot and node revision are carried together so current
    /// responsibility edges cannot be recreated from an old batch response.
    private struct HydrationResponsibilitySource: Sendable {
        let nodeID: GitHubNodeID
        let kind: GitHubContentKind
        let sourceRevision: String
        let rawSnapshotID: RawAPISnapshotID
        let requestKey: String
        let streamID: SyncStreamID
        let observedAt: Date
        let payload: Data
    }

    private struct ReceiptContainmentSource: Sendable {
        let pullRequestNodeID: GitHubNodeID
        let sourceRevision: String
        let rawSnapshotID: RawAPISnapshotID
        let requestKey: String
        let streamID: SyncStreamID
        let feature: CoverageFeature
        let observedAt: Date
    }

    private nonisolated static func items(scope: SynchronizationScope, in database: Database) throws -> [Item] {
        try Row.fetchAll(database, sql: "SELECT id, primary_node_id FROM work_items WHERE account_id = ? AND organization_id = ? ORDER BY primary_node_id", arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]).map {
            guard let id = WorkItemID(rawValue: $0["id"]), let node = GitHubNodeID(rawValue: $0["primary_node_id"]) else {
                throw WorkItemGraphRepositoryError.workItemScopeMismatch
            }
            return Item(id: id, primaryNodeID: node)
        }
    }

    /// Materializes only relationships explicitly represented in the complete
    /// hydration selection.  Search discovery decides which content is worth
    /// hydrating; it is not itself proof of an assignee, author, or current
    /// review request.  In particular, a truncated nested connection publishes
    /// no relation rather than a tempting partial set.
    private nonisolated static func reconcileCurrentHydrationResponsibilityRelations(
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        let currentAccountNodeID = (try String.fetchOne(
            database,
            sql: "SELECT github_node_id FROM accounts WHERE id = ?",
            arguments: [scope.accountID.rawValue]
        )).flatMap(GitHubNodeID.init(rawValue:))
        let sources = try Row.fetchAll(database, sql: """
            SELECT github_nodes.github_node_id, github_nodes.kind, github_nodes.source_revision,
                   raw_api_snapshots.id, raw_api_snapshots.authority_request_key,
                   raw_api_snapshots.authority_stream_id, raw_api_snapshots.observed_at_ms,
                   raw_api_snapshots.payload
            FROM github_nodes
            JOIN raw_api_snapshots
              ON raw_api_snapshots.github_node_id = github_nodes.github_node_id
            WHERE github_nodes.account_id = ? AND github_nodes.organization_id = ?
              AND github_nodes.kind IN ('issue', 'pullRequest')
              AND raw_api_snapshots.account_id = ?
              AND raw_api_snapshots.authority_organization_id = ?
              AND raw_api_snapshots.authority_feature IN ('issues', 'pullRequests')
              AND raw_api_snapshots.authority_credential_revision = ?
              AND raw_api_snapshots.authority_capability_revision = ?
              AND raw_api_snapshots.observed_at_ms = github_nodes.last_observed_at_ms
              AND raw_api_snapshots.authority_request_key =
                    'graphql:TriageHydrateNodes/node=' || github_nodes.github_node_id
              AND EXISTS (
                  SELECT 1 FROM coverage_records
                  WHERE coverage_records.account_id = raw_api_snapshots.account_id
                    AND coverage_records.organization_id = raw_api_snapshots.authority_organization_id
                    AND coverage_records.repository_id IS NULL
                    AND coverage_records.feature = raw_api_snapshots.authority_feature
                    AND coverage_records.stream_id = raw_api_snapshots.authority_stream_id
                    AND coverage_records.credential_revision = raw_api_snapshots.authority_credential_revision
                    AND coverage_records.capability_revision = raw_api_snapshots.authority_capability_revision
                    AND coverage_records.status = 'complete'
                    AND coverage_records.last_successful_at_ms >= raw_api_snapshots.observed_at_ms
              )
            ORDER BY github_nodes.github_node_id, raw_api_snapshots.id
            """, arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ]).compactMap { row -> HydrationResponsibilitySource? in
                guard let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let rawKind: String = row["kind"],
                      let kind = GitHubContentKind(rawValue: rawKind),
                      let sourceRevision: String = row["source_revision"], !sourceRevision.isEmpty,
                      let rawSnapshotID = RawAPISnapshotID(rawValue: row["id"]),
                      let requestKey: String = row["authority_request_key"],
                      let streamID = SyncStreamID(rawValue: row["authority_stream_id"]),
                      let milliseconds: Int64 = row["observed_at_ms"],
                      let payload: Data = row["payload"]
                else { return nil }
                return HydrationResponsibilitySource(
                    nodeID: nodeID,
                    kind: kind,
                    sourceRevision: sourceRevision,
                    rawSnapshotID: rawSnapshotID,
                    requestKey: requestKey,
                    streamID: streamID,
                    observedAt: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000),
                    payload: payload
                )
            }

        for source in sources {
            guard var relations = hydrationResponsibilityRelations(from: source, scope: scope) else {
                // A malformed or truncated connection is not an empty current
                // set. Leave the prior historical evidence intact; it cannot
                // satisfy the current-revision checks used by projection/rules.
                continue
            }
            // A Waiting state on a PR authored by the current account can
            // safely mean the account is awaiting one of its explicit direct
            // review requests.  Do not create a team await edge: a team is
            // not the actor that can later satisfy the response condition.
            if let currentAccountNodeID,
               relations.contains(where: { $0.kind == .authored && $0.objectNodeID == currentAccountNodeID }) {
                let reviewerIDs = relations.compactMap { relation -> GitHubNodeID? in
                    relation.kind == .reviewRequestedDirectly ? relation.objectNodeID : nil
                }
                relations += reviewerIDs.map { reviewerID in
                    let evidence = relations.first { relation in
                        relation.kind == .reviewRequestedDirectly && relation.objectNodeID == reviewerID
                    }!.evidence
                    return WorkRelation(
                        kind: .awaitingResponse,
                        subjectNodeID: source.nodeID,
                        objectNodeID: reviewerID,
                        confidence: .confirmed,
                        evidence: evidence.map { value in
                            EvidenceReference(
                                id: EvidenceID(rawValue: "hydration-awaiting-response-\(source.nodeID.rawValue)-\(reviewerID.rawValue)-\(source.rawSnapshotID.rawValue)")!,
                                source: value.source,
                                locator: value.locator,
                                authority: value.authority,
                                nodeID: value.nodeID,
                                eventID: value.eventID,
                                sourceRevision: value.sourceRevision,
                                rawSnapshotID: value.rawSnapshotID,
                                confidence: value.confidence,
                                confirmation: value.confirmation,
                                observedAt: value.observedAt,
                                excerpt: value.excerpt
                            )
                        },
                        observedAt: source.observedAt
                    )
                }
            }
            let feature: CoverageFeature = source.kind == .issue ? .issues : .pullRequests
            let authority = RelationReplacementAuthority(
                source: .graphQL,
                locator: .query(source.requestKey),
                scope: scope,
                feature: feature,
                streamID: source.streamID,
                repositoryID: nil,
                sourceRevision: source.sourceRevision,
                rawSnapshotID: source.rawSnapshotID,
                observedAt: source.observedAt,
                mode: .completeReconciliation
            )
            try WorkRelationRepository.replace(
                relations,
                accountID: scope.accountID,
                subjectNodeID: source.nodeID,
                authority: authority,
                in: database
            )
        }
    }

    /// GitHub's issue search `mentions:` qualifier is direct server-side
    /// membership evidence.  We use it only for the exact current viewer or
    /// an explicitly active visible team, and only after the corresponding
    /// role-discovery stream is complete.  The timeline's `mentioned` event
    /// does not identify a target and therefore is deliberately not used.
    private nonisolated static func reconcileCurrentRoleMentionRelations(
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        let rows = try Row.fetchAll(database, sql: """
            SELECT raw_api_snapshots.id, raw_api_snapshots.authority_request_key,
                   raw_api_snapshots.authority_stream_id, raw_api_snapshots.observed_at_ms,
                   raw_api_snapshots.payload, role_search_page_replays.query_value,
                   accounts.github_node_id AS account_node_id, accounts.login AS account_login,
                   organizations.login AS organization_login
            FROM raw_api_snapshots
            JOIN accounts ON accounts.id = raw_api_snapshots.account_id
            JOIN organizations ON organizations.id = raw_api_snapshots.authority_organization_id
            JOIN role_search_page_replays
              ON role_search_page_replays.raw_snapshot_id = raw_api_snapshots.id
             AND role_search_page_replays.account_id = raw_api_snapshots.account_id
             AND role_search_page_replays.organization_id = raw_api_snapshots.authority_organization_id
             AND role_search_page_replays.stream_id = raw_api_snapshots.authority_stream_id
             AND role_search_page_replays.request_key = raw_api_snapshots.authority_request_key
             AND role_search_page_replays.credential_revision = raw_api_snapshots.authority_credential_revision
             AND role_search_page_replays.capability_revision = raw_api_snapshots.authority_capability_revision
            WHERE raw_api_snapshots.account_id = ?
              AND raw_api_snapshots.github_node_id IS NULL
              AND raw_api_snapshots.authority_organization_id = ?
              AND raw_api_snapshots.authority_feature = 'roleDiscovery'
              AND raw_api_snapshots.authority_credential_revision = ?
              AND raw_api_snapshots.authority_capability_revision = ?
              AND (raw_api_snapshots.authority_stream_id LIKE '%-open-direct-mentions'
                   OR raw_api_snapshots.authority_stream_id LIKE '%-open-team-mentions')
              AND EXISTS (
                  SELECT 1 FROM coverage_records
                  WHERE coverage_records.account_id = raw_api_snapshots.account_id
                    AND coverage_records.organization_id = raw_api_snapshots.authority_organization_id
                    AND coverage_records.repository_id IS NULL
                    AND coverage_records.feature = raw_api_snapshots.authority_feature
                    AND coverage_records.stream_id = raw_api_snapshots.authority_stream_id
                    AND coverage_records.credential_revision = raw_api_snapshots.authority_credential_revision
                    AND coverage_records.capability_revision = raw_api_snapshots.authority_capability_revision
                    AND coverage_records.status = 'complete'
                    AND coverage_records.last_successful_at_ms >= raw_api_snapshots.observed_at_ms
              )
            ORDER BY raw_api_snapshots.id
            """, arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for row in rows {
            guard let rawSnapshotID = RawAPISnapshotID(rawValue: row["id"]),
                  let requestKey: String = row["authority_request_key"],
                  let streamID = SyncStreamID(rawValue: row["authority_stream_id"]),
                  let observedMilliseconds: Int64 = row["observed_at_ms"],
                  let payload: Data = row["payload"],
                  let queryValue: String = row["query_value"],
                  let accountNodeID = GitHubNodeID(rawValue: row["account_node_id"]),
                  let accountLogin: String = row["account_login"],
                  let organizationLogin: String = row["organization_login"],
                  let page = try? decoder.decode(GitHubIssueSearchPage.self, from: payload),
                  !page.incompleteResults
            else { continue }

            let relation: (kind: WorkRelationKind, objectNodeID: GitHubNodeID)?
            if streamID.rawValue.hasSuffix("-open-direct-mentions") {
                relation = roleQueryQualifier(named: "mentions", in: queryValue) == accountLogin
                    ? (.mentioned, accountNodeID)
                    : nil
            } else {
                relation = teamMentionRelation(
                    queryValue: queryValue,
                    organizationLogin: organizationLogin,
                    scope: scope,
                    in: database
                )
            }
            guard let relation else { continue }
            let observedAt = Date(timeIntervalSince1970: TimeInterval(observedMilliseconds) / 1_000)
            for item in page.items {
                guard let subjectNodeID = GitHubNodeID(rawValue: item.nodeID),
                      let sourceRevision = currentSourceRevision(
                          for: subjectNodeID,
                          expected: item.updatedAt.ISO8601Format(),
                          scope: scope,
                          in: database
                      )
                else { continue }
                let authority = RelationReplacementAuthority(
                    source: .restSearch,
                    locator: .query(requestKey),
                    scope: scope,
                    feature: .roleDiscovery,
                    streamID: streamID,
                    repositoryID: nil,
                    sourceRevision: sourceRevision,
                    rawSnapshotID: rawSnapshotID,
                    observedAt: observedAt,
                    mode: .completeReconciliation
                )
                let workRelation = WorkRelation(
                    kind: relation.kind,
                    subjectNodeID: subjectNodeID,
                    objectNodeID: relation.objectNodeID,
                    confidence: .confirmed,
                    evidence: [EvidenceReference(
                        id: EvidenceID(rawValue: "role-\(relation.kind.rawValue)-\(subjectNodeID.rawValue)-\(relation.objectNodeID.rawValue)-\(rawSnapshotID.rawValue)")!,
                        source: .restSearch,
                        locator: .query(requestKey),
                        authority: .github(scope: scope, feature: .roleDiscovery, streamID: streamID),
                        nodeID: subjectNodeID,
                        sourceRevision: sourceRevision,
                        rawSnapshotID: rawSnapshotID,
                        confidence: .confirmed,
                        confirmation: .confirmed,
                        observedAt: observedAt
                    )],
                    observedAt: observedAt
                )
                try WorkRelationRepository.replace(
                    [workRelation],
                    accountID: scope.accountID,
                    subjectNodeID: subjectNodeID,
                    authority: authority,
                    in: database
                )
            }
        }
    }

    private nonisolated static func teamMentionRelation(
        queryValue: String,
        organizationLogin: String,
        scope: SynchronizationScope,
        in database: Database
    ) -> (kind: WorkRelationKind, objectNodeID: GitHubNodeID)? {
        guard let teamSlug = roleTeamMentionSlug(
            in: queryValue,
            organizationLogin: organizationLogin
        ) else { return nil }
        let rawNodeID: String?
        do {
            rawNodeID = try String.fetchOne(
                database,
                sql: """
                    SELECT teams.github_node_id
                    FROM teams
                    JOIN team_memberships ON team_memberships.team_id = teams.id
                    WHERE teams.organization_id = ? AND teams.slug = ?
                      AND team_memberships.account_id = ?
                      AND team_memberships.membership_state = 'active'
                    """,
                arguments: [scope.organizationID.rawValue, teamSlug, scope.accountID.rawValue]
            )
        } catch {
            return nil
        }
        guard let rawNodeID, let nodeID = GitHubNodeID(rawValue: rawNodeID)
        else { return nil }
        return (.teamMentioned, nodeID)
    }

    /// Parses one exact search qualifier token. Role discovery persists the
    /// query that it issued, so accepting substrings (for example
    /// `mentions:octocat-alt`) could turn a different GitHub search into a
    /// current personal responsibility relation.
    nonisolated static func roleQueryQualifier(
        named name: String,
        in query: String
    ) -> String? {
        let prefix = name + ":"
        let qualifiers = query
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> String? in
                guard token.hasPrefix(prefix) else { return nil }
                let value = String(token.dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
        guard qualifiers.count == 1 else { return nil }
        return qualifiers[0]
    }

    nonisolated static func roleTeamMentionQualifier(
        in query: String
    ) -> (owner: String, slug: String)? {
        guard let qualifier = roleQueryQualifier(named: "mentions", in: query),
              let slash = qualifier.firstIndex(of: "/"),
              qualifier[qualifier.index(after: slash)...].firstIndex(of: "/") == nil
        else { return nil }
        let owner = String(qualifier[..<slash])
        let slug = String(qualifier[qualifier.index(after: slash)...])
        guard !owner.isEmpty, !slug.isEmpty else { return nil }
        return (owner, slug)
    }

    /// A team slug is meaningful only within its exact organization owner.
    nonisolated static func roleTeamMentionSlug(
        in query: String,
        organizationLogin: String
    ) -> String? {
        guard let qualifier = roleTeamMentionQualifier(in: query),
              qualifier.owner == organizationLogin
        else { return nil }
        return qualifier.slug
    }

    private nonisolated static func currentSourceRevision(
        for nodeID: GitHubNodeID,
        expected: String,
        scope: SynchronizationScope,
        in database: Database
    ) -> String? {
        let revision: String?
        do {
            revision = try String.fetchOne(
                database,
                sql: """
                    SELECT source_revision
                    FROM github_nodes
                    WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                      AND source_revision = ?
                    """,
                arguments: [nodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue, expected]
            )
        } catch {
            return nil
        }
        guard let revision, !revision.isEmpty
        else { return nil }
        return revision
    }

    /// Returns nil when a required bounded GraphQL connection is absent or
    /// incomplete.  A non-nil empty list is therefore a proven empty set.
    private nonisolated static func hydrationResponsibilityRelations(
        from source: HydrationResponsibilitySource,
        scope: SynchronizationScope
    ) -> [WorkRelation]? {
        guard let root = try? JSONSerialization.jsonObject(with: source.payload) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let nodes = data["nodes"] as? [[String: Any]],
              let node = nodes.first(where: { ($0["id"] as? String) == source.nodeID.rawValue })
        else { return nil }

        var drafts = [(WorkRelationKind, GitHubNodeID)]()
        if let authorID = (node["author"] as? [String: Any])?["id"] as? String,
           let author = GitHubNodeID(rawValue: authorID) {
            drafts.append((.authored, author))
        }
        guard let assigneeObjects = completeConnection(named: "assignees", in: node) else {
            return nil
        }
        let assignees = assigneeObjects.compactMap { ($0["id"] as? String).flatMap(GitHubNodeID.init(rawValue:)) }
        guard assignees.count == assigneeObjects.count, Set(assignees).count == assignees.count else { return nil }
        drafts += assignees.map { (.assigned, $0) }

        if source.kind == .pullRequest {
            guard let requestObjects = completeConnection(named: "reviewRequests", in: node) else {
                return nil
            }
            for request in requestObjects {
                guard let reviewer = request["requestedReviewer"] as? [String: Any],
                      let rawID = reviewer["id"] as? String,
                      let reviewerID = GitHubNodeID(rawValue: rawID)
                else { return nil }
                // The committed selection distinguishes the two possible
                // union branches structurally: Team has `slug`, User has
                // `login`. Do not guess when GitHub omits either discriminator.
                if reviewer["slug"] is String, reviewer["login"] == nil {
                    drafts.append((.reviewRequestedFromTeam, reviewerID))
                } else if reviewer["login"] is String, reviewer["slug"] == nil {
                    drafts.append((.reviewRequestedDirectly, reviewerID))
                } else {
                    return nil
                }
            }
        }

        let feature: CoverageFeature = source.kind == .issue ? .issues : .pullRequests
        return drafts
            .sorted { lhs, rhs in
                lhs.0.rawValue == rhs.0.rawValue
                    ? lhs.1.rawValue < rhs.1.rawValue
                    : lhs.0.rawValue < rhs.0.rawValue
            }
            .map { kind, objectNodeID in
                WorkRelation(
                    kind: kind,
                    subjectNodeID: source.nodeID,
                    objectNodeID: objectNodeID,
                    confidence: .confirmed,
                    evidence: [EvidenceReference(
                        id: EvidenceID(rawValue: "hydration-\(kind.rawValue)-\(source.nodeID.rawValue)-\(objectNodeID.rawValue)-\(source.rawSnapshotID.rawValue)")!,
                        source: .graphQL,
                        locator: .query(source.requestKey),
                        authority: .github(scope: scope, feature: feature, streamID: source.streamID),
                        nodeID: source.nodeID,
                        sourceRevision: source.sourceRevision,
                        rawSnapshotID: source.rawSnapshotID,
                        confidence: .confirmed,
                        confirmation: .confirmed,
                        observedAt: source.observedAt
                    )],
                    observedAt: source.observedAt
                )
            }
    }

    private nonisolated static func completeConnection(
        named name: String,
        in node: [String: Any]
    ) -> [[String: Any]]? {
        guard let connection = node[name] as? [String: Any],
              let pageInfo = connection["pageInfo"] as? [String: Any],
              pageInfo["hasNextPage"] as? Bool == false,
              let nodes = connection["nodes"] as? [[String: Any]]
        else { return nil }
        return nodes
    }

    private nonisolated static func reconcileCurrentHydrationClosingRelations(
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        let sources = try Row.fetchAll(database, sql: """
            SELECT github_nodes.github_node_id, github_nodes.source_revision,
                   raw_api_snapshots.id, raw_api_snapshots.authority_request_key,
                   raw_api_snapshots.authority_stream_id, raw_api_snapshots.observed_at_ms,
                   raw_api_snapshots.payload
            FROM github_nodes
            JOIN raw_api_snapshots
              ON raw_api_snapshots.github_node_id = github_nodes.github_node_id
            WHERE github_nodes.account_id = ? AND github_nodes.organization_id = ?
              AND github_nodes.kind = 'pullRequest'
              AND raw_api_snapshots.account_id = ?
              AND raw_api_snapshots.authority_organization_id = ?
              AND raw_api_snapshots.authority_feature = 'pullRequests'
              AND raw_api_snapshots.authority_credential_revision = ?
              AND raw_api_snapshots.authority_capability_revision = ?
              AND raw_api_snapshots.observed_at_ms = github_nodes.last_observed_at_ms
              AND raw_api_snapshots.authority_request_key =
                    'graphql:TriageHydrateNodes/node=' || github_nodes.github_node_id
              AND EXISTS (
                  SELECT 1 FROM coverage_records
                  WHERE coverage_records.account_id = raw_api_snapshots.account_id
                    AND coverage_records.organization_id = raw_api_snapshots.authority_organization_id
                    AND coverage_records.repository_id IS NULL
                    AND coverage_records.feature = raw_api_snapshots.authority_feature
                    AND coverage_records.stream_id = raw_api_snapshots.authority_stream_id
                    AND coverage_records.credential_revision = raw_api_snapshots.authority_credential_revision
                    AND coverage_records.capability_revision = raw_api_snapshots.authority_capability_revision
                    AND coverage_records.status = 'complete'
                    AND coverage_records.last_successful_at_ms >= raw_api_snapshots.observed_at_ms
              )
            ORDER BY github_nodes.github_node_id, raw_api_snapshots.id
            """, arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ]).compactMap { row -> HydrationClosingSource? in
                guard let pullRequestNodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let sourceRevision: String = row["source_revision"],
                      let rawSnapshotID = RawAPISnapshotID(rawValue: row["id"]),
                      let requestKey: String = row["authority_request_key"],
                      let streamID = SyncStreamID(rawValue: row["authority_stream_id"]),
                      let observedAtMilliseconds: Int64 = row["observed_at_ms"],
                      let payload: Data = row["payload"]
                else { return nil }
                return HydrationClosingSource(
                    pullRequestNodeID: pullRequestNodeID,
                    sourceRevision: sourceRevision,
                    rawSnapshotID: rawSnapshotID,
                    requestKey: requestKey,
                    streamID: streamID,
                    observedAt: Date(timeIntervalSince1970: TimeInterval(observedAtMilliseconds) / 1_000),
                    payload: payload
                )
            }

        for source in sources {
            let closingIssueNodeIDs = Self.closingIssueNodeIDs(
                in: source.payload,
                pullRequestNodeID: source.pullRequestNodeID
            )
            let scopedIssueNodeIDs = try closingIssueNodeIDs.filter { nodeID in
                (try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM github_nodes
                        WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                          AND kind = 'issue'
                        """,
                    arguments: [nodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue]
                ) ?? 0) == 1
            }
            let authority = RelationReplacementAuthority(
                source: .graphQL,
                locator: .query(source.requestKey),
                scope: scope,
                feature: .pullRequests,
                streamID: source.streamID,
                repositoryID: nil,
                sourceRevision: source.sourceRevision,
                rawSnapshotID: source.rawSnapshotID,
                observedAt: source.observedAt,
                mode: .completeReconciliation
            )
            let relations = scopedIssueNodeIDs.map { issueNodeID in
                WorkRelation(
                    kind: .closes,
                    subjectNodeID: source.pullRequestNodeID,
                    objectNodeID: issueNodeID,
                    confidence: .confirmed,
                    evidence: [EvidenceReference(
                        id: EvidenceID(rawValue: "hydration-closes-\(source.pullRequestNodeID.rawValue)-\(issueNodeID.rawValue)-\(source.rawSnapshotID.rawValue)")!,
                        source: .graphQL,
                        locator: .query(source.requestKey),
                        authority: .github(scope: scope, feature: .pullRequests, streamID: source.streamID),
                        nodeID: source.pullRequestNodeID,
                        sourceRevision: source.sourceRevision,
                        rawSnapshotID: source.rawSnapshotID,
                        confidence: .confirmed,
                        confirmation: .confirmed,
                        observedAt: source.observedAt
                    )],
                    observedAt: source.observedAt
                )
            }
            try WorkRelationRepository.replace(
                relations,
                accountID: scope.accountID,
                subjectNodeID: source.pullRequestNodeID,
                authority: authority,
                in: database
            )
            // The raw GraphQL response is owned by the pull request, not the
            // closed issue. Preserve that exact origin in the inverse edge so
            // a UI can state both directions without guessing from text.
            for issueNodeID in scopedIssueNodeIDs {
                let reverse = WorkRelation(
                    kind: .closedBy,
                    subjectNodeID: issueNodeID,
                    objectNodeID: source.pullRequestNodeID,
                    confidence: .confirmed,
                    evidence: [EvidenceReference(
                        id: EvidenceID(rawValue: "hydration-closed-by-\(issueNodeID.rawValue)-\(source.pullRequestNodeID.rawValue)-\(source.rawSnapshotID.rawValue)")!,
                        source: .graphQL,
                        locator: .query(source.requestKey),
                        authority: .github(scope: scope, feature: .pullRequests, streamID: source.streamID),
                        nodeID: source.pullRequestNodeID,
                        sourceRevision: source.sourceRevision,
                        rawSnapshotID: source.rawSnapshotID,
                        confidence: .confirmed,
                        confirmation: .confirmed,
                        observedAt: source.observedAt
                    )],
                    observedAt: source.observedAt
                )
                try WorkRelationRepository.replace(
                    [reverse],
                    accountID: scope.accountID,
                    subjectNodeID: issueNodeID,
                    authority: authority,
                    in: database
                )
            }
        }
    }

    private nonisolated static func reconcileCurrentReviewContainmentRelations(
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        for source in try Self.currentReceiptContainmentSources(
            feature: .reviews,
            segmentKey: "reviewHistory",
            scope: scope,
            in: database
        ) {
            let reviewNodeIDs = try Self.scopedNodeIDs(
                sql: """
                    SELECT reviews.github_node_id
                    FROM reviews
                    JOIN github_nodes ON github_nodes.github_node_id = reviews.github_node_id
                    WHERE reviews.pull_request_node_id = ?
                      AND github_nodes.account_id = ? AND github_nodes.organization_id = ?
                    ORDER BY reviews.github_node_id
                    """,
                subject: source.pullRequestNodeID,
                scope: scope,
                in: database
            )
            try Self.persistContainment(
                kind: .containsReview, objectNodeIDs: reviewNodeIDs, source: source,
                scope: scope, in: database
            )
        }
        for source in try Self.currentReceiptContainmentSources(
            feature: .reviewThreads,
            segmentKey: "reviewThreads",
            scope: scope,
            in: database
        ) {
            let threadNodeIDs = try Self.scopedNodeIDs(
                sql: """
                    SELECT review_threads.github_node_id
                    FROM review_threads
                    JOIN github_nodes ON github_nodes.github_node_id = review_threads.github_node_id
                    WHERE review_threads.pull_request_node_id = ?
                      AND github_nodes.account_id = ? AND github_nodes.organization_id = ?
                    ORDER BY review_threads.github_node_id
                    """,
                subject: source.pullRequestNodeID,
                scope: scope,
                in: database
            )
            try Self.persistContainment(
                kind: .containsThread, objectNodeIDs: threadNodeIDs, source: source,
                scope: scope, in: database
            )
            let commentNodeIDs = try Self.scopedNodeIDs(
                sql: """
                    SELECT comments.github_node_id
                    FROM comments
                    JOIN review_threads ON review_threads.github_node_id = comments.parent_node_id
                    JOIN github_nodes ON github_nodes.github_node_id = comments.github_node_id
                    WHERE review_threads.pull_request_node_id = ?
                      AND github_nodes.account_id = ? AND github_nodes.organization_id = ?
                    ORDER BY comments.github_node_id
                    """,
                subject: source.pullRequestNodeID,
                scope: scope,
                in: database
            )
            try Self.persistContainment(
                kind: .containsComment, objectNodeIDs: commentNodeIDs, source: source,
                scope: scope, in: database
            )
        }
    }

    /// Review-history replacements are admitted only from a complete
    /// candidate traversal receipt.  The REST review response includes the
    /// reviewing actor and state, so it is the sole authority for both the
    /// generic reviewed edge and a changes-requested edge.
    private nonisolated static func reconcileCurrentReviewActorRelations(
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        for source in try currentReceiptContainmentSources(
            feature: .reviews,
            segmentKey: "reviewHistory",
            scope: scope,
            in: database
        ) {
            let rows = try Row.fetchAll(database, sql: """
                SELECT reviews.author_id, actors.github_node_id, reviews.state, reviews.submitted_at_ms
                FROM reviews
                JOIN actors ON actors.id = reviews.author_id
                WHERE reviews.pull_request_node_id = ?
                ORDER BY actors.github_node_id, reviews.github_node_id
                """, arguments: [source.pullRequestNodeID.rawValue])
            let relations = rows.flatMap { row -> [WorkRelation] in
                guard let rawActorID: String = row["github_node_id"],
                      let actorID = GitHubNodeID(rawValue: rawActorID),
                      let state: String = row["state"]
                else { return [] }
                let observedAt: Date
                if let milliseconds: Int64 = row["submitted_at_ms"] {
                    observedAt = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
                } else {
                    observedAt = source.observedAt
                }
                let kinds: [WorkRelationKind] = state == ReviewState.changesRequested.rawValue
                    ? [.reviewed, .changesRequested]
                    : [.reviewed]
                return kinds.map { kind in
                    WorkRelation(
                        kind: kind,
                        subjectNodeID: source.pullRequestNodeID,
                        objectNodeID: actorID,
                        confidence: .confirmed,
                        evidence: [EvidenceReference(
                            id: EvidenceID(rawValue: "review-\(kind.rawValue)-\(source.pullRequestNodeID.rawValue)-\(actorID.rawValue)-\(source.rawSnapshotID.rawValue)")!,
                            source: .restReview,
                            locator: .query(source.requestKey),
                            authority: .github(scope: scope, feature: .reviews, streamID: source.streamID),
                            nodeID: source.pullRequestNodeID,
                            sourceRevision: source.sourceRevision,
                            rawSnapshotID: source.rawSnapshotID,
                            confidence: .confirmed,
                            confirmation: .confirmed,
                            observedAt: observedAt
                        )],
                        observedAt: observedAt
                    )
                }
            }
            let authority = RelationReplacementAuthority(
                source: .restReview,
                locator: .query(source.requestKey),
                scope: scope,
                feature: .reviews,
                streamID: source.streamID,
                repositoryID: nil,
                sourceRevision: source.sourceRevision,
                rawSnapshotID: source.rawSnapshotID,
                observedAt: source.observedAt,
                mode: .completeReconciliation
            )
            try WorkRelationRepository.replace(
                relations,
                accountID: scope.accountID,
                subjectNodeID: source.pullRequestNodeID,
                authority: authority,
                in: database
            )
        }
    }

    private nonisolated static func reconcileCurrentProjectItemWrapperRelations(
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        let rows = try Row.fetchAll(database, sql: """
            SELECT project_item_raw_provenance.project_item_node_id,
                   project_items.content_node_id,
                   project_item_raw_provenance.source_revision,
                   project_item_raw_provenance.raw_snapshot_id,
                   raw_api_snapshots.authority_request_key,
                   raw_api_snapshots.authority_stream_id,
                   raw_api_snapshots.observed_at_ms
            FROM project_item_raw_provenance
            JOIN project_items
              ON project_items.github_node_id = project_item_raw_provenance.project_item_node_id
             AND project_items.project_node_id = project_item_raw_provenance.project_node_id
            JOIN github_nodes AS item_node
              ON item_node.github_node_id = project_items.github_node_id
            JOIN github_nodes AS content_node
              ON content_node.github_node_id = project_items.content_node_id
            JOIN raw_api_snapshots
              ON raw_api_snapshots.id = project_item_raw_provenance.raw_snapshot_id
            WHERE project_item_raw_provenance.account_id = ?
              AND project_item_raw_provenance.organization_id = ?
              AND project_item_raw_provenance.credential_revision = ?
              AND project_item_raw_provenance.capability_revision = ?
              AND item_node.account_id = ? AND item_node.organization_id = ?
              AND item_node.source_revision = project_item_raw_provenance.source_revision
              AND content_node.account_id = ? AND content_node.organization_id = ?
              AND raw_api_snapshots.account_id = ?
              AND raw_api_snapshots.github_node_id = project_item_raw_provenance.project_node_id
              AND raw_api_snapshots.authority_organization_id = ?
              AND raw_api_snapshots.authority_feature = 'projectItems'
              AND raw_api_snapshots.authority_credential_revision = project_item_raw_provenance.credential_revision
              AND raw_api_snapshots.authority_capability_revision = project_item_raw_provenance.capability_revision
              AND raw_api_snapshots.observed_at_ms = project_item_raw_provenance.observed_at_ms
              AND EXISTS (
                  SELECT 1 FROM coverage_records
                  WHERE coverage_records.account_id = raw_api_snapshots.account_id
                    AND coverage_records.organization_id = raw_api_snapshots.authority_organization_id
                    AND coverage_records.repository_id IS NULL
                    AND coverage_records.feature = raw_api_snapshots.authority_feature
                    AND coverage_records.stream_id = raw_api_snapshots.authority_stream_id
                    AND coverage_records.credential_revision = raw_api_snapshots.authority_credential_revision
                    AND coverage_records.capability_revision = raw_api_snapshots.authority_capability_revision
                    AND coverage_records.status = 'complete'
                    AND coverage_records.last_successful_at_ms >= raw_api_snapshots.observed_at_ms
              )
            ORDER BY project_item_raw_provenance.project_item_node_id
            """, arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue
            ])
        for row in rows {
            guard let itemNodeID = GitHubNodeID(rawValue: row["project_item_node_id"]),
                  let contentNodeID = GitHubNodeID(rawValue: row["content_node_id"]),
                  let sourceRevision: String = row["source_revision"],
                  let rawSnapshotID = RawAPISnapshotID(rawValue: row["raw_snapshot_id"]),
                  let requestKey: String = row["authority_request_key"],
                  let streamID = SyncStreamID(rawValue: row["authority_stream_id"]),
                  let milliseconds: Int64 = row["observed_at_ms"]
            else { continue }
            let observedAt = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            let authority = RelationReplacementAuthority(
                source: .graphQL, locator: .query(requestKey), scope: scope,
                feature: .projectItems, streamID: streamID, repositoryID: nil,
                sourceRevision: sourceRevision, rawSnapshotID: rawSnapshotID,
                observedAt: observedAt, mode: .completeReconciliation
            )
            let relation = WorkRelation(
                kind: .projectWrapsContent, subjectNodeID: itemNodeID, objectNodeID: contentNodeID,
                confidence: .confirmed,
                evidence: [EvidenceReference(
                    id: EvidenceID(rawValue: "project-wrapper-\(itemNodeID.rawValue)-\(contentNodeID.rawValue)-\(rawSnapshotID.rawValue)")!,
                    source: .graphQL, locator: .query(requestKey),
                    authority: .github(scope: scope, feature: .projectItems, streamID: streamID),
                    nodeID: itemNodeID, sourceRevision: sourceRevision, rawSnapshotID: rawSnapshotID,
                    confidence: .confirmed, confirmation: .confirmed, observedAt: observedAt
                )], observedAt: observedAt
            )
            try WorkRelationRepository.replace(
                [relation], accountID: scope.accountID, subjectNodeID: itemNodeID,
                authority: authority, in: database
            )
        }
    }

    private nonisolated static func currentReceiptContainmentSources(
        feature: CoverageFeature,
        segmentKey: String,
        scope: SynchronizationScope,
        in database: Database
    ) throws -> [ReceiptContainmentSource] {
        try Row.fetchAll(database, sql: """
            SELECT github_nodes.github_node_id, github_nodes.source_revision,
                   raw_api_snapshots.id, raw_api_snapshots.authority_request_key,
                   raw_api_snapshots.authority_stream_id, raw_api_snapshots.observed_at_ms
            FROM github_nodes
            JOIN review_candidate_complete_traversal_receipts AS receipts
              ON receipts.candidate_node_id = github_nodes.github_node_id
             AND receipts.candidate_source_revision = github_nodes.source_revision
            JOIN review_candidate_complete_traversal_pages AS pages
              ON pages.receipt_id = receipts.id
             AND pages.segment_key = ? AND pages.page_ordinal = 1
            JOIN raw_api_snapshots ON raw_api_snapshots.id = pages.raw_snapshot_id
            WHERE github_nodes.account_id = ? AND github_nodes.organization_id = ?
              AND github_nodes.kind = 'pullRequest'
              AND receipts.account_id = ? AND receipts.organization_id = ?
              AND receipts.feature = ?
              AND receipts.credential_revision = ? AND receipts.capability_revision = ?
              AND raw_api_snapshots.account_id = ?
              AND raw_api_snapshots.authority_organization_id = ?
              AND raw_api_snapshots.authority_feature = receipts.feature
              AND raw_api_snapshots.authority_stream_id = receipts.stream_id
              AND raw_api_snapshots.authority_credential_revision = receipts.credential_revision
              AND raw_api_snapshots.authority_capability_revision = receipts.capability_revision
              AND EXISTS (
                  SELECT 1 FROM coverage_records
                  WHERE coverage_records.account_id = receipts.account_id
                    AND coverage_records.organization_id = receipts.organization_id
                    AND coverage_records.repository_id IS NULL
                    AND coverage_records.feature = receipts.feature
                    AND coverage_records.stream_id = receipts.stream_id
                    AND coverage_records.credential_revision = receipts.credential_revision
                    AND coverage_records.capability_revision = receipts.capability_revision
                    AND coverage_records.status = 'complete'
                    AND coverage_records.last_successful_at_ms >= raw_api_snapshots.observed_at_ms
              )
            ORDER BY github_nodes.github_node_id, raw_api_snapshots.id
            """, arguments: [
                segmentKey, scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue, feature.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue
            ]).compactMap { row in
                guard let pullRequestNodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let sourceRevision: String = row["source_revision"],
                      let rawSnapshotID = RawAPISnapshotID(rawValue: row["id"]),
                      let requestKey: String = row["authority_request_key"],
                      let streamID = SyncStreamID(rawValue: row["authority_stream_id"]),
                      let observedAtMilliseconds: Int64 = row["observed_at_ms"]
                else { return nil }
                return ReceiptContainmentSource(
                    pullRequestNodeID: pullRequestNodeID, sourceRevision: sourceRevision,
                    rawSnapshotID: rawSnapshotID, requestKey: requestKey, streamID: streamID,
                    feature: feature,
                    observedAt: Date(timeIntervalSince1970: TimeInterval(observedAtMilliseconds) / 1_000)
                )
            }
    }

    private nonisolated static func scopedNodeIDs(
        sql: String, subject: GitHubNodeID, scope: SynchronizationScope, in database: Database
    ) throws -> [GitHubNodeID] {
        try String.fetchAll(
            database, sql: sql,
            arguments: [subject.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue]
        ).compactMap(GitHubNodeID.init(rawValue:))
    }

    private nonisolated static func persistContainment(
        kind: WorkRelationKind,
        objectNodeIDs: [GitHubNodeID],
        source: ReceiptContainmentSource,
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        let authority = RelationReplacementAuthority(
            source: .graphQL, locator: .query(source.requestKey), scope: scope,
            feature: source.feature, streamID: source.streamID, repositoryID: nil,
            sourceRevision: source.sourceRevision, rawSnapshotID: source.rawSnapshotID,
            observedAt: source.observedAt, mode: .completeReconciliation
        )
        let relations = objectNodeIDs.map { objectNodeID in
            WorkRelation(
                kind: kind, subjectNodeID: source.pullRequestNodeID, objectNodeID: objectNodeID,
                confidence: .confirmed,
                evidence: [EvidenceReference(
                    id: EvidenceID(rawValue: "receipt-\(kind.rawValue)-\(source.pullRequestNodeID.rawValue)-\(objectNodeID.rawValue)-\(source.rawSnapshotID.rawValue)")!,
                    source: .graphQL, locator: .query(source.requestKey),
                    authority: .github(scope: scope, feature: source.feature, streamID: source.streamID),
                    nodeID: source.pullRequestNodeID, sourceRevision: source.sourceRevision,
                    rawSnapshotID: source.rawSnapshotID, confidence: .confirmed,
                    confirmation: .confirmed, observedAt: source.observedAt
                )], observedAt: source.observedAt
            )
        }
        try WorkRelationRepository.replace(
            relations, accountID: scope.accountID, subjectNodeID: source.pullRequestNodeID,
            authority: authority, in: database
        )
    }

    /// Extract only the exact GraphQL selection used by hydration. Malformed,
    /// partial, or differently-shaped payloads deliberately yield no edge.
    private nonisolated static func closingIssueNodeIDs(
        in payload: Data,
        pullRequestNodeID: GitHubNodeID
    ) -> [GitHubNodeID] {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let nodes = data["nodes"] as? [[String: Any]],
              let node = nodes.first(where: { ($0["id"] as? String) == pullRequestNodeID.rawValue }),
              let references = node["closingIssuesReferences"] as? [String: Any],
              let pageInfo = references["pageInfo"] as? [String: Any],
              (pageInfo["hasNextPage"] as? Bool) == false,
              let rawNodes = references["nodes"] as? [[String: Any]]
        else { return [] }
        let identifiers = rawNodes.compactMap { $0["id"] as? String }.compactMap(GitHubNodeID.init(rawValue:))
        guard identifiers.count == rawNodes.count, Set(identifiers).count == identifiers.count else { return [] }
        return identifiers.sorted { $0.rawValue < $1.rawValue }
    }

    private nonisolated static func currentRelations(scope: SynchronizationScope, in database: Database) throws -> [WorkRelation] {
        try Row.fetchAll(database, sql: """
            SELECT relations.subject_node_id, relations.object_node_id, relations.kind, relations.observed_at_ms
            FROM relations
            JOIN github_nodes AS subject ON subject.github_node_id = relations.subject_node_id
            LEFT JOIN github_nodes AS object ON object.github_node_id = relations.object_node_id
            WHERE relations.account_id = ? AND relations.confidence = 'confirmed'
              AND subject.account_id = ? AND subject.organization_id = ?
              AND (relations.object_node_id IS NULL OR (object.account_id = ? AND object.organization_id = ?))
              AND EXISTS (
                SELECT 1 FROM relation_evidence
                JOIN raw_api_snapshots
                  ON raw_api_snapshots.id = relation_evidence.raw_snapshot_id
                WHERE relation_evidence.relation_id = relations.id
                  AND relation_evidence.authority_kind = 'github'
                  AND relation_evidence.authority_account_id = ?
                  AND relation_evidence.authority_organization_id = ?
                  AND relation_evidence.authority_credential_revision = ?
                  AND relation_evidence.authority_capability_revision = ?
                  AND EXISTS (
                      SELECT 1 FROM github_nodes AS evidence_node
                      WHERE evidence_node.github_node_id = relation_evidence.source_node_id
                        AND evidence_node.account_id = relation_evidence.authority_account_id
                        AND evidence_node.organization_id = relation_evidence.authority_organization_id
                        AND evidence_node.source_revision = relation_evidence.source_revision
                  )
                  AND relation_evidence.confirmation = 'confirmed'
                  AND relation_evidence.confidence = 'confirmed'
                  AND raw_api_snapshots.account_id = relation_evidence.authority_account_id
                  AND raw_api_snapshots.authority_organization_id = relation_evidence.authority_organization_id
                  AND raw_api_snapshots.authority_feature = relation_evidence.authority_feature
                  AND raw_api_snapshots.authority_stream_id = relation_evidence.authority_stream_id
                  AND raw_api_snapshots.authority_credential_revision = relation_evidence.authority_credential_revision
                  AND raw_api_snapshots.authority_capability_revision = relation_evidence.authority_capability_revision
                  AND (
                      raw_api_snapshots.github_node_id IS NULL
                      OR raw_api_snapshots.github_node_id = relations.subject_node_id
                      OR raw_api_snapshots.github_node_id = relation_evidence.source_node_id
                      OR EXISTS (
                          SELECT 1 FROM project_item_raw_provenance
                          WHERE project_item_raw_provenance.project_item_node_id = relations.subject_node_id
                            AND project_item_raw_provenance.raw_snapshot_id = raw_api_snapshots.id
                            AND project_item_raw_provenance.account_id = relation_evidence.authority_account_id
                            AND project_item_raw_provenance.organization_id = relation_evidence.authority_organization_id
                            AND project_item_raw_provenance.credential_revision = relation_evidence.authority_credential_revision
                            AND project_item_raw_provenance.capability_revision = relation_evidence.authority_capability_revision
                            AND project_item_raw_provenance.source_revision = subject.source_revision
                      )
                  )
                  AND EXISTS (
                      SELECT 1 FROM coverage_records
                      WHERE coverage_records.account_id = relation_evidence.authority_account_id
                        AND coverage_records.organization_id = relation_evidence.authority_organization_id
                        AND coverage_records.feature = relation_evidence.authority_feature
                        AND coverage_records.stream_id = relation_evidence.authority_stream_id
                        AND coverage_records.credential_revision = relation_evidence.authority_credential_revision
                        AND coverage_records.capability_revision = relation_evidence.authority_capability_revision
                        AND coverage_records.status = 'complete'
                        AND coverage_records.last_successful_at_ms >= raw_api_snapshots.observed_at_ms
                  )
              )
            ORDER BY relations.id
            """, arguments: [
                scope.accountID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ]).map { row in
                guard let subject = GitHubNodeID(rawValue: row["subject_node_id"]),
                      let kind = WorkRelationKind(rawValue: row["kind"]), let observed: Int64 = row["observed_at_ms"] else {
                    throw WorkRelationRepositoryError.invalidSourceAuthority
                }
                return WorkRelation(kind: kind, subjectNodeID: subject, objectNodeID: (row["object_node_id"] as String?).flatMap(GitHubNodeID.init(rawValue:)), confidence: .confirmed, evidence: [], observedAt: Date(timeIntervalSince1970: TimeInterval(observed) / 1_000))
            }
    }

    private nonisolated static func currentDecisions(scope: SynchronizationScope, in database: Database) throws -> [WorkItemGroupingDecision] {
        try Row.fetchAll(database, sql: """
            SELECT grouping_decisions.source_node_id, grouping_decisions.destination_node_id,
                   grouping_decisions.relation, grouping_decisions.strength,
                   grouping_decisions.evidence_json, grouping_decisions.decided_at_ms
            FROM grouping_decisions
            JOIN github_nodes AS source ON source.github_node_id = grouping_decisions.source_node_id
            JOIN github_nodes AS destination ON destination.github_node_id = grouping_decisions.destination_node_id
            WHERE source.account_id = ? AND source.organization_id = ?
              AND destination.account_id = ? AND destination.organization_id = ?
            ORDER BY grouping_decisions.source_node_id, grouping_decisions.destination_node_id
            """, arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue]).map { row in
                guard let source = GitHubNodeID(rawValue: row["source_node_id"]),
                      let destination = GitHubNodeID(rawValue: row["destination_node_id"]),
                      let relation = WorkRelationKind(rawValue: row["relation"]),
                      let strength = GroupingStrength(rawValue: row["strength"]),
                      let decided: Int64 = row["decided_at_ms"],
                      let data: Data = row["evidence_json"],
                      let evidence = try? JSONDecoder().decode([EvidenceReference].self, from: data)
                else { throw WorkItemGroupingDecisionRepositoryError.invalidPersistedData }
                guard (strength == .userConfirmed || strength == .userSeparated),
                      evidence.allSatisfy({ evidence in
                          evidence.confirmation == .confirmed
                              && evidence.confidence == .confirmed
                              && evidence.authority == .localWorkflow(accountID: scope.accountID, organizationID: scope.organizationID)
                      })
                else { return nil }
                return WorkItemGroupingDecision(sourceNodeID: source, destinationNodeID: destination, relation: relation, strength: strength, evidence: evidence, decidedAt: Date(timeIntervalSince1970: TimeInterval(decided) / 1_000))
            }.compactMap { $0 }
    }

    private nonisolated static func contextLinks(for members: [GitHubNodeID], relations: [WorkRelation]) -> [WorkItemContextReference] {
        let memberSet = Set(members)
        return relations.compactMap { relation in
            guard let object = relation.objectNodeID,
                  relation.kind != .closes, relation.kind != .closedBy,
                  relation.kind != .linkedPullRequest, relation.kind != .containsReview,
                  relation.kind != .containsThread, relation.kind != .containsComment,
                  relation.kind != .projectWrapsContent,
                  relation.kind != .parentOf, relation.kind != .childOf,
                  memberSet.contains(relation.subjectNodeID), !memberSet.contains(object)
            else { return nil }
            return WorkItemContextReference(nodeID: object, relation: relation.kind)
        }.reduce(into: [String: WorkItemContextReference]()) { $0["\($1.nodeID.rawValue)\u{0}\($1.relation.rawValue)"] = $1 }.values.sorted { $0.nodeID.rawValue < $1.nodeID.rawValue }
    }

    private nonisolated static func memberRole(
        nodeID: GitHubNodeID,
        target: GitHubNodeID,
        in relations: [WorkRelation]
    ) -> WorkItemMemberRole {
        guard nodeID != target else { return .primary }
        let adjacent = relations.first {
            ($0.subjectNodeID == nodeID || $0.objectNodeID == nodeID)
                && ($0.subjectNodeID == target || $0.objectNodeID == target)
        }
        switch adjacent?.kind {
        case .closes, .closedBy: return .closingPullRequest
        case .containsReview: return .review
        case .containsThread: return .reviewThread
        case .containsComment, .parentOf, .childOf: return .comment
        case .projectWrapsContent: return .projectItem
        default: return .linkedIssue
        }
    }

    private nonisolated static func sourceRevision(scope: SynchronizationScope, in database: Database) throws -> String {
        let pairs = try Row.fetchAll(database, sql: "SELECT work_items.id, github_nodes.source_revision FROM work_items JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id WHERE work_items.account_id = ? AND work_items.organization_id = ? ORDER BY work_items.id", arguments: [scope.accountID.rawValue, scope.organizationID.rawValue])
        let revisions = try Dictionary(uniqueKeysWithValues: pairs.map { row -> (WorkItemID, String) in
            guard let id = WorkItemID(rawValue: row["id"]), let revision: String = row["source_revision"], !revision.isEmpty else { throw WorkItemGraphRepositoryError.workItemScopeMismatch }
            return (id, revision)
        })
        return DerivedIntelligenceSourceRevision.aggregate(primaryRevisions: revisions, supplementalSources: try DerivedIntelligenceSourceRevision.supplementalSources(for: scope, in: database))
    }

    private nonisolated static func recordRun(scope: SynchronizationScope, sourceRevision: String, at date: Date, in database: Database) throws {
        try database.execute(sql: "INSERT INTO work_item_graph_runs (account_id, organization_id, credential_revision, capability_revision, source_revision, projected_at_ms) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(account_id, organization_id) DO UPDATE SET credential_revision = excluded.credential_revision, capability_revision = excluded.capability_revision, source_revision = excluded.source_revision, projected_at_ms = excluded.projected_at_ms", arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue, sourceRevision, Int64(date.timeIntervalSince1970 * 1_000)])
    }

    private nonisolated static func placeholders(_ values: [String]) -> String { Array(repeating: "?", count: values.count).joined(separator: ", ") }
}

/// Durable visibility mapping for a graph projection. Each constituent keeps
/// its original Work Item row and its action/workflow history; only the
/// canonical representative is emitted by the visible Work Item query.
private enum WorkItemCanonicalGroupRepository {
    typealias Canonicalization = OrganizationWorkItemGraphProjectionService.ProjectionResult.Canonicalization

    static func replace(
        _ canonicalizations: [Canonicalization],
        scope: SynchronizationScope,
        sourceRevision: String,
        at date: Date,
        in database: Database
    ) throws {
        let constituentIDs = canonicalizations.map(\.constituentWorkItemID)
        guard Set(constituentIDs).count == constituentIDs.count,
              canonicalizations.allSatisfy({ $0.constituentWorkItemID.rawValue.count <= 512 && $0.canonicalWorkItemID.rawValue.count <= 512 })
        else {
            throw WorkItemGraphRepositoryError.workItemScopeMismatch
        }
        let expectedCount = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM work_items WHERE account_id = ? AND organization_id = ?",
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        ) ?? 0
        guard expectedCount == canonicalizations.count else {
            throw WorkItemGraphRepositoryError.workItemScopeMismatch
        }
        for canonicalization in canonicalizations {
            let valid = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM work_items AS constituent
                    JOIN work_items AS canonical ON canonical.id = ?
                    WHERE constituent.id = ?
                      AND constituent.account_id = ? AND constituent.organization_id = ?
                      AND canonical.account_id = constituent.account_id
                      AND canonical.organization_id = constituent.organization_id
                    """,
                arguments: [
                    canonicalization.canonicalWorkItemID.rawValue,
                    canonicalization.constituentWorkItemID.rawValue,
                    scope.accountID.rawValue,
                    scope.organizationID.rawValue
                ]
            ) ?? 0
            guard valid == 1 else { throw WorkItemGraphRepositoryError.workItemScopeMismatch }
        }
        try database.execute(
            sql: "DELETE FROM work_item_group_memberships WHERE account_id = ? AND organization_id = ?",
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        for canonicalization in canonicalizations.sorted(by: {
            $0.constituentWorkItemID.rawValue < $1.constituentWorkItemID.rawValue
        }) {
            try database.execute(
                sql: """
                    INSERT INTO work_item_group_memberships (
                        account_id, organization_id, constituent_work_item_id,
                        canonical_work_item_id, credential_revision, capability_revision,
                        source_revision, projected_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    scope.accountID.rawValue,
                    scope.organizationID.rawValue,
                    canonicalization.constituentWorkItemID.rawValue,
                    canonicalization.canonicalWorkItemID.rawValue,
                    scope.credentialRevision.rawValue,
                    scope.capabilityRevision.rawValue,
                    sourceRevision,
                    Int64(date.timeIntervalSince1970 * 1_000)
                ]
            )
        }
    }
}
