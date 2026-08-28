import Foundation

enum EvidenceSource: String, Codable, Sendable {
    case restSearch
    case restTimeline
    case restReview
    case restNotification
    case graphQL
    case localWorkflow
    case copilot
}

struct EvidenceReference: Codable, Equatable, Sendable, Identifiable {
    let id: EvidenceID
    let source: EvidenceSource
    let nodeID: GitHubNodeID?
    let eventID: GitHubEventID?
    let sourceRevision: String?
    let observedAt: Date
    let excerpt: String?

    init(
        id: EvidenceID,
        source: EvidenceSource,
        nodeID: GitHubNodeID? = nil,
        eventID: GitHubEventID? = nil,
        sourceRevision: String? = nil,
        observedAt: Date,
        excerpt: String? = nil
    ) {
        self.id = id
        self.source = source
        self.nodeID = nodeID
        self.eventID = eventID
        self.sourceRevision = sourceRevision
        self.observedAt = observedAt
        self.excerpt = excerpt
    }
}

enum WorkRelationKind: String, Codable, Sendable {
    case authored
    case assigned
    case mentioned
    case teamMentioned
    case commented
    case reviewRequestedDirectly
    case reviewRequestedFromTeam
    case reviewed
    case changesRequested
    case awaitingResponse
    case parentOf
    case childOf
    case closes
    case closedBy
    case linkedPullRequest
    case crossReferences
    case blocks
    case blockedBy
    case duplicateOf
    case containsReview
    case containsThread
    case containsComment
    case projectWrapsContent
    case projectContext
}

enum RelationConfidence: String, Codable, Sendable {
    case provisional
    case confirmed
}

struct WorkRelation: Codable, Equatable, Sendable {
    let kind: WorkRelationKind
    let subjectNodeID: GitHubNodeID
    let objectNodeID: GitHubNodeID?
    let confidence: RelationConfidence
    let evidence: [EvidenceReference]
    let observedAt: Date
}

enum AttentionCategory: String, Codable, Sendable {
    case directResponsibility
    case conversation
    case pullRequest
    case progress
    case waiting
    case deadline
}

struct AttentionReason: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let category: AttentionCategory
    let ruleID: String
    let ruleVersion: Int
    let strength: Int
    let title: String
    let explanation: String
    let evidence: [EvidenceReference]
    let evaluatedAt: Date
}

struct AttentionScore: Codable, Equatable, Comparable, Sendable {
    let value: Int
    let breakdown: [String: Int]

    static func < (lhs: AttentionScore, rhs: AttentionScore) -> Bool {
        lhs.value < rhs.value
    }
}
