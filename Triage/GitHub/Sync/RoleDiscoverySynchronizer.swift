import Foundation

enum RoleDiscoverySyncError: Error, Equatable, Sendable {
    case shardingRequired
}

actor RoleDiscoverySynchronizer {
    private let searchClient: GitHubIssueSearchClient
    private let nodeRepository: GitHubNodeRepository
    private let workItemRepository: WorkItemRepository
    private let clock: @Sendable () -> Date

    init(
        searchClient: GitHubIssueSearchClient,
        nodeRepository: GitHubNodeRepository,
        workItemRepository: WorkItemRepository,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.searchClient = searchClient
        self.nodeRepository = nodeRepository
        self.workItemRepository = workItemRepository
        self.clock = clock
    }

    func synchronize(
        plan: RoleDiscoveryPlan,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: @escaping @Sendable (GitHubIssueSearchItem) -> RepositoryID?
    ) async throws -> [WorkItemID] {
        var itemsByNodeID: [String: GitHubIssueSearchItem] = [:]
        for query in plan.openQueries + plan.recentClosedQueries {
            let firstPage = try await searchClient.search(query)
            guard !firstPage.incompleteResults,
                  firstPage.totalCount <= SearchShardPlanner.maximumResults
            else {
                throw RoleDiscoverySyncError.shardingRequired
            }
            let pageCount = max(1, Int(ceil(Double(firstPage.totalCount) / 100)))
            for page in 1...pageCount {
                let result = page == 1 ? firstPage : try await searchClient.search(query, page: page)
                guard !result.incompleteResults else {
                    throw RoleDiscoverySyncError.shardingRequired
                }
                for item in result.items {
                    itemsByNodeID[item.nodeID] = item
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
            workItemIDs.append(try await workItemRepository.ensureWorkItem(for: node))
        }
        return workItemIDs
    }
}
