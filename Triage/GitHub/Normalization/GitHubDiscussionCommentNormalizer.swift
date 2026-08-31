import Foundation

enum GitHubDiscussionCommentNormalizationError: Error, Equatable, Sendable {
    case invalidComment
    case invalidReply
    case duplicateNodeID
    case invalidActor
    case parentMismatch
}

struct DiscussionCommentRecord: Equatable, Sendable {
    let nodeID: GitHubNodeID
    let discussionNodeID: GitHubNodeID
    let parentNodeID: GitHubNodeID
    let kind: GitHubContentKind
    let author: ActorSummary?
    let body: String
    let createdAt: Date
    let updatedAt: Date
    let url: URL
}

struct DiscussionCommentNormalizationResult: Sendable {
    let comments: [DiscussionCommentRecord]
    let replies: [DiscussionCommentRecord]
}

enum GitHubDiscussionCommentNormalizer {
    static func validateCommentPayloads(_ comments: [GitHubDiscussionCommentPagePayload.Comment]) throws {
        var identifiers = Set<GitHubNodeID>()
        for comment in comments {
            guard let identifier = GitHubNodeID(rawValue: comment.id), identifiers.insert(identifier).inserted,
                  comment.replies.totalCount >= 0 else { throw GitHubDiscussionCommentNormalizationError.invalidComment }
            try validate(body: comment.body, createdAt: comment.createdAt, updatedAt: comment.updatedAt, url: comment.url, actor: comment.author)
        }
    }

    static func normalize(
        discussionNodeID: GitHubNodeID,
        comments: [GitHubDiscussionCommentPagePayload.Comment],
        repliesByParent: [GitHubNodeID: [GitHubDiscussionReplyPagePayload.Reply]]
    ) throws -> DiscussionCommentNormalizationResult {
        try validateCommentPayloads(comments)
        var identifiers = Set<GitHubNodeID>()
        var normalizedComments = [DiscussionCommentRecord](); var normalizedReplies = [DiscussionCommentRecord]()
        for value in comments {
            guard let nodeID = GitHubNodeID(rawValue: value.id), identifiers.insert(nodeID).inserted else { throw GitHubDiscussionCommentNormalizationError.duplicateNodeID }
            let author = try actor(value.author)
            normalizedComments.append(.init(nodeID: nodeID, discussionNodeID: discussionNodeID, parentNodeID: discussionNodeID, kind: .discussionComment, author: author, body: value.body, createdAt: value.createdAt, updatedAt: value.updatedAt, url: value.url))
            guard let replies = repliesByParent[nodeID] else { throw GitHubDiscussionCommentNormalizationError.parentMismatch }
            for reply in replies {
                guard let replyID = GitHubNodeID(rawValue: reply.id), identifiers.insert(replyID).inserted else { throw GitHubDiscussionCommentNormalizationError.duplicateNodeID }
                try validate(body: reply.body, createdAt: reply.createdAt, updatedAt: reply.updatedAt, url: reply.url, actor: reply.author)
                normalizedReplies.append(.init(nodeID: replyID, discussionNodeID: discussionNodeID, parentNodeID: nodeID, kind: .discussionReply, author: try actor(reply.author), body: reply.body, createdAt: reply.createdAt, updatedAt: reply.updatedAt, url: reply.url))
            }
        }
        return .init(comments: normalizedComments, replies: normalizedReplies)
    }

    private static func validate<Actor>(body: String, createdAt: Date, updatedAt: Date, url: URL, actor: Actor?) throws {
        guard createdAt.timeIntervalSinceReferenceDate.isFinite, updatedAt.timeIntervalSinceReferenceDate.isFinite, createdAt <= updatedAt,
              url.scheme == "https", url.host == "github.com" else { throw GitHubDiscussionCommentNormalizationError.invalidComment }
    }

    private static func actor(_ value: GitHubDiscussionCommentPagePayload.Actor?) throws -> ActorSummary? {
        guard let value else { return nil }
        return try actor(id: value.id, login: value.login, avatarURL: value.avatarUrl)
    }
    private static func actor(_ value: GitHubDiscussionReplyPagePayload.Actor?) throws -> ActorSummary? {
        guard let value else { return nil }
        return try actor(id: value.id, login: value.login, avatarURL: value.avatarUrl)
    }
    private static func actor(id: String, login: String, avatarURL: URL?) throws -> ActorSummary {
        guard let actorID = ActorID(rawValue: id), let nodeID = GitHubNodeID(rawValue: id), !login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitHubDiscussionCommentNormalizationError.invalidActor }
        return .init(id: actorID, nodeID: nodeID, login: login, displayName: nil, avatarURL: avatarURL)
    }
}
