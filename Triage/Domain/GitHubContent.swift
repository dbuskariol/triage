import Foundation

enum GitHubContentKind: String, CaseIterable, Codable, Sendable {
    case issue
    case pullRequest
    case pullRequestReview
    case pullRequestReviewThread
    case pullRequestReviewComment
    case issueComment
    case discussion
    case discussionComment
    case discussionReply
    case project
    case projectItem
    case projectDraftIssue
    case repository
    case milestone
    case label
    case team
    case actor
    case commit
    case statusCheck
    case timelineEvent
    case notificationThread
}

enum GitHubItemState: String, Codable, Sendable {
    case open
    case closed
    case merged
    case draft
    case active
    case completed
    case archived
    case unknown
}

struct RepositorySummary: Codable, Equatable, Sendable, Identifiable {
    let id: RepositoryID
    let nodeID: GitHubNodeID
    let ownerLogin: String
    let name: String
    let isPrivate: Bool
    let isArchived: Bool
    let hasDiscussions: Bool
    /// False means GitHub omitted the capability and Triage must not interpret
    /// `hasDiscussions == false` as authoritative feature disablement.
    let hasDiscussionsKnown: Bool
    let url: URL

    init(
        id: RepositoryID,
        nodeID: GitHubNodeID,
        ownerLogin: String,
        name: String,
        isPrivate: Bool,
        isArchived: Bool,
        hasDiscussions: Bool,
        hasDiscussionsKnown: Bool = true,
        url: URL
    ) {
        self.id = id
        self.nodeID = nodeID
        self.ownerLogin = ownerLogin
        self.name = name
        self.isPrivate = isPrivate
        self.isArchived = isArchived
        self.hasDiscussions = hasDiscussions
        self.hasDiscussionsKnown = hasDiscussionsKnown
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id, nodeID, ownerLogin, name, isPrivate, isArchived
        case hasDiscussions, hasDiscussionsKnown, url
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(RepositoryID.self, forKey: .id),
            nodeID: try values.decode(GitHubNodeID.self, forKey: .nodeID),
            ownerLogin: try values.decode(String.self, forKey: .ownerLogin),
            name: try values.decode(String.self, forKey: .name),
            isPrivate: try values.decode(Bool.self, forKey: .isPrivate),
            isArchived: try values.decode(Bool.self, forKey: .isArchived),
            hasDiscussions: try values.decode(Bool.self, forKey: .hasDiscussions),
            hasDiscussionsKnown: try values.decodeIfPresent(Bool.self, forKey: .hasDiscussionsKnown) ?? false,
            url: try values.decode(URL.self, forKey: .url)
        )
    }

    var fullName: String {
        "\(ownerLogin)/\(name)"
    }
}

struct ActorSummary: Codable, Equatable, Sendable, Identifiable {
    let id: ActorID
    let nodeID: GitHubNodeID
    let login: String
    let displayName: String?
    let avatarURL: URL?
}

struct GitHubContentSummary: Codable, Equatable, Sendable, Identifiable {
    let id: GitHubNodeID
    let kind: GitHubContentKind
    let repository: RepositorySummary?
    let number: Int?
    let title: String
    let state: GitHubItemState
    let author: ActorSummary?
    let url: URL
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let mergedAt: Date?
}

enum TimelineEventKind: String, Codable, Sendable {
    case assigned
    case unassigned
    case commented
    case reviewed
    case reviewRequested
    case reviewRequestRemoved
    case reviewDismissed
    case reviewThreadResolved
    case reviewThreadUnresolved
    case labeled
    case unlabeled
    case mentioned
    case crossReferenced
    case committed
    case closed
    case reopened
    case merged
    case transferred
    case addedToProject
    case removedFromProject
    case milestoneChanged
    case renamed
    case unknown
}

struct TimelineEventSummary: Codable, Equatable, Sendable, Identifiable {
    let id: GitHubEventID
    let subjectNodeID: GitHubNodeID
    let kind: TimelineEventKind
    let actor: ActorSummary?
    let occurredAt: Date
    let url: URL?
    let body: String?
}

enum ReviewState: String, Codable, Sendable {
    case approved
    case changesRequested
    case commented
    case pending
    case dismissed
}

struct PullRequestReviewSummary: Codable, Equatable, Sendable, Identifiable {
    let id: GitHubNodeID
    let pullRequestNodeID: GitHubNodeID
    let author: ActorSummary?
    let state: ReviewState
    let submittedAt: Date?
    let url: URL?
    let body: String?
}

struct ProjectFieldValue: Codable, Equatable, Sendable {
    let fieldName: String
    let displayValue: String?
    let dateValue: Date?
    let actorNodeID: GitHubNodeID?
}

struct ProjectItemSummary: Codable, Equatable, Sendable, Identifiable {
    let id: GitHubNodeID
    let projectNodeID: GitHubNodeID
    let contentNodeID: GitHubNodeID?
    let contentKind: GitHubContentKind?
    let updatedAt: Date
    let fieldValues: [ProjectFieldValue]
}
