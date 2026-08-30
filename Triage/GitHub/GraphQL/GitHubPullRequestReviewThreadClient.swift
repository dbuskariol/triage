import Foundation

enum GitHubPullRequestReviewThreadClientError: Error, Equatable, Sendable {
    case queryCostExceeded
    case paginationLoop
    case paginationLimitExceeded
    case incompleteConnection
    case missingRequestedPullRequest
    case missingRequestedThread
    case duplicateThread
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
    let payload: Data
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

actor GitHubPullRequestReviewThreadClient {
    private static let maximumPages = 100
    private static let maximumQueryCost = 500

    private let client: GitHubGraphQLClient

    init(client: GitHubGraphQLClient) {
        self.client = client
    }

    func allReviewThreads(
        pullRequestNodeID: GitHubNodeID,
        observedAt: Date = .now
    ) async throws -> GitHubPullRequestReviewThreadInventory {
        let threadsQuery = try GitHubGraphQLQueries.pullRequestReviewThreads()
        let commentsQuery = try GitHubGraphQLQueries.pullRequestReviewThreadComments()
        var rawPages = [GitHubPullRequestReviewThreadRawPage]()
        var totalCost = 0
        var threadPages = 0
        var after: String?
        var visitedCursors = Set<String>()
        var threads = [GitHubPullRequestReviewThreadPayload.Thread]()

        while true {
            try Task.checkCancellation()
            guard threadPages < Self.maximumPages else {
                throw GitHubPullRequestReviewThreadClientError.paginationLimitExceeded
            }
            let response = try await client.execute(
                threadsQuery,
                variables: CursorVariables(pullRequestID: pullRequestNodeID.rawValue, after: after),
                as: GitHubPullRequestReviewThreadPayload.self
            )
            rawPages.append(
                .init(
                    endpoint: "graphql:TriagePullRequestReviewThreads/page=\(threadPages + 1)",
                    payload: response.payload
                )
            )
            let payload = try Self.complete(response)
            totalCost += try Self.validatedCost(payload.rateLimit.cost)
            guard let pullRequest = payload.node, pullRequest.id == pullRequestNodeID.rawValue else {
                throw GitHubPullRequestReviewThreadClientError.missingRequestedPullRequest
            }
            guard !pullRequest.reviewThreads.nodes.contains(where: { $0 == nil }) else {
                throw GitHubPullRequestReviewThreadNormalizationError.missingThreadID
            }
            threads.append(contentsOf: pullRequest.reviewThreads.nodes.compactMap { $0 })
            threadPages += 1
            guard pullRequest.reviewThreads.pageInfo.hasNextPage else { break }
            guard let cursor = pullRequest.reviewThreads.pageInfo.endCursor,
                  visitedCursors.insert(cursor).inserted
            else {
                throw GitHubPullRequestReviewThreadClientError.paginationLoop
            }
            after = cursor
        }

        let threadIDs = try Self.validThreadIDs(in: threads)
        for index in threads.indices {
            var thread = threads[index]
            var comments = [GitHubPullRequestReviewThreadPayload.Comment?]()
            var commentPages = 0
            var commentCursor: String?
            var visitedCommentCursors = Set<String>()
            while true {
                try Task.checkCancellation()
                guard commentPages < Self.maximumPages else {
                    throw GitHubPullRequestReviewThreadClientError.paginationLimitExceeded
                }
                let response = try await client.execute(
                    commentsQuery,
                    variables: ThreadCursorVariables(
                        threadID: threadIDs[index].rawValue,
                        after: commentCursor
                    ),
                    as: GitHubPullRequestReviewThreadCommentPagePayload.self
                )
                rawPages.append(
                    .init(
                        endpoint: "graphql:TriagePullRequestReviewThreadComments/thread=\(threadIDs[index].rawValue)/page=\(commentPages + 1)",
                        payload: response.payload
                    )
                )
                let payload = try Self.complete(response)
                totalCost += try Self.validatedCost(payload.rateLimit.cost)
                guard let returnedThread = payload.node,
                      returnedThread.id == threadIDs[index].rawValue
                else {
                    throw GitHubPullRequestReviewThreadClientError.missingRequestedThread
                }
                comments.append(contentsOf: returnedThread.comments.nodes)
                commentPages += 1
                guard returnedThread.comments.pageInfo.hasNextPage else { break }
                guard let nextCursor = returnedThread.comments.pageInfo.endCursor,
                      visitedCommentCursors.insert(nextCursor).inserted
                else {
                    throw GitHubPullRequestReviewThreadClientError.paginationLoop
                }
                commentCursor = nextCursor
            }
            thread.comments = .init(
                nodes: comments,
                pageInfo: .init(hasNextPage: false, endCursor: nil)
            )
            threads[index] = thread
        }

        let records = try GitHubPullRequestReviewThreadNormalizer.normalize(threads, observedAt: observedAt)
        return GitHubPullRequestReviewThreadInventory(
            records: records,
            rawPages: rawPages,
            metrics: .init(
                pageCount: rawPages.count,
                responseBytes: rawPages.reduce(0) { $0 + $1.payload.count },
                queryCost: totalCost
            )
        )
    }

    private nonisolated static func complete<Value>(
        _ response: GitHubGraphQLResponse<Value>
    ) throws -> Value {
        guard response.errors.isEmpty else { throw GitHubGraphQLError.partialResponse }
        guard let data = response.data else { throw GitHubGraphQLError.missingData }
        return data
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

    private struct CursorVariables: Encodable, Sendable {
        let pullRequestID: String
        let after: String?
    }

    private struct ThreadCursorVariables: Encodable, Sendable {
        let threadID: String
        let after: String?
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
