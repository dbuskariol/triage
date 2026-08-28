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
    let url: URL

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
