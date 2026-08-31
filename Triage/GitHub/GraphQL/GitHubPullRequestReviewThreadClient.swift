import Foundation

enum GitHubPullRequestReviewThreadClientError: Error, Equatable, Sendable {
    case queryCostExceeded
    case responseByteBudgetExceeded
    case paginationLoop
    case paginationLimitExceeded
    case incompleteConnection
    case missingRequestedPullRequest
    case missingRequestedThread
    case duplicateThread
    case partialResponse
    case missingData
    case undecodableResponse
    case normalizationFailed
    case requestFailed
    case transportFailure
}

/// A failed review-thread traversal always carries every raw page obtained
/// before the terminal condition. This lets the synchronizer retain evidence
/// before moving its fair-scheduling cursor; it never makes a partial result
/// authoritative normalized state.
struct GitHubPullRequestReviewThreadTraversalFailure: Error, Equatable, Sendable {
    let reason: GitHubPullRequestReviewThreadClientError
    let rawPages: [GitHubPullRequestReviewThreadRawPage]
    let terminalRequestKey: String
    let remoteFailure: GitHubFailure?
    let ssoHeader: GitHubSSOHeader?
}

enum GitHubPullRequestReviewThreadNormalizationError: Error, Equatable, Sendable {
    case missingThreadID
    case duplicateThreadID
    case missingCommentID
    case duplicateCommentID
    case invalidCommentDates
    case invalidCommentURL
    case invalidActor
}

struct PullRequestReviewThreadCommentRecord: Equatable, Sendable {
    let nodeID: GitHubNodeID
    let author: ActorSummary?
    let body: String
    let createdAt: Date
    let updatedAt: Date
    let url: URL
}

struct PullRequestReviewThreadRecord: Equatable, Sendable {
    let nodeID: GitHubNodeID
    let isResolved: Bool
    let isOutdated: Bool
    let comments: [PullRequestReviewThreadCommentRecord]
    let updatedAt: Date
}

struct GitHubPullRequestReviewThreadRawPage: Equatable, Sendable {
    let endpoint: String
    /// Canonical operation and variables for this exact GraphQL request. This
    /// is deliberately separate from the diagnostic storage endpoint: cursors
    /// are authority, not page display metadata.
    let requestKey: String
    let payload: Data

    init(endpoint: String, requestKey: String? = nil, payload: Data) {
        self.endpoint = endpoint
        self.requestKey = requestKey ?? endpoint
        self.payload = payload
    }
}

struct GitHubPullRequestReviewThreadMetrics: Equatable, Sendable {
    let pageCount: Int
    let responseBytes: Int
    let queryCost: Int
}

struct GitHubPullRequestReviewThreadInventory: Sendable {
    let records: [PullRequestReviewThreadRecord]
    let rawPages: [GitHubPullRequestReviewThreadRawPage]
    let metrics: GitHubPullRequestReviewThreadMetrics
}

private struct StoredGraphQLResponse<Value: Decodable>: Decodable {
    let data: Value?
    let errors: [GitHubGraphQLPartialError]?
}

