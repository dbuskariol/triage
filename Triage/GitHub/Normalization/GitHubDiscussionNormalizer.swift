import Foundation

enum GitHubDiscussionNormalizationError: Error, Equatable, Sendable {
    case missingDiscussionID
    case duplicateDiscussionID
    case invalidDiscussion
}

struct GitHubDiscussionRecord: Equatable, Sendable {
    let nodeID: GitHubNodeID
    let number: Int
    let title: String
    let body: String?
    let url: URL
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let state: GitHubItemState
    let categoryName: String?
    let answerCommentNodeID: GitHubNodeID?
    let commentsCount: Int
}

struct GitHubDiscussionPayload: Decodable, Sendable {
    let node: Repository?
    let rateLimit: RateLimit

    struct Repository: Decodable, Sendable {
        let id: String
        let discussions: Connection
    }

    struct Connection: Decodable, Sendable {
        let nodes: [Discussion?]
        let pageInfo: PageInfo
    }

    struct Discussion: Decodable, Sendable {
        let id: String
        let number: Int
        let title: String
        let body: String?
        let url: URL
        let createdAt: Date
        let updatedAt: Date
        let closedAt: Date?
        let isAnswered: Bool
        let category: Category?
        let answer: Answer?
        let comments: Comments
    }

    struct Category: Decodable, Sendable { let name: String }
    struct Answer: Decodable, Sendable { let id: String }
    struct Comments: Decodable, Sendable { let totalCount: Int }
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

enum GitHubDiscussionNormalizer {
    static func normalize(_ discussions: [GitHubDiscussionPayload.Discussion]) throws -> [GitHubDiscussionRecord] {
        var identifiers = Set<GitHubNodeID>()
        return try discussions.map { discussion in
            guard let nodeID = GitHubNodeID(rawValue: discussion.id) else {
                throw GitHubDiscussionNormalizationError.missingDiscussionID
            }
            guard identifiers.insert(nodeID).inserted else {
                throw GitHubDiscussionNormalizationError.duplicateDiscussionID
            }
            guard
                  discussion.number > 0,
                  !discussion.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  discussion.createdAt <= discussion.updatedAt,
                  discussion.closedAt.map({ $0 >= discussion.createdAt }) ?? true,
                  discussion.comments.totalCount >= 0,
                  discussion.url.scheme == "https",
                  discussion.url.host == "github.com"
            else {
                throw GitHubDiscussionNormalizationError.invalidDiscussion
            }
            let answerID = discussion.answer.flatMap { GitHubNodeID(rawValue: $0.id) }
            guard (discussion.answer == nil || answerID != nil),
                  discussion.isAnswered == (answerID != nil)
            else {
                throw GitHubDiscussionNormalizationError.invalidDiscussion
            }
            return GitHubDiscussionRecord(
                nodeID: nodeID,
                number: discussion.number,
                title: discussion.title,
                body: discussion.body,
                url: discussion.url,
                createdAt: discussion.createdAt,
                updatedAt: discussion.updatedAt,
                closedAt: discussion.closedAt,
                state: discussion.closedAt == nil ? .open : .closed,
                categoryName: discussion.category?.name,
                answerCommentNodeID: answerID,
                commentsCount: discussion.comments.totalCount
            )
        }
    }
}
