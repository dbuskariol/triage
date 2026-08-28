import Foundation

enum RoleDiscoverySyncError: Error, Equatable, Sendable {
    case shardingRequired
    case snapshotProvenanceMissing
}

struct RoleDiscoverySyncResult: Sendable {
    let workItemIDs: [WorkItemID]
    let candidateNodeIDs: Set<GitHubNodeID>
}

actor RoleDiscoverySynchronizer {
    private let searchClient: GitHubIssueSearchClient
    private let nodeRepository: GitHubNodeRepository
    private let workItemRepository: WorkItemRepository
    private let relationRepository: WorkRelationRepository
    private let attentionRepository: AttentionReasonRepository
    private let rawSnapshotRepository: RawAPISnapshotRepository
    private let normalizationFailureRepository: NormalizationFailureRepository
    private let shardRepository: SyncShardRepository
    private let clock: @Sendable () -> Date

    init(
        searchClient: GitHubIssueSearchClient,
        nodeRepository: GitHubNodeRepository,
        workItemRepository: WorkItemRepository,
        relationRepository: WorkRelationRepository,
        attentionRepository: AttentionReasonRepository,
        rawSnapshotRepository: RawAPISnapshotRepository,
        normalizationFailureRepository: NormalizationFailureRepository,
        shardRepository: SyncShardRepository,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.searchClient = searchClient
        self.nodeRepository = nodeRepository
        self.workItemRepository = workItemRepository
        self.relationRepository = relationRepository
        self.attentionRepository = attentionRepository
        self.rawSnapshotRepository = rawSnapshotRepository
        self.normalizationFailureRepository = normalizationFailureRepository
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
                let snapshotID = try await self.persist(
                    response,
                    query: boundedQuery,
                    page: page,
                    accountID: accountID
                )
                await accumulator.store(
                    response.value,
                    relationship: query.relationship,
                    snapshotID: snapshotID
                )
            }
        }

        let observedAt = clock()
        let results = await accumulator.results()
        var nodes: [NormalizedGitHubNode] = []
        for item in results.itemsByNodeID.values.sorted(by: { $0.nodeID < $1.nodeID }) {
            do {
                nodes.append(
                    try GitHubSearchNormalizer.normalize(
                        item,
                        accountID: accountID,
                        organizationID: organizationID,
                        repositoryID: repositoryID(item),
                        observedAt: observedAt
                    )
                )
            } catch let error as GitHubSearchNormalizationError {
                guard let snapshotID = results.snapshotsByNodeID[item.nodeID] else {
                    throw RoleDiscoverySyncError.snapshotProvenanceMissing
                }
                try await normalizationFailureRepository.record(
                    NormalizationFailure(
                        id: UUID(),
                        accountID: accountID,
                        rawSnapshotID: snapshotID,
                        githubNodeID: GitHubNodeID(rawValue: item.nodeID),
                        endpoint: searchEndpoint(for: item),
                        parserVersion: 1,
                        occurredAt: observedAt,
                        redactedDiagnostic: redactedDiagnostic(for: error)
                    )
                )
            }
        }
        nodes.sort { $0.nodeID.rawValue < $1.nodeID.rawValue }
        var workItemIDs: [WorkItemID] = []
        for node in nodes {
            try await nodeRepository.save(node)
            let workItemID = try await workItemRepository.ensureWorkItem(for: node)
            try await relationRepository.replace(
                discoveryRelations(
                    relationships: results.relationshipsByNodeID[node.nodeID.rawValue] ?? [],
                    node: node,
                    accountNodeID: accountNodeID,
                    observedAt: observedAt
                ),
                accountID: accountID,
                subjectNodeID: node.nodeID
            )
            try await attentionRepository.replaceDiscoveryReasons(
                workItemID: workItemID,
                reasons: discoveryReasons(
                    relationships: results.relationshipsByNodeID[node.nodeID.rawValue] ?? [],
                    node: node,
                    evaluatedAt: observedAt
                )
            )
            workItemIDs.append(workItemID)
        }
        return RoleDiscoverySyncResult(
            workItemIDs: workItemIDs,
            candidateNodeIDs: Set(nodes.map(\.nodeID))
        )
    }

    private func persist(
        _ response: GitHubResponse<GitHubIssueSearchPage>,
        query: GitHubIssueSearchQuery,
        page: Int,
        accountID: AccountID
    ) async throws -> RawAPISnapshotID {
        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: accountID,
            githubNodeID: nil,
            endpoint: "/search/issues?q=\(query.value)&page=\(page)",
            eTag: response.etag,
            parserVersion: 1,
            observedAt: clock(),
            payload: response.payload
        )
        try await rawSnapshotRepository.save(snapshot)
        return snapshot.id
    }

    private func searchEndpoint(for item: GitHubIssueSearchItem) -> String {
        "/search/issues"
    }

    private actor RoleDiscoveryAccumulator {
        private var itemsByNodeID: [String: GitHubIssueSearchItem] = [:]
        private var relationshipsByNodeID: [String: Set<GitHubIssueSearchRelationship>] = [:]
        private var snapshotsByNodeID: [String: RawAPISnapshotID] = [:]

        func store(
            _ page: GitHubIssueSearchPage,
            relationship: GitHubIssueSearchRelationship,
            snapshotID: RawAPISnapshotID
        ) {
            for item in page.items {
                itemsByNodeID[item.nodeID] = item
                relationshipsByNodeID[item.nodeID, default: []].insert(relationship)
                snapshotsByNodeID[item.nodeID] = snapshotID
            }
        }

        func results() -> (
            itemsByNodeID: [String: GitHubIssueSearchItem],
            relationshipsByNodeID: [String: Set<GitHubIssueSearchRelationship>],
            snapshotsByNodeID: [String: RawAPISnapshotID]
        ) {
            (itemsByNodeID, relationshipsByNodeID, snapshotsByNodeID)
        }
    }

    private func redactedDiagnostic(for error: GitHubSearchNormalizationError) -> String {
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

    private func discoveryReasons(
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

    private func discoveryRelations(
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