actor GitHubPullRequestReviewThreadClient {
    private static let maximumPages = 100
    private static let maximumNodesPerConnectionPage = 50
    private static let maximumQueryCost = 500
    private static let maximumResponseBytes = 4 * 1_024 * 1_024

    private let client: GitHubGraphQLClient

    init(client: GitHubGraphQLClient) {
        self.client = client
    }

    func allReviewThreads(
        pullRequestNodeID: GitHubNodeID,
        observedAt: Date = .now
    ) async throws -> GitHubPullRequestReviewThreadInventory {
        try await allReviewThreads(
            pullRequestNodeID: pullRequestNodeID, observedAt: observedAt, rootCheckpoint: nil
        )
    }

    func allReviewThreads(
        pullRequestNodeID: GitHubNodeID,
        observedAt: Date,
        rootCheckpoint: ReviewThreadRootCheckpoint?
    ) async throws -> GitHubPullRequestReviewThreadInventory {
        let threadsQuery = try GitHubGraphQLQueries.pullRequestReviewThreads()
        let commentsQuery = try GitHubGraphQLQueries.pullRequestReviewThreadComments()
        // A checkpoint is only a bounded optimization. A corrupt or oversized
        // persisted prefix cannot become a new source of review-thread facts;
        // start a fresh root traversal instead.
        let boundedRootCheckpoint = rootCheckpoint.flatMap {
            $0.rawPrefix.count <= Self.maximumPages ? $0 : nil
        }
        var rawPages = boundedRootCheckpoint?.rawPrefix ?? []
        var budget = AggregateBudget()
        var threadPages = boundedRootCheckpoint?.rawPrefix.count ?? 0
        var after: String? = boundedRootCheckpoint?.rootCursor
        var visitedCursors = Set<String>()
        var seenThreadNodeIDs = Set<GitHubNodeID>()
        var threads = [GitHubPullRequestReviewThreadPayload.Thread]()

        if let rootCheckpoint = boundedRootCheckpoint {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var expectedAfter: String?
            for (offset, rawPage) in rootCheckpoint.rawPrefix.enumerated() {
                guard rawPage.endpoint == "graphql:TriagePullRequestReviewThreads/page=\(offset + 1)",
                      rawPage.requestKey == Self.threadRequestKey(
                        pullRequestNodeID: pullRequestNodeID, after: expectedAfter
                      ),
                      let response = try? decoder.decode(
                        StoredGraphQLResponse<GitHubPullRequestReviewThreadPayload>.self, from: rawPage.payload
                      ), response.errors?.isEmpty != false, let payload = response.data,
                      let pullRequest = payload.node, pullRequest.id == pullRequestNodeID.rawValue,
                      let pageIDs = Self.connectionNodeIDs(pullRequest.reviewThreads.nodes.map { $0?.id }),
                      seenThreadNodeIDs.isDisjoint(with: pageIDs)
                else {
                    // A persisted prefix is never trusted as a new source.
                    // Fall back to a complete fresh root traversal.
                    rawPages.removeAll()
                    threadPages = 0
                    after = nil
                    seenThreadNodeIDs.removeAll()
                    threads.removeAll()
                    break
                }
                try budget.consume(cost: try Self.validatedCost(payload.rateLimit.cost), responseBytes: rawPage.payload.count)
                seenThreadNodeIDs.formUnion(pageIDs)
                threads.append(contentsOf: pullRequest.reviewThreads.nodes.compactMap { $0 })
                expectedAfter = pullRequest.reviewThreads.pageInfo.endCursor
                guard pullRequest.reviewThreads.pageInfo.hasNextPage,
                      expectedAfter == rootCheckpoint.rootCursor || offset + 1 < rootCheckpoint.rawPrefix.count
                else {
                    rawPages.removeAll(); threadPages = 0; after = nil; seenThreadNodeIDs.removeAll(); threads.removeAll()
                    break
                }
            }
        }

        while true {
            try Task.checkCancellation()
            let endpoint = "graphql:TriagePullRequestReviewThreads/page=\(threadPages + 1)"
            let requestKey = Self.threadRequestKey(
                pullRequestNodeID: pullRequestNodeID,
                after: after
            )
            guard threadPages < Self.maximumPages else {
                let terminal = Self.syntheticTerminalPage(
                    endpoint: endpoint,
                    requestKey: requestKey,
                    reason: .paginationLimitExceeded
                )
                throw Self.failure(
                    .paginationLimitExceeded,
                    rawPages: rawPages + [terminal],
                    terminalRequestKey: terminal.requestKey
                )
            }
            let decodingResult: GitHubGraphQLDecodingResult<GitHubPullRequestReviewThreadPayload>
            do {
                decodingResult = try await client.executePreservingUndecodableResponse(
                    threadsQuery,
                    variables: CursorVariables(pullRequestID: pullRequestNodeID.rawValue, after: after),
                    as: GitHubPullRequestReviewThreadPayload.self
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let GitHubGraphQLError.requestFailed(failure) {
                let terminal = Self.syntheticTerminalPage(
                    endpoint: endpoint,
                    requestKey: requestKey,
                    reason: .requestFailed
                )
                throw Self.failure(
                    .requestFailed,
                    rawPages: rawPages + [terminal],
                    terminalRequestKey: terminal.requestKey,
                    remoteFailure: failure,
                    ssoHeader: failure.ssoHeader
                )
            } catch {
                let terminal = Self.syntheticTerminalPage(
                    endpoint: endpoint,
                    requestKey: requestKey,
                    reason: .transportFailure
                )
                throw Self.failure(
                    .transportFailure,
                    rawPages: rawPages + [terminal],
                    terminalRequestKey: terminal.requestKey
                )
            }
            try Task.checkCancellation()
            let response: GitHubGraphQLResponse<GitHubPullRequestReviewThreadPayload>
            switch decodingResult {
            case let .response(value):
                response = value
            case let .undecodable(value):
                let rawPage = GitHubPullRequestReviewThreadRawPage(
                    endpoint: endpoint, requestKey: requestKey, payload: value.payload
                )
                throw Self.failure(
                    .undecodableResponse,
                    rawPages: rawPages + [rawPage],
                    terminalRequestKey: requestKey,
                    ssoHeader: value.metadata.ssoHeader
                )
            }
            let rawPage = GitHubPullRequestReviewThreadRawPage(
                endpoint: endpoint, requestKey: requestKey, payload: response.payload
            )
            if let ssoHeader = response.metadata.ssoHeader {
                throw Self.failure(
                    .requestFailed,
                    rawPages: rawPages + [rawPage],
                    terminalRequestKey: requestKey,
                    ssoHeader: ssoHeader
                )
            }
            guard response.errors.isEmpty else {
                throw Self.failure(.partialResponse, rawPages: rawPages + [rawPage], terminalRequestKey: requestKey)
            }
            guard let payload = response.data else {
                throw Self.failure(.missingData, rawPages: rawPages + [rawPage], terminalRequestKey: requestKey)
            }
            do {
                try budget.consume(
                    cost: try Self.validatedCost(payload.rateLimit.cost),
                    responseBytes: rawPage.payload.count
                )
            } catch let reason as GitHubPullRequestReviewThreadClientError {
                throw Self.failure(reason, rawPages: rawPages + [rawPage], terminalRequestKey: requestKey)
            }
            rawPages.append(rawPage)
            guard let pullRequest = payload.node, pullRequest.id == pullRequestNodeID.rawValue else {
                throw Self.failure(.missingRequestedPullRequest, rawPages: rawPages, terminalRequestKey: requestKey)
            }
            guard let pageThreadNodeIDs = Self.connectionNodeIDs(
                pullRequest.reviewThreads.nodes.map { $0?.id }
            ), pageThreadNodeIDs.count <= Self.maximumNodesPerConnectionPage,
               seenThreadNodeIDs.isDisjoint(with: pageThreadNodeIDs)
            else {
                throw Self.failure(.incompleteConnection, rawPages: rawPages, terminalRequestKey: requestKey)
            }
            seenThreadNodeIDs.formUnion(pageThreadNodeIDs)
            threads.append(contentsOf: pullRequest.reviewThreads.nodes.compactMap { $0 })
            threadPages += 1
            guard pullRequest.reviewThreads.pageInfo.hasNextPage else { break }
            guard let cursor = pullRequest.reviewThreads.pageInfo.endCursor,
                  visitedCursors.insert(cursor).inserted
            else {
                throw Self.failure(.paginationLoop, rawPages: rawPages, terminalRequestKey: requestKey)
            }
            after = cursor
        }

        try Task.checkCancellation()
        let threadIDs: [GitHubNodeID]
        do {
            threadIDs = try Self.validThreadIDs(in: threads)
        } catch {
            throw Self.failure(
                .normalizationFailed,
                rawPages: rawPages,
                terminalRequestKey: rawPages.last?.requestKey ?? Self.threadRequestKey(pullRequestNodeID: pullRequestNodeID, after: nil)
            )
        }
        for index in threads.indices {
            try Task.checkCancellation()
            var thread = threads[index]
            var comments = [GitHubPullRequestReviewThreadPayload.Comment?]()
            var seenCommentNodeIDs = Set<GitHubNodeID>()
            var commentPages = 0
            var commentCursor: String?
            var visitedCommentCursors = Set<String>()
            while true {
                try Task.checkCancellation()
                let endpoint = "graphql:TriagePullRequestReviewThreadComments/thread=\(threadIDs[index].rawValue)/page=\(commentPages + 1)"
                let requestKey = Self.commentRequestKey(threadNodeID: threadIDs[index], after: commentCursor)
                guard commentPages < Self.maximumPages else {
                    let terminal = Self.syntheticTerminalPage(
                        endpoint: endpoint,
                        requestKey: requestKey,
                        reason: .paginationLimitExceeded
                    )
                    throw Self.failure(
                        .paginationLimitExceeded,
                        rawPages: rawPages + [terminal],
                        terminalRequestKey: terminal.requestKey
                    )
                }
                let decodingResult: GitHubGraphQLDecodingResult<GitHubPullRequestReviewThreadCommentPagePayload>
                do {
                    decodingResult = try await client.executePreservingUndecodableResponse(
                        commentsQuery,
                        variables: ThreadCursorVariables(
                            threadID: threadIDs[index].rawValue,
                            after: commentCursor
                        ),
                        as: GitHubPullRequestReviewThreadCommentPagePayload.self
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let GitHubGraphQLError.requestFailed(failure) {
                    let terminal = Self.syntheticTerminalPage(
                        endpoint: endpoint,
                        requestKey: requestKey,
                        reason: .requestFailed
                    )
                    throw Self.failure(
                        .requestFailed,
                        rawPages: rawPages + [terminal],
                        terminalRequestKey: terminal.requestKey,
                        remoteFailure: failure,
                        ssoHeader: failure.ssoHeader
                    )
                } catch {
                    let terminal = Self.syntheticTerminalPage(
                        endpoint: endpoint,
                        requestKey: requestKey,
                        reason: .transportFailure
                    )
                    throw Self.failure(
                        .transportFailure,
                        rawPages: rawPages + [terminal],
                        terminalRequestKey: terminal.requestKey
                    )
                }
                try Task.checkCancellation()
                let response: GitHubGraphQLResponse<GitHubPullRequestReviewThreadCommentPagePayload>
                switch decodingResult {
                case let .response(value):
                    response = value
                case let .undecodable(value):
                    let rawPage = GitHubPullRequestReviewThreadRawPage(
                        endpoint: endpoint, requestKey: requestKey, payload: value.payload
                    )
                    throw Self.failure(
                        .undecodableResponse,
                        rawPages: rawPages + [rawPage],
                        terminalRequestKey: requestKey,
                        ssoHeader: value.metadata.ssoHeader
                    )
                }
                let rawPage = GitHubPullRequestReviewThreadRawPage(
                    endpoint: endpoint, requestKey: requestKey, payload: response.payload
                )
                if let ssoHeader = response.metadata.ssoHeader {
                    throw Self.failure(.requestFailed, rawPages: rawPages + [rawPage], terminalRequestKey: requestKey, ssoHeader: ssoHeader)
                }
                guard response.errors.isEmpty else {
                    throw Self.failure(.partialResponse, rawPages: rawPages + [rawPage], terminalRequestKey: requestKey)
                }
                guard let payload = response.data else {
                    throw Self.failure(.missingData, rawPages: rawPages + [rawPage], terminalRequestKey: requestKey)
                }
                do {
                    try budget.consume(
                        cost: try Self.validatedCost(payload.rateLimit.cost),
                        responseBytes: rawPage.payload.count
                    )
                } catch let reason as GitHubPullRequestReviewThreadClientError {
                    throw Self.failure(reason, rawPages: rawPages + [rawPage], terminalRequestKey: requestKey)
                }
                rawPages.append(rawPage)
                guard let returnedThread = payload.node,
                      returnedThread.id == threadIDs[index].rawValue
                else {
                    throw Self.failure(.missingRequestedThread, rawPages: rawPages, terminalRequestKey: requestKey)
                }
                guard let pageCommentNodeIDs = Self.connectionNodeIDs(
                    returnedThread.comments.nodes.map { $0?.id }
                ), pageCommentNodeIDs.count <= Self.maximumNodesPerConnectionPage,
                   seenCommentNodeIDs.isDisjoint(with: pageCommentNodeIDs)
                else {
                    throw Self.failure(.incompleteConnection, rawPages: rawPages, terminalRequestKey: requestKey)
                }
                seenCommentNodeIDs.formUnion(pageCommentNodeIDs)
                comments.append(contentsOf: returnedThread.comments.nodes)
                commentPages += 1
                guard returnedThread.comments.pageInfo.hasNextPage else { break }
                guard let nextCursor = returnedThread.comments.pageInfo.endCursor,
                      visitedCommentCursors.insert(nextCursor).inserted
                else {
                    throw Self.failure(.paginationLoop, rawPages: rawPages, terminalRequestKey: requestKey)
                }
                commentCursor = nextCursor
            }
            thread.comments = .init(
                nodes: comments,
                pageInfo: .init(hasNextPage: false, endCursor: nil)
            )
            threads[index] = thread
        }

        try Task.checkCancellation()
        let records: [PullRequestReviewThreadRecord]
        do {
            records = try GitHubPullRequestReviewThreadNormalizer.normalize(threads, observedAt: observedAt)
        } catch {
            throw Self.failure(
                .normalizationFailed,
                rawPages: rawPages,
                terminalRequestKey: rawPages.last?.requestKey ?? Self.threadRequestKey(pullRequestNodeID: pullRequestNodeID, after: nil)
            )
        }
        try Task.checkCancellation()
        return GitHubPullRequestReviewThreadInventory(
            records: records,
            rawPages: rawPages,
            metrics: .init(
                pageCount: rawPages.count,
                responseBytes: budget.responseBytes,
                queryCost: budget.queryCost
            )
        )
    }

    private nonisolated static func validatedCost(_ cost: Int) throws -> Int {
        guard cost >= 0, cost <= maximumQueryCost else {
            throw GitHubPullRequestReviewThreadClientError.queryCostExceeded
        }
        return cost
    }

    private nonisolated static func validThreadIDs(
        in threads: [GitHubPullRequestReviewThreadPayload.Thread]
    ) throws -> [GitHubNodeID] {
        let identifiers = try threads.map {
            guard let id = GitHubNodeID(rawValue: $0.id) else {
                throw GitHubPullRequestReviewThreadNormalizationError.missingThreadID
            }
            return id
        }
        guard Set(identifiers).count == identifiers.count else {
            throw GitHubPullRequestReviewThreadClientError.duplicateThread
        }
        return identifiers
    }

    /// Validate a GraphQL connection before its members can trigger follow-up
    /// requests. A malformed server response must not amplify into arbitrary
    /// descendant traversal work.
    private nonisolated static func connectionNodeIDs(_ identifiers: [String?]) -> Set<GitHubNodeID>? {
        guard identifiers.count <= maximumNodesPerConnectionPage else { return nil }
        let nodeIDs = identifiers.compactMap { $0 }.compactMap(GitHubNodeID.init(rawValue:))
        guard nodeIDs.count == identifiers.count,
              Set(nodeIDs).count == nodeIDs.count
        else { return nil }
        return Set(nodeIDs)
    }

    private struct AggregateBudget {
        private(set) var queryCost = 0
        private(set) var responseBytes = 0

        mutating func consume(cost: Int, responseBytes nextResponseBytes: Int) throws {
            guard queryCost <= GitHubPullRequestReviewThreadClient.maximumQueryCost - cost else {
                throw GitHubPullRequestReviewThreadClientError.queryCostExceeded
            }
            guard nextResponseBytes <= GitHubPullRequestReviewThreadClient.maximumResponseBytes,
                  responseBytes <= GitHubPullRequestReviewThreadClient.maximumResponseBytes - nextResponseBytes
            else {
                throw GitHubPullRequestReviewThreadClientError.responseByteBudgetExceeded
            }
            queryCost += cost
            responseBytes += nextResponseBytes
        }
    }

    private struct CursorVariables: Encodable, Sendable {
        let pullRequestID: String
        let after: String?
    }

    private struct ThreadCursorVariables: Encodable, Sendable {
        let threadID: String
        let after: String?
    }

    private nonisolated static func failure(
        _ reason: GitHubPullRequestReviewThreadClientError,
        rawPages: [GitHubPullRequestReviewThreadRawPage],
        terminalRequestKey: String,
        remoteFailure: GitHubFailure? = nil,
        ssoHeader: GitHubSSOHeader? = nil
    ) -> GitHubPullRequestReviewThreadTraversalFailure {
        .init(
            reason: reason,
            rawPages: rawPages,
            terminalRequestKey: terminalRequestKey,
            remoteFailure: remoteFailure,
            ssoHeader: ssoHeader
        )
    }

    private nonisolated static func threadRequestKey(
        pullRequestNodeID: GitHubNodeID,
        after: String?
    ) -> String {
        "graphql:TriagePullRequestReviewThreads/pull-request=\(pullRequestNodeID.rawValue)/after=\(cursorComponent(after))"
    }

    private nonisolated static func commentRequestKey(
        threadNodeID: GitHubNodeID,
        after: String?
    ) -> String {
        "graphql:TriagePullRequestReviewThreadComments/thread=\(threadNodeID.rawValue)/after=\(cursorComponent(after))"
    }

    private nonisolated static func cursorComponent(_ cursor: String?) -> String {
        guard let cursor else { return "none" }
        return Data(cursor.utf8).base64EncodedString()
    }

    private nonisolated static func syntheticTerminalPage(
        endpoint: String,
        requestKey: String,
        reason: GitHubPullRequestReviewThreadClientError
    ) -> GitHubPullRequestReviewThreadRawPage {
        let payload = Data("{\"triageFailureEnvelopeVersion\":1,\"reason\":\"\(String(describing: reason))\"}".utf8)
        return .init(
            endpoint: "\(endpoint)/terminal",
            requestKey: "\(requestKey)/terminal",
            payload: payload
        )
    }
}

enum GitHubPullRequestReviewThreadNormalizer {
    static func normalize(
        _ threads: [GitHubPullRequestReviewThreadPayload.Thread],
        observedAt: Date
    ) throws -> [PullRequestReviewThreadRecord] {
        var threadIDs = Set<GitHubNodeID>()
        var commentIDs = Set<GitHubNodeID>()
        return try threads.map { thread in
            guard let threadID = GitHubNodeID(rawValue: thread.id) else {
                throw GitHubPullRequestReviewThreadNormalizationError.missingThreadID
            }
            guard threadIDs.insert(threadID).inserted else {
                throw GitHubPullRequestReviewThreadNormalizationError.duplicateThreadID
            }
            guard let threadComments = thread.comments else {
                throw GitHubPullRequestReviewThreadNormalizationError.missingThreadID
            }
            let comments = try threadComments.nodes.map { payload -> PullRequestReviewThreadCommentRecord in
                guard let payload,
                      let nodeID = GitHubNodeID(rawValue: payload.id)
                else {
                    throw GitHubPullRequestReviewThreadNormalizationError.missingCommentID
                }
                guard commentIDs.insert(nodeID).inserted else {
                    throw GitHubPullRequestReviewThreadNormalizationError.duplicateCommentID
                }
                guard payload.createdAt.isFinite, payload.updatedAt.isFinite,
                      payload.createdAt <= payload.updatedAt
                else {
                    throw GitHubPullRequestReviewThreadNormalizationError.invalidCommentDates
                }
                guard payload.url.scheme == "https", payload.url.host == "github.com" else {
                    throw GitHubPullRequestReviewThreadNormalizationError.invalidCommentURL
                }
                let author = try payload.author.map(Self.actor)
                return .init(
                    nodeID: nodeID,
                    author: author,
                    body: payload.body,
                    createdAt: payload.createdAt,
                    updatedAt: payload.updatedAt,
                    url: payload.url
                )
            }
            let updatedAt = comments.map(\.updatedAt).max() ?? observedAt
            return .init(
                nodeID: threadID,
                isResolved: thread.isResolved,
                isOutdated: thread.isOutdated,
                comments: comments,
                updatedAt: updatedAt
            )
        }
    }

    private static func actor(
        _ payload: GitHubPullRequestReviewThreadPayload.Actor
    ) throws -> ActorSummary {
        guard let actorID = ActorID(rawValue: payload.id),
              let nodeID = GitHubNodeID(rawValue: payload.id),
              !payload.login.isEmpty
        else {
            throw GitHubPullRequestReviewThreadNormalizationError.invalidActor
        }
        return ActorSummary(
            id: actorID,
            nodeID: nodeID,
            login: payload.login,
            displayName: nil,
            avatarURL: payload.avatarUrl
        )
    }
}

struct GitHubPullRequestReviewThreadPayload: Decodable, Sendable {
    let node: PullRequest?
    let rateLimit: RateLimit

    struct PullRequest: Decodable, Sendable {
        let id: String
        let reviewThreads: Connection
    }

    struct Thread: Decodable, Sendable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        var comments: CommentConnection?
    }

    struct Connection: Decodable, Sendable {
        let nodes: [Thread?]
        let pageInfo: PageInfo
    }

    struct CommentConnection: Decodable, Sendable {
        var nodes: [Comment?]
        let pageInfo: PageInfo
    }

    struct Comment: Decodable, Sendable {
        let id: String
        let body: String
        let createdAt: Date
        let updatedAt: Date
        let url: URL
        let author: Actor?
    }

    struct Actor: Decodable, Sendable {
        let id: String
        let login: String
        let avatarUrl: URL?
    }

    struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct RateLimit: Decodable, Sendable {
        let cost: Int
        let remaining: Int
        let resetAt: Date
    }
}

struct GitHubPullRequestReviewThreadCommentPagePayload: Decodable, Sendable {
    let node: Thread?
    let rateLimit: GitHubPullRequestReviewThreadPayload.RateLimit

    struct Thread: Decodable, Sendable {
        let id: String
        let comments: GitHubPullRequestReviewThreadPayload.CommentConnection
    }
}

private extension Date {
    var isFinite: Bool {
        timeIntervalSinceReferenceDate.isFinite
    }
}
