import CryptoKit
import Foundation

enum SearchShardExecutorError: Error, Equatable, Sendable {
    case inaccessibleRepositoryPartition
    case incompleteSearchPage
    case invalidPersistedCursor
}

actor SearchShardExecutor {
    typealias PageHandler = @Sendable (
        GitHubResponse<GitHubIssueSearchPage>,
        GitHubIssueSearchQuery,
        Int
    ) async throws -> Void

    private let client: any GitHubIssueSearchExecuting
    private let shardRepository: SyncShardRepository
    private let planner: SearchShardPlanner
    private let clock: @Sendable () -> Date

    init(
        client: any GitHubIssueSearchExecuting,
        shardRepository: SyncShardRepository,
        planner: SearchShardPlanner = SearchShardPlanner(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.shardRepository = shardRepository
        self.planner = planner
        self.clock = clock
    }

    func execute(
        query: GitHubIssueSearchQuery,
        range: SearchTimeRange,
        streamID: SyncStreamID,
        accountID: AccountID,
        accessibleRepositoryNames: [String],
        handlePage: @escaping PageHandler
    ) async throws {
        let boundedQuery = try query.bounded(to: range)
        try await executeShard(
            query: boundedQuery,
            range: range,
            streamID: streamID,
            accountID: accountID,
            accessibleRepositoryNames: accessibleRepositoryNames,
            handlePage: handlePage
        )
    }

    private func executeShard(
        query: GitHubIssueSearchQuery,
        range: SearchTimeRange,
        streamID: SyncStreamID,
        accountID: AccountID,
        accessibleRepositoryNames: [String],
        handlePage: @escaping PageHandler
    ) async throws {
        try Task.checkCancellation()
        let shardID = Self.shardID(
            streamID: streamID,
            query: query,
            range: range
        )
        let priorShard = try await shardRepository.shards(
            for: streamID,
            accountID: accountID
        ).first { $0.id == shardID }
        // Completed descendants are replayed when resuming an unfinished parent
        // so the caller can reconstruct its in-memory deduplication state.
        let resumeCursor = priorShard?.state == .completed ? nil : priorShard?.pageCursor
        var shard = running(
            priorShard ?? SyncShard(
                id: shardID,
                streamID: streamID,
                queryKind: query.value,
                intervalStart: range.start,
                intervalEnd: range.end,
                pageCursor: nil,
                state: .pending,
                completedAt: nil
            ),
            cursor: resumeCursor
        )
        try await shardRepository.save(shard, accountID: accountID)

        do {
            let firstResponse = try await client.searchResponse(query, page: 1)
            let firstPage = firstResponse.value
            switch planner.nextPlan(
                range: range,
                totalCount: firstPage.totalCount,
                incompleteResults: firstPage.incompleteResults
            ) {
            case .complete:
                let pageCount = max(1, Int(ceil(Double(firstPage.totalCount) / 100)))
                let resumePage = try pageAfter(cursor: shard.pageCursor, pageCount: pageCount)
                if resumePage == 1 {
                    try await handlePage(firstResponse, query, 1)
                }
                if pageCount == 1 || resumePage > pageCount {
                    shard = completed(shard, cursor: String(pageCount))
                    try await shardRepository.save(shard, accountID: accountID)
                    return
                }
                if resumePage == 1, pageCount > 1 {
                    shard = running(shard, cursor: "1")
                    try await shardRepository.save(shard, accountID: accountID)
                }
                for page in max(2, resumePage)...pageCount {
                    try Task.checkCancellation()
                    let response = try await client.searchResponse(query, page: page)
                    guard !response.value.incompleteResults else {
                        throw SearchShardExecutorError.incompleteSearchPage
                    }
                    try await handlePage(response, query, page)
                    shard = running(shard, cursor: String(page))
                    try await shardRepository.save(shard, accountID: accountID)
                }
                shard = completed(shard, cursor: String(pageCount))
                try await shardRepository.save(shard, accountID: accountID)

            case let .split(firstRange, secondRange):
                shard = running(shard, cursor: "partitioned")
                try await shardRepository.save(shard, accountID: accountID)
                try await executeShard(
                    query: try query.bounded(to: firstRange),
                    range: firstRange,
                    streamID: streamID,
                    accountID: accountID,
                    accessibleRepositoryNames: accessibleRepositoryNames,
                    handlePage: handlePage
                )
                try await executeShard(
                    query: try query.bounded(to: secondRange),
                    range: secondRange,
                    streamID: streamID,
                    accountID: accountID,
                    accessibleRepositoryNames: accessibleRepositoryNames,
                    handlePage: handlePage
                )
                shard = completed(shard, cursor: "partitioned")
                try await shardRepository.save(shard, accountID: accountID)

            case .repositoryPartitionRequired:
                guard !accessibleRepositoryNames.isEmpty else {
                    throw SearchShardExecutorError.inaccessibleRepositoryPartition
                }
                shard = running(shard, cursor: "partitioned")
                try await shardRepository.save(shard, accountID: accountID)
                for repositoryName in accessibleRepositoryNames.sorted() {
                    try await executeShard(
                        query: try query.scoped(
                            to: repositoryName,
                            updatedRange: range
                        ),
                        range: range,
                        streamID: streamID,
                        accountID: accountID,
                        accessibleRepositoryNames: [],
                        handlePage: handlePage
                    )
                }
                shard = completed(shard, cursor: "partitioned")
                try await shardRepository.save(shard, accountID: accountID)
            }
        } catch {
            if !(error is CancellationError) {
                shard = failed(shard)
                try await shardRepository.save(shard, accountID: accountID)
            }
            throw error
        }
    }

    private func running(_ shard: SyncShard, cursor: String?) -> SyncShard {
        SyncShard(
            id: shard.id,
            streamID: shard.streamID,
            queryKind: shard.queryKind,
            intervalStart: shard.intervalStart,
            intervalEnd: shard.intervalEnd,
            pageCursor: cursor,
            state: .running,
            completedAt: nil
        )
    }

    private func completed(_ shard: SyncShard, cursor: String?) -> SyncShard {
        SyncShard(
            id: shard.id,
            streamID: shard.streamID,
            queryKind: shard.queryKind,
            intervalStart: shard.intervalStart,
            intervalEnd: shard.intervalEnd,
            pageCursor: cursor,
            state: .completed,
            completedAt: clock()
        )
    }

    private func failed(_ shard: SyncShard) -> SyncShard {
        SyncShard(
            id: shard.id,
            streamID: shard.streamID,
            queryKind: shard.queryKind,
            intervalStart: shard.intervalStart,
            intervalEnd: shard.intervalEnd,
            pageCursor: shard.pageCursor,
            state: .failed,
            completedAt: nil
        )
    }

    private func pageAfter(cursor: String?, pageCount: Int) throws -> Int {
        guard let cursor else {
            return 1
        }
        guard let completedPage = Int(cursor),
              completedPage >= 1,
              completedPage <= pageCount
        else {
            throw SearchShardExecutorError.invalidPersistedCursor
        }
        return completedPage + 1
    }

    private nonisolated static func shardID(
        streamID: SyncStreamID,
        query: GitHubIssueSearchQuery,
        range: SearchTimeRange
    ) -> SyncShardID {
        let material = [
            streamID.rawValue,
            query.value,
            String(range.start.timeIntervalSince1970),
            String(range.end.timeIntervalSince1970)
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
        let rawValue = digest.map { String(format: "%02x", $0) }.joined()
        return SyncShardID(rawValue: rawValue)!
    }
}
