import CryptoKit
import Foundation
import GRDB

enum SearchShardExecutorError: Error, Equatable, Sendable {
    case inaccessibleRepositoryPartition
    case incompleteSearchPage
    case invalidPersistedCursor
    case notModifiedWithoutReplay
    case normalizationFailure
}

struct GitHubIssueSearchUndecodableResponseError: Error, Equatable, Sendable {
    let ssoHeader: GitHubSSOHeader?
}

struct PreparedSearchShardPageWrite: Sendable {
    let write: @Sendable (Database) throws -> Void
    let didCommit: @Sendable () async -> Void
    /// Reported only after the transactional page write succeeds. This lets a
    /// source retain its raw evidence and normalization diagnostics while
    /// preventing the shard from being marked complete.
    let postCommitFailure: SearchShardExecutorError?

    init(
        write: @escaping @Sendable (Database) throws -> Void,
        didCommit: @escaping @Sendable () async -> Void,
        postCommitFailure: SearchShardExecutorError? = nil
    ) {
        self.write = write
        self.didCommit = didCommit
        self.postCommitFailure = postCommitFailure
    }

    static let empty = PreparedSearchShardPageWrite(
        write: { _ in },
        didCommit: {},
        postCommitFailure: nil
    )
}

actor SearchShardExecutor {
    typealias PagePreparer = @Sendable (
        GitHubResponse<GitHubIssueSearchPage>,
        GitHubIssueSearchQuery,
        Int
    ) async throws -> PreparedSearchShardPageWrite

    typealias UndecodablePagePreparer = @Sendable (
        GitHubUndecodableResponse,
        GitHubIssueSearchQuery,
        Int
    ) async throws -> PreparedSearchShardPageWrite

    private let client: any GitHubIssueSearchExecuting
    private let shardRepository: SyncShardRepository
    private let planner: SearchShardPlanner
    private let replayCache: RoleSearchPageReplayCache?
    private let clock: @Sendable () -> Date

    init(
        client: any GitHubIssueSearchExecuting,
        shardRepository: SyncShardRepository,
        planner: SearchShardPlanner = SearchShardPlanner(),
        replayCache: RoleSearchPageReplayCache? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.shardRepository = shardRepository
        self.planner = planner
        self.replayCache = replayCache
        self.clock = clock
    }

    func execute(
        query: GitHubIssueSearchQuery,
        range: SearchTimeRange,
        streamID: SyncStreamID,
        accountID: AccountID,
        accessibleRepositoryNames: [String],
        prepareControlPage: @escaping PagePreparer = { _, _, _ in .empty },
        prepareUndecodablePage: @escaping UndecodablePagePreparer = { _, _, _ in .empty },
        preparePage: @escaping PagePreparer
    ) async throws {
        let boundedQuery = try query.bounded(to: range)
        try await executeShard(
            query: boundedQuery,
            range: range,
            streamID: streamID,
            accountID: accountID,
            accessibleRepositoryNames: accessibleRepositoryNames,
            prepareControlPage: prepareControlPage,
            prepareUndecodablePage: prepareUndecodablePage,
            preparePage: preparePage
        )
    }

    private func executeShard(
        query: GitHubIssueSearchQuery,
        range: SearchTimeRange,
        streamID: SyncStreamID,
        accountID: AccountID,
        accessibleRepositoryNames: [String],
        prepareControlPage: @escaping PagePreparer,
        prepareUndecodablePage: @escaping UndecodablePagePreparer,
        preparePage: @escaping PagePreparer
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
            let firstResponse = try await response(
                query: query,
                page: 1,
                streamID: streamID,
                shard: &shard,
                accountID: accountID,
                prepareUndecodablePage: prepareUndecodablePage
            )
            try Task.checkCancellation()
            let firstPage = firstResponse.value
            switch planner.nextPlan(
                range: range,
                totalCount: firstPage.totalCount,
                incompleteResults: firstPage.incompleteResults
            ) {
            case .complete:
                let pageCount = max(1, Int(ceil(Double(firstPage.totalCount) / 100)))
                let resumePage = try pageAfter(cursor: shard.pageCursor, pageCount: pageCount)
                let firstTargetShard = resumePage == 1
                    ? (pageCount == 1
                        ? completed(shard, cursor: "1")
                        : running(shard, cursor: "1"))
                    : shard
                let preparedPage = try await preparePage(firstResponse, query, 1)
                let committedShard = shardAfterPreparing(
                    preparedPage,
                    from: shard,
                    advancing: firstTargetShard
                )
                try await persistPage(
                    preparedPage,
                    advancing: committedShard,
                    accountID: accountID
                )
                shard = committedShard
                try throwPostCommitFailure(from: preparedPage)
                if pageCount == 1 {
                    if shard.state != .completed || shard.pageCursor != "1" {
                        shard = completed(shard, cursor: "1")
                        try await shardRepository.save(shard, accountID: accountID)
                    }
                    return
                }
                for page in 2...pageCount {
                    try Task.checkCancellation()
                    let response = try await response(
                        query: query,
                        page: page,
                        streamID: streamID,
                        shard: &shard,
                        accountID: accountID,
                        prepareUndecodablePage: prepareUndecodablePage
                    )
                    try Task.checkCancellation()
                    if response.value.incompleteResults {
                        shard = try await executePartitions(
                            planner.nextPlan(
                                range: range,
                                totalCount: response.value.totalCount,
                                incompleteResults: true
                            ),
                            controlResponse: response,
                            controlPage: page,
                            query: query,
                            range: range,
                            streamID: streamID,
                            accountID: accountID,
                            accessibleRepositoryNames: accessibleRepositoryNames,
                            shard: shard,
                            prepareControlPage: prepareControlPage,
                            prepareUndecodablePage: prepareUndecodablePage,
                            preparePage: preparePage
                        )
                        return
                    }
                    let targetShard: SyncShard
                    if page < resumePage {
                        targetShard = shard
                    } else if page == pageCount {
                        targetShard = completed(shard, cursor: String(page))
                    } else {
                        targetShard = running(shard, cursor: String(page))
                    }
                    let preparedPage = try await preparePage(response, query, page)
                    let committedShard = shardAfterPreparing(
                        preparedPage,
                        from: shard,
                        advancing: targetShard
                    )
                    try await persistPage(
                        preparedPage,
                        advancing: committedShard,
                        accountID: accountID
                    )
                    shard = committedShard
                    try throwPostCommitFailure(from: preparedPage)
                }
                if shard.state != .completed {
                    shard = completed(shard, cursor: String(pageCount))
                    try await shardRepository.save(shard, accountID: accountID)
                }

            case .split, .repositoryPartitionRequired:
                shard = try await executePartitions(
                    planner.nextPlan(
                        range: range,
                        totalCount: firstPage.totalCount,
                        incompleteResults: firstPage.incompleteResults
                    ),
                    controlResponse: firstResponse,
                    controlPage: 1,
                    query: query,
                    range: range,
                    streamID: streamID,
                    accountID: accountID,
                    accessibleRepositoryNames: accessibleRepositoryNames,
                    shard: shard,
                    prepareControlPage: prepareControlPage,
                    prepareUndecodablePage: prepareUndecodablePage,
                    preparePage: preparePage
                )
            }
        } catch {
            if !(error is CancellationError) {
                shard = failed(shard)
                try await shardRepository.save(shard, accountID: accountID)
            }
            throw error
        }
    }

    private func executePartitions(
        _ plan: SearchShardPlan,
        controlResponse: GitHubResponse<GitHubIssueSearchPage>,
        controlPage: Int,
        query: GitHubIssueSearchQuery,
        range: SearchTimeRange,
        streamID: SyncStreamID,
        accountID: AccountID,
        accessibleRepositoryNames: [String],
        shard: SyncShard,
        prepareControlPage: @escaping PagePreparer,
        prepareUndecodablePage: @escaping UndecodablePagePreparer,
        preparePage: @escaping PagePreparer
    ) async throws -> SyncShard {
        var parent = running(shard, cursor: "partitioned")
        try await persistPage(
            try await prepareControlPage(controlResponse, query, controlPage),
            advancing: parent,
            accountID: accountID
        )
        switch plan {
        case let .split(firstRange, secondRange):
            try await executeShard(
                query: try query.bounded(to: firstRange),
                range: firstRange,
                streamID: streamID,
                accountID: accountID,
                accessibleRepositoryNames: accessibleRepositoryNames,
                prepareControlPage: prepareControlPage,
                prepareUndecodablePage: prepareUndecodablePage,
                preparePage: preparePage
            )
            try Task.checkCancellation()
            try await executeShard(
                query: try query.bounded(to: secondRange),
                range: secondRange,
                streamID: streamID,
                accountID: accountID,
                accessibleRepositoryNames: accessibleRepositoryNames,
                prepareControlPage: prepareControlPage,
                prepareUndecodablePage: prepareUndecodablePage,
                preparePage: preparePage
            )
        case .repositoryPartitionRequired:
            guard !accessibleRepositoryNames.isEmpty else {
                throw SearchShardExecutorError.inaccessibleRepositoryPartition
            }
            for repositoryName in accessibleRepositoryNames.sorted() {
                try Task.checkCancellation()
                try await executeShard(
                    query: try query.scoped(to: repositoryName, updatedRange: range),
                    range: range,
                    streamID: streamID,
                    accountID: accountID,
                    accessibleRepositoryNames: [],
                    prepareControlPage: prepareControlPage,
                    prepareUndecodablePage: prepareUndecodablePage,
                    preparePage: preparePage
                )
            }
        case .complete:
            throw SearchShardExecutorError.incompleteSearchPage
        }
        try Task.checkCancellation()
        parent = completed(parent, cursor: "partitioned")
        try await shardRepository.save(parent, accountID: accountID)
        return parent
    }

    private func response(
        query: GitHubIssueSearchQuery,
        page: Int,
        streamID: SyncStreamID,
        shard: inout SyncShard,
        accountID: AccountID,
        prepareUndecodablePage: @escaping UndecodablePagePreparer
    ) async throws -> GitHubResponse<GitHubIssueSearchPage> {
        try Task.checkCancellation()
        let cachedEntry = try await replayCache?.entry(
            for: query,
            page: page,
            streamID: streamID
        )
        try Task.checkCancellation()
        let validators = try cachedEntry.map {
            try GitHubHTTPValidators(
                eTag: $0.replay.eTag,
                lastModified: $0.replay.lastModified
            )
        }
        try Task.checkCancellation()
        let result = try await client.searchResult(
            query,
            page: page,
            validators: validators
        )
        switch result {
        case let .response(response):
            return response
        case let .undecodable(response):
            return try await failUndecodableResponse(
                response,
                query: query,
                page: page,
                shard: &shard,
                accountID: accountID,
                prepareUndecodablePage: prepareUndecodablePage
            )
        case let .notModified(ssoHeader):
            guard let cachedEntry else {
                throw SearchShardExecutorError.notModifiedWithoutReplay
            }
            do {
                return GitHubResponse(
                    value: try GitHubIssueSearchClient.decodeReplayPayload(
                        cachedEntry.snapshot.payload
                    ),
                    payload: cachedEntry.snapshot.payload,
                    etag: cachedEntry.replay.eTag,
                    lastModified: cachedEntry.replay.lastModified,
                    ssoHeader: ssoHeader,
                    source: .replay(cachedEntry.snapshot.id)
                )
            } catch {
                try Task.checkCancellation()
                try await replayCache?.invalidate(
                    query: query,
                    page: page,
                    streamID: streamID
                )
                try Task.checkCancellation()
                let retry = try await client.searchResult(
                    query,
                    page: page,
                    validators: nil
                )
                switch retry {
                case let .response(response):
                    return response
                case let .undecodable(response):
                    return try await failUndecodableResponse(
                        response,
                        query: query,
                        page: page,
                        shard: &shard,
                        accountID: accountID,
                        prepareUndecodablePage: prepareUndecodablePage
                    )
                case .notModified:
                    throw SearchShardExecutorError.notModifiedWithoutReplay
                }
            }
        }
    }

    private func failUndecodableResponse(
        _ response: GitHubUndecodableResponse,
        query: GitHubIssueSearchQuery,
        page: Int,
        shard: inout SyncShard,
        accountID: AccountID,
        prepareUndecodablePage: @escaping UndecodablePagePreparer
    ) async throws -> GitHubResponse<GitHubIssueSearchPage> {
        let failedShard = failed(shard)
        try await persistPage(
            try await prepareUndecodablePage(response, query, page),
            advancing: failedShard,
            accountID: accountID
        )
        shard = failedShard
        throw GitHubIssueSearchUndecodableResponseError(ssoHeader: response.ssoHeader)
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

    private func persistPage(
        _ preparedWrite: PreparedSearchShardPageWrite,
        advancing shard: SyncShard,
        accountID: AccountID
    ) async throws {
        try await shardRepository.writeTransaction(accountID: accountID) { database in
            try preparedWrite.write(database)
            try SyncShardRepository.save(shard, accountID: accountID, in: database)
        }
        await preparedWrite.didCommit()
    }

    private func shardAfterPreparing(
        _ preparedWrite: PreparedSearchShardPageWrite,
        from currentShard: SyncShard,
        advancing targetShard: SyncShard
    ) -> SyncShard {
        guard preparedWrite.postCommitFailure == nil else {
            return failed(currentShard)
        }
        return targetShard
    }

    private func throwPostCommitFailure(
        from preparedWrite: PreparedSearchShardPageWrite
    ) throws {
        if let failure = preparedWrite.postCommitFailure {
            throw failure
        }
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
