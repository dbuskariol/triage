import Foundation

struct RoleDiscoverySyncResult: Sendable {
    let workItemIDs: [WorkItemID]
    let candidateNodeIDs: Set<GitHubNodeID>
}

actor RoleDiscoverySynchronizer {
    private let searchClient: GitHubIssueSearchClient
    private let workItemRepository: WorkItemRepository
    private let shardRepository: SyncShardRepository
    private let clock: @Sendable () -> Date

    init(
        searchClient: GitHubIssueSearchClient,
        workItemRepository: WorkItemRepository,
        shardRepository: SyncShardRepository,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.searchClient = searchClient
        self.workItemRepository = workItemRepository
        self.shardRepository = shardRepository
        self.clock = clock
    }

    func synchronize(
        plan: RoleDiscoveryPlan,
        accountID: AccountID,
        accountNodeID: GitHubNodeID,
        organizationID: OrganizationID,
        githubOrganizationID: UInt64,
        streamID: SyncStreamID,
        searchRange: SearchTimeRange,
        accessibleRepositoryNames: [String],
        repositoryID: @escaping @Sendable (GitHubIssueSearchItem) -> RepositoryID?
    ) async throws -> RoleDiscoverySyncResult {
        let accumulator = RoleDiscoveryAccumulator()
        let shardExecutor = SearchShardExecutor(
            client: searchClient,
            shardRepository: shardRepository,
            clock: clock
        )
        for query in plan.openQueries + plan.recentClosedQueries {
            try await shardExecutor.execute(
                query: query,
                range: searchRange,
                streamID: streamID,
                accountID: accountID,
                accessibleRepositoryNames: accessibleRepositoryNames
            ) { [self] response, boundedQuery, page in
                try await self.throwForSSORequirement(
                    in: response.ssoHeader,
                    githubOrganizationID: githubOrganizationID
                )
                return try await self.preparePageWrite(
                    response,
                    query: boundedQuery,
                    page: page,
                    accountID: accountID,
                    organizationID: organizationID,
                    accountNodeID: accountNodeID,
                    relationship: query.relationship,
                    repositoryID: repositoryID,
                    accumulator: accumulator
                )
            }
        }

        let candidateNodeIDs = await accumulator.committedNodeIDs()
        return RoleDiscoverySyncResult(
            workItemIDs: try await workItemRepository.identifiers(
                for: candidateNodeIDs,
                accountID: accountID
            ),
            candidateNodeIDs: candidateNodeIDs
        )
    }

    private func preparePageWrite(
        _ response: GitHubResponse<GitHubIssueSearchPage>,
        query: GitHubIssueSearchQuery,
        page: Int,
        accountID: AccountID,
        organizationID: OrganizationID,
        accountNodeID: GitHubNodeID,
        relationship: GitHubIssueSearchRelationship,
        repositoryID: @escaping @Sendable (GitHubIssueSearchItem) -> RepositoryID?,
        accumulator: RoleDiscoveryAccumulator
    ) async throws -> PreparedSearchShardPageWrite {
        let observedAt = clock()
        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: accountID,
            githubNodeID: nil,
            endpoint: "/search/issues?q=\(query.value)&page=\(page)",
            eTag: response.etag,
            parserVersion: 1,
            observedAt: observedAt,
            payload: response.payload
        )
        let relationships = await accumulator.combinedRelationships(
            for: response.value,
            adding: relationship
        )
        var entries: [NormalizedPageEntry] = []
        var failures: [NormalizationFailure] = []
        for item in response.value.items {
            do {
                let node = try GitHubSearchNormalizer.normalize(
                    item,
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: repositoryID(item),
                    observedAt: observedAt
                )
                entries.append(
                    NormalizedPageEntry(
                        node: node,
                        relationships: relationships[node.nodeID.rawValue] ?? []
                    )
                )
            } catch let error as GitHubSearchNormalizationError {
                failures.append(
                    NormalizationFailure(
                        id: UUID(),
                        accountID: accountID,
                        rawSnapshotID: snapshot.id,
                        githubNodeID: nil,
                        endpoint: searchEndpoint(for: item),
                        parserVersion: 1,
                        occurredAt: observedAt,
                        redactedDiagnostic: Self.redactedDiagnostic(for: error)
                    )
                )
            }
        }
        entries.sort { $0.node.nodeID.rawValue < $1.node.nodeID.rawValue }
        let preparedEntries = entries
        let preparedFailures = failures
        let committedNodes = preparedEntries.map(\.node)

        return PreparedSearchShardPageWrite(
            write: {
                database in
                try RawAPISnapshotRepository.save(snapshot, in: database)
                for entry in preparedEntries {
                    try GitHubNodeRepository.save(entry.node, in: database)
                    let workItemID = try WorkItemRepository.ensureWorkItem(
                        for: entry.node,
                        in: database
                    )
                    try WorkRelationRepository.replace(
                        Self.discoveryRelations(
                            relationships: entry.relationships,
                            node: entry.node,
                            accountNodeID: accountNodeID,
                            observedAt: observedAt
                        ),
                        accountID: accountID,
                        subjectNodeID: entry.node.nodeID,
                        in: database
                    )
                    try AttentionReasonRepository.replaceDiscoveryReasons(
                        workItemID: workItemID,
                        reasons: Self.discoveryReasons(
                            relationships: entry.relationships,
                            node: entry.node,
                            evaluatedAt: observedAt
                        ),
                        accountID: accountID,
                        in: database
                    )
                }
                for failure in preparedFailures {
                    try NormalizationFailureRepository.record(failure, in: database)
                }
            },
            didCommit: {
                await accumulator.storeCommitted(
                    relationship: relationship,
                    nodes: committedNodes
                )
            }
        )
    }

    private func searchEndpoint(for item: GitHubIssueSearchItem) -> String {
        "/search/issues"
    }

    private actor RoleDiscoveryAccumulator {
        private var nodeIDs: Set<GitHubNodeID> = []
        private var relationshipsByNodeID: [String: Set<GitHubIssueSearchRelationship>] = [:]

        func combinedRelationships(
            for page: GitHubIssueSearchPage,
            adding relationship: GitHubIssueSearchRelationship
        ) -> [String: Set<GitHubIssueSearchRelationship>] {
            var combined: [String: Set<GitHubIssueSearchRelationship>] = [:]
            for item in page.items {
                combined[item.nodeID] = relationshipsByNodeID[item.nodeID, default: []]
                combined[item.nodeID, default: []].insert(relationship)
            }
            return combined
        }

        func storeCommitted(
            relationship: GitHubIssueSearchRelationship,
            nodes: [NormalizedGitHubNode]
        ) {
            for node in nodes {
                relationshipsByNodeID[node.nodeID.rawValue, default: []].insert(relationship)
            }
            nodeIDs.formUnion(nodes.map(\.nodeID))
        }

        func committedNodeIDs() -> Set<GitHubNodeID> {
            nodeIDs
        }
    }

    private struct NormalizedPageEntry: Sendable {
        let node: NormalizedGitHubNode
        let relationships: Set<GitHubIssueSearchRelationship>
    }

    private nonisolated static func redactedDiagnostic(for error: GitHubSearchNormalizationError) -> String {
        switch error {
        case .invalidNodeID:
            "Search result contains an invalid GitHub node identifier."
        case .unknownState:
            "Search result contains an unsupported item state."
        }
    }

    private func throwForSSORequirement(
        in header: GitHubSSOHeader?,
        githubOrganizationID: UInt64
    ) throws {
        if let header = header?.scoped(to: githubOrganizationID) {
            throw OrganizationRefreshError.ssoRequirement(header)
        }
    }

    private nonisolated static func discoveryReasons(
        relationships: Set<GitHubIssueSearchRelationship>,
        node: NormalizedGitHubNode,
        evaluatedAt: Date
    ) -> [AttentionReason] {
        let definitions: [(GitHubIssueSearchRelationship, Int, String, String)] = [
            (.reviewRequested, 1_000, "Review requested", "You are currently requested to review this pull request."),
            (.assigned, 850, "Assigned to you", "You are currently assigned to this work."),
            (.mentioned, 750, "Mentioned", "You were directly mentioned in this work.")
        ]
        return definitions.compactMap { relationship, strength, title, explanation in
            guard relationships.contains(relationship) else { return nil }
            let evidence = EvidenceReference(
                id: EvidenceID(rawValue: "discovery-\(relationship.qualifier)-\(node.nodeID.rawValue)")!,
                source: .restSearch,
                nodeID: node.nodeID,
                sourceRevision: node.sourceRevision,
                observedAt: evaluatedAt
            )
            return AttentionReason(
                id: "discovery.\(relationship.qualifier)-\(node.nodeID.rawValue)",
                category: .directResponsibility,
                ruleID: "discovery.\(relationship.qualifier)",
                ruleVersion: 1,
                strength: strength,
                title: title,
                explanation: explanation,
                evidence: [evidence],
                evaluatedAt: evaluatedAt
            )
        }
    }

    private nonisolated static func discoveryRelations(
        relationships: Set<GitHubIssueSearchRelationship>,
        node: NormalizedGitHubNode,
        accountNodeID: GitHubNodeID,
        observedAt: Date
    ) -> [WorkRelation] {
        relationships.compactMap { relationship in
            let kind: WorkRelationKind? = switch relationship {
            case .involves:
                nil
            case .authored:
                WorkRelationKind.authored
            case .assigned:
                .assigned
            case .mentioned:
                .mentioned
            case .commented:
                .commented
            case .reviewRequested:
                .reviewRequestedDirectly
            case .reviewInvolves:
                .reviewed
            }
            guard let kind else {
                return nil
            }
            let evidence = EvidenceReference(
                id: EvidenceID(rawValue: "discovery-\(relationship.qualifier)-\(node.nodeID.rawValue)")!,
                source: .restSearch,
                nodeID: node.nodeID,
                sourceRevision: node.sourceRevision,
                observedAt: observedAt
            )
            return WorkRelation(
                kind: kind,
                subjectNodeID: node.nodeID,
                objectNodeID: accountNodeID,
                confidence: .confirmed,
                evidence: [evidence],
                observedAt: observedAt
            )
        }.sorted { lhs, rhs in
            lhs.kind.rawValue < rhs.kind.rawValue
        }
    }
}
