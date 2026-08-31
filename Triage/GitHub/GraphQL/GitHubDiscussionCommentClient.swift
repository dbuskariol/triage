import Foundation

/// Read-only documents for the two independently-paginated Discussion
/// connections.  They deliberately do not nest replies under comments: each
/// reply page is fetched using its own cursor and immutable parent ID.
enum GitHubDiscussionCommentQueryDocuments {
    static func discussionComments() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQueries.discussionComments()
    }

    static func discussionCommentReplies() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQueries.discussionCommentReplies()
    }
}

enum GitHubDiscussionCommentSource: String, Equatable, Sendable {
    case comments
    case replies

    var coverageFeature: CoverageFeature {
        switch self {
        case .comments: .discussionComments
        case .replies: .discussionReplies
        }
    }
}

struct GitHubDiscussionCommentRawPage: Equatable, Sendable {
    let source: GitHubDiscussionCommentSource
    let endpoint: String
    let requestKey: String
    let payload: Data
}

enum GitHubDiscussionCommentClientError: Error, Equatable, Sendable {
    case requestFailed(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage], GitHubGraphQLError)
    case paginationLoop(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage])
    case paginationLimitExceeded(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage])
    case queryCostExceeded(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage])
    case aggregateLimitExceeded(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage])
    case missingRequestedNode(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage])
    case incompleteConnection(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage])
    case undecodableResponse(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage])
    case partialResponse(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage])
    case ssoResponse(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage], GitHubSSOHeader)
    case normalizationFailed(GitHubDiscussionCommentSource, [GitHubDiscussionCommentRawPage])
}

struct GitHubDiscussionCommentInventory: Sendable {
    let comments: [DiscussionCommentRecord]
    let replies: [DiscussionCommentRecord]
    let rawPages: [GitHubDiscussionCommentRawPage]
}

struct GitHubDiscussionCommentPagePayload: Decodable, Sendable {
    let node: Discussion?
    let rateLimit: RateLimit
    struct Discussion: Decodable, Sendable { let id: String; let comments: Connection }
    struct Connection: Decodable, Sendable { let nodes: [Comment?]; let pageInfo: PageInfo }
    struct Comment: Decodable, Sendable {
        let id: String; let body: String; let createdAt: Date; let updatedAt: Date; let url: URL
        let author: Actor?; let replies: ReplyCount
    }
    struct ReplyCount: Decodable, Sendable { let totalCount: Int }
    struct Actor: Decodable, Sendable { let id: String; let login: String; let avatarUrl: URL? }
    struct PageInfo: Decodable, Sendable { let hasNextPage: Bool; let endCursor: String? }
    struct RateLimit: Decodable, Sendable { let cost: Int; let remaining: Int; let resetAt: Date }
}

struct GitHubDiscussionReplyPagePayload: Decodable, Sendable {
    let node: Comment?
    let rateLimit: RateLimit
    struct Comment: Decodable, Sendable { let id: String; let replies: Connection }
    struct Connection: Decodable, Sendable { let nodes: [Reply?]; let pageInfo: PageInfo }
    struct Reply: Decodable, Sendable {
        let id: String; let body: String; let createdAt: Date; let updatedAt: Date; let url: URL; let author: Actor?
    }
    struct Actor: Decodable, Sendable { let id: String; let login: String; let avatarUrl: URL? }
    struct PageInfo: Decodable, Sendable { let hasNextPage: Bool; let endCursor: String? }
    struct RateLimit: Decodable, Sendable { let cost: Int; let remaining: Int; let resetAt: Date }
}

