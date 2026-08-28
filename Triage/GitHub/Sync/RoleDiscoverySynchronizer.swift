import Foundation

enum RoleDiscoverySyncError: Error, Equatable, Sendable {
    case shardingRequired
}

actor RoleDiscoverySynchronizer {
    private let searchClient: GitHubIssueSearchClient
    private let nodeRepository: GitHubNodeRepository
    private let workItemRepository: WorkItemRepository
    private let relationRepository: WorkRelationRepository
    private let attentionRepository: AttentionReasonRepository
    private let clock: @Sendable () -> Date

    init(
        searchClient: GitHubIssueSearchClient,
        nodeRepository: GitHubNodeRepository,
        workItemRepository: WorkItemRepository,
        relationRepository: WorkRelationRepository,
        attentionRepository: AttentionReasonRepository,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.searchClient = searchClient
        self.nodeRepository = nodeRepository
        self.workItemRepository = workItemRepository
        self.relationRepository = relationRepository
        self.attentionRepository = attentionRepository
        self.clock = clock
    }

    func synchronize(
        plan: RoleDiscoveryPlan,
        accountID: AccountID,
        accountNodeID: GitHubNodeID,
        organizationID: OrganizationID,
        githubOrganizationID: UInt64,
        repositoryID: @escaping @Sendable (GitHubIssueSearchItem) -> RepositoryID?
    ) async throws -> [WorkItemID] {
        var itemsByNodeID: [String: GitHubIssueSearchItem] = [:]
        var relationshipsByNodeID: [String: Set<GitHubIssueSearchRelationship>] = [:]
        for query in plan.openQueries + plan.recentClosedQueries {
            let firstResponse = try await searchClient.searchResponse(query)
            try throwForSSORequirement(
                in: firstResponse.ssoHeader,
                githubOrganizationID: githubOrganizationID
            )
            let firstPage = firstResponse.value
            guard !firstPage.incompleteResults,
                  firstPage.totalCount <= SearchShardPlanner.maximumResults
            else {
                throw RoleDiscoverySyncError.shardingRequired
            }
            let pageCount = max(1, Int(ceil(Double(firstPage.totalCount) / 100)))
            for page in 1...pageCount {
                let result: GitHubIssueSearchPage
                if page == 1 {
                    result = firstPage
                } else {
                    let response = try await searchClient.searchResponse(query, page: page)
                    try throwForSSORequirement(
                        in: response.ssoHeader,
                        githubOrganizationID: githubOrganizationID
                    )
                    result = response.value
                }
                guard !result.incompleteResults else {
                    throw RoleDiscoverySyncError.shardingRequired
                }
                for item in result.items {
                    itemsByNodeID[item.nodeID] = item
                    relationshipsByNodeID[item.nodeID, default: []].insert(query.relationship)
                }
            }
        }

        let observedAt = clock()
        let nodes = try itemsByNodeID.values
            .map {
                try GitHubSearchNormalizer.normalize(
                    $0,
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: repositoryID($0),
                    observedAt: observedAt
                )
            }
            .sorted { $0.nodeID.rawValue < $1.nodeID.rawValue }
        var workItemIDs: [WorkItemID] = []
        for node in nodes {
            try await nodeRepository.save(node)
            let workItemID = try await workItemRepository.ensureWorkItem(for: node)
            try await relationRepository.replace(
                discoveryRelations(
                    relationships: relationshipsByNodeID[node.nodeID.rawValue] ?? [],
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
                    relationships: relationshipsByNodeID[node.nodeID.rawValue] ?? [],
                    node: node,
                    evaluatedAt: observedAt
                )
            )
            workItemIDs.append(workItemID)
        }
        return workItemIDs
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