actor GitHubDiscussionCommentClient {
    private static let maximumPages = 100
    private static let maximumCost = 500
    private static let maximumBytes = 4 * 1_024 * 1_024
    private let client: GitHubGraphQLClient
    private let commentsQuery: GitHubGraphQLQuery
    private let repliesQuery: GitHubGraphQLQuery

    init(client: GitHubGraphQLClient, commentsQuery: GitHubGraphQLQuery, repliesQuery: GitHubGraphQLQuery) {
        self.client = client; self.commentsQuery = commentsQuery; self.repliesQuery = repliesQuery
    }

    init(client: GitHubGraphQLClient) throws {
        self.client = client
        self.commentsQuery = try GitHubDiscussionCommentQueryDocuments.discussionComments()
        self.repliesQuery = try GitHubDiscussionCommentQueryDocuments.discussionCommentReplies()
    }

    func allCommentsAndReplies(
        discussionNodeID: GitHubNodeID,
        githubOrganizationID: UInt64,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> GitHubDiscussionCommentInventory {
        var budget = Budget(); var pages = [GitHubDiscussionCommentRawPage](); var cursor: String?; var cursors = Set<String>()
        var comments = [GitHubDiscussionCommentPagePayload.Comment]()
        while true {
            try Task.checkCancellation(); try await validateScope()
            guard pages.filter({ $0.source == .comments }).count < Self.maximumPages else { throw GitHubDiscussionCommentClientError.paginationLimitExceeded(.comments, pages) }
            let response = try await commentResponse(discussionNodeID: discussionNodeID, after: cursor, page: pages.count + 1, organizationID: githubOrganizationID, existing: pages)
            let page = response.page; try budget.consume(cost: response.payload.rateLimit.cost, bytes: page.payload.count, source: .comments, pages: pages + [page]); pages.append(page)
            guard let discussion = response.payload.node, discussion.id == discussionNodeID.rawValue else { throw GitHubDiscussionCommentClientError.missingRequestedNode(.comments, pages) }
            guard !discussion.comments.nodes.contains(where: { $0 == nil }) else { throw GitHubDiscussionCommentClientError.incompleteConnection(.comments, pages) }
            comments.append(contentsOf: discussion.comments.nodes.compactMap { $0 })
            guard discussion.comments.pageInfo.hasNextPage else { break }
            guard let next = discussion.comments.pageInfo.endCursor, cursors.insert(next).inserted else { throw GitHubDiscussionCommentClientError.paginationLoop(.comments, pages) }
            cursor = next
        }
        do { try GitHubDiscussionCommentNormalizer.validateCommentPayloads(comments) } catch { throw GitHubDiscussionCommentClientError.normalizationFailed(.comments, pages) }
        var repliesByParent = [GitHubNodeID: [GitHubDiscussionReplyPagePayload.Reply]]()
        for comment in comments {
            guard let commentID = GitHubNodeID(rawValue: comment.id) else { throw GitHubDiscussionCommentClientError.normalizationFailed(.comments, pages) }
            var replyCursor: String?; var replyCursors = Set<String>(); var replies = [GitHubDiscussionReplyPagePayload.Reply](); var replyPage = 0
            while true {
                try Task.checkCancellation(); try await validateScope()
                guard replyPage < Self.maximumPages else { throw GitHubDiscussionCommentClientError.paginationLimitExceeded(.replies, pages) }
                let response = try await replyResponse(discussionNodeID: discussionNodeID, commentID: commentID, after: replyCursor, page: replyPage + 1, organizationID: githubOrganizationID, existing: pages)
                let page = response.page; try budget.consume(cost: response.payload.rateLimit.cost, bytes: page.payload.count, source: .replies, pages: pages + [page]); pages.append(page)
                guard let returned = response.payload.node, returned.id == commentID.rawValue else { throw GitHubDiscussionCommentClientError.missingRequestedNode(.replies, pages) }
                guard !returned.replies.nodes.contains(where: { $0 == nil }) else { throw GitHubDiscussionCommentClientError.incompleteConnection(.replies, pages) }
                replies.append(contentsOf: returned.replies.nodes.compactMap { $0 })
                replyPage += 1
                guard returned.replies.pageInfo.hasNextPage else { break }
                guard let next = returned.replies.pageInfo.endCursor, replyCursors.insert(next).inserted else { throw GitHubDiscussionCommentClientError.paginationLoop(.replies, pages) }
                replyCursor = next
            }
            repliesByParent[commentID] = replies
        }
        do {
            let normalized = try GitHubDiscussionCommentNormalizer.normalize(discussionNodeID: discussionNodeID, comments: comments, repliesByParent: repliesByParent)
            return .init(comments: normalized.comments, replies: normalized.replies, rawPages: pages)
        } catch { throw GitHubDiscussionCommentClientError.normalizationFailed(.replies, pages) }
    }

    private func commentResponse(discussionNodeID: GitHubNodeID, after: String?, page: Int, organizationID: UInt64, existing: [GitHubDiscussionCommentRawPage]) async throws -> (payload: GitHubDiscussionCommentPagePayload, page: GitHubDiscussionCommentRawPage) {
        let key = "graphql:TriageDiscussionComments/discussion=\(discussionNodeID.rawValue)/after=\(Self.cursorComponent(after))"
        do {
            let result = try await client.executePreservingUndecodableResponse(commentsQuery, variables: DiscussionCursorVariables(discussionID: discussionNodeID.rawValue, after: after), as: GitHubDiscussionCommentPagePayload.self)
            try Task.checkCancellation()
            switch result {
            case let .undecodable(value):
                let raw = GitHubDiscussionCommentRawPage(source: .comments, endpoint: "graphql:TriageDiscussionComments/discussion=\(discussionNodeID.rawValue)/page=\(page)", requestKey: key, payload: value.payload)
                if let sso = value.metadata.ssoHeader?.scoped(to: organizationID) { throw GitHubDiscussionCommentClientError.ssoResponse(.comments, existing + [raw], sso) }
                throw GitHubDiscussionCommentClientError.undecodableResponse(.comments, existing + [raw])
            case let .response(value):
                let raw = GitHubDiscussionCommentRawPage(source: .comments, endpoint: "graphql:TriageDiscussionComments/discussion=\(discussionNodeID.rawValue)/page=\(page)", requestKey: key, payload: value.payload)
                if let sso = value.metadata.ssoHeader?.scoped(to: organizationID) { throw GitHubDiscussionCommentClientError.ssoResponse(.comments, existing + [raw], sso) }
                guard value.errors.isEmpty else { throw GitHubDiscussionCommentClientError.partialResponse(.comments, existing + [raw]) }
                guard let payload = value.data else { throw GitHubDiscussionCommentClientError.partialResponse(.comments, existing + [raw]) }
                return (payload, raw)
            }
        } catch let error as GitHubDiscussionCommentClientError { throw error }
        catch let error as GitHubGraphQLError { throw GitHubDiscussionCommentClientError.requestFailed(.comments, existing, error) }
    }

    private func replyResponse(discussionNodeID: GitHubNodeID, commentID: GitHubNodeID, after: String?, page: Int, organizationID: UInt64, existing: [GitHubDiscussionCommentRawPage]) async throws -> (payload: GitHubDiscussionReplyPagePayload, page: GitHubDiscussionCommentRawPage) {
        let key = "graphql:TriageDiscussionCommentReplies/discussion=\(discussionNodeID.rawValue)/comment=\(commentID.rawValue)/after=\(Self.cursorComponent(after))"
        do {
            let result = try await client.executePreservingUndecodableResponse(repliesQuery, variables: ReplyCursorVariables(commentID: commentID.rawValue, after: after), as: GitHubDiscussionReplyPagePayload.self)
            try Task.checkCancellation()
            switch result {
            case let .undecodable(value):
                let raw = GitHubDiscussionCommentRawPage(source: .replies, endpoint: "graphql:TriageDiscussionCommentReplies/discussion=\(discussionNodeID.rawValue)/comment=\(commentID.rawValue)/page=\(page)", requestKey: key, payload: value.payload)
                if let sso = value.metadata.ssoHeader?.scoped(to: organizationID) { throw GitHubDiscussionCommentClientError.ssoResponse(.replies, existing + [raw], sso) }
                throw GitHubDiscussionCommentClientError.undecodableResponse(.replies, existing + [raw])
            case let .response(value):
                let raw = GitHubDiscussionCommentRawPage(source: .replies, endpoint: "graphql:TriageDiscussionCommentReplies/discussion=\(discussionNodeID.rawValue)/comment=\(commentID.rawValue)/page=\(page)", requestKey: key, payload: value.payload)
                if let sso = value.metadata.ssoHeader?.scoped(to: organizationID) { throw GitHubDiscussionCommentClientError.ssoResponse(.replies, existing + [raw], sso) }
                guard value.errors.isEmpty, let payload = value.data else { throw GitHubDiscussionCommentClientError.partialResponse(.replies, existing + [raw]) }
                return (payload, raw)
            }
        } catch let error as GitHubDiscussionCommentClientError { throw error }
        catch let error as GitHubGraphQLError { throw GitHubDiscussionCommentClientError.requestFailed(.replies, existing, error) }
    }

    private struct DiscussionCursorVariables: Encodable, Sendable { let discussionID: String; let after: String? }
    private struct ReplyCursorVariables: Encodable, Sendable { let commentID: String; let after: String? }
    private struct Budget {
        var cost = 0; var bytes = 0
        mutating func consume(cost nextCost: Int, bytes nextBytes: Int, source: GitHubDiscussionCommentSource, pages: [GitHubDiscussionCommentRawPage]) throws {
            guard nextCost >= 0, nextCost <= GitHubDiscussionCommentClient.maximumCost, cost <= GitHubDiscussionCommentClient.maximumCost - nextCost else { throw GitHubDiscussionCommentClientError.queryCostExceeded(source, pages) }
            guard nextBytes <= GitHubDiscussionCommentClient.maximumBytes, bytes <= GitHubDiscussionCommentClient.maximumBytes - nextBytes else { throw GitHubDiscussionCommentClientError.aggregateLimitExceeded(source, pages) }
            cost += nextCost; bytes += nextBytes
        }
    }
    private nonisolated static func cursorComponent(_ value: String?) -> String { value.map { Data($0.utf8).base64EncodedString() } ?? "none" }
}
