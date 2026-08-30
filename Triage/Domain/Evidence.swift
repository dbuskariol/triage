import Foundation

enum EvidenceSource: String, Codable, Sendable {
    case restSearch
    case restTimeline
    case restReview
    case restNotification
    case graphQL
    case localWorkflow
    case copilot
    /// Evidence imported from the pre-authority work-graph schema. It is
    /// deliberately not a source a synchronizer may produce.
    case legacyUnverified
}

enum EvidenceLocator: Codable, Equatable, Sendable {
    case endpoint(String)
    case query(String)
    case localWorkflow(String)
    case legacyUnverified

    var kind: String {
        switch self {
        case .endpoint: "endpoint"
        case .query: "query"
        case .localWorkflow: "localWorkflow"
        case .legacyUnverified: "legacyUnverified"
        }
    }

    var value: String {
        switch self {
        case let .endpoint(value), let .query(value), let .localWorkflow(value): value
        case .legacyUnverified: "legacy-unverified"
        }
    }

    init?(kind: String, value: String) {
        switch kind {
        case "endpoint": self = .endpoint(value)
        case "query": self = .query(value)
        case "localWorkflow": self = .localWorkflow(value)
        case "legacyUnverified" where value == "legacy-unverified": self = .legacyUnverified
        default: return nil
        }
    }
}

/// The authority which produced an evidence item. GitHub authority is exact
/// and revision-bound; local workflow evidence is explicitly local rather
/// than impersonating a GitHub source. The legacy case is migration-only.
enum EvidenceAuthority: Codable, Equatable, Sendable {
    case github(
        scope: SynchronizationScope,
        feature: CoverageFeature,
        streamID: SyncStreamID
    )
    case localWorkflow(accountID: AccountID, organizationID: OrganizationID)
    case legacyUnverified
}

enum EvidenceConfirmation: String, Codable, Sendable {
    case provisional
    case confirmed
}

struct EvidenceReference: Codable, Equatable, Sendable, Identifiable {
    let id: EvidenceID
    let source: EvidenceSource
    let locator: EvidenceLocator
    let authority: EvidenceAuthority
    let nodeID: GitHubNodeID?
    let eventID: GitHubEventID?
    let sourceRevision: String?
    let rawSnapshotID: RawAPISnapshotID?
    /// Relation strength is independent of whether this observation was
    /// fully reconciled and confirmed.
    let confidence: RelationConfidence
    let confirmation: EvidenceConfirmation
    let observedAt: Date
    let excerpt: String?

    init(
        id: EvidenceID,
        source: EvidenceSource,
        locator: EvidenceLocator,
        authority: EvidenceAuthority,
        nodeID: GitHubNodeID? = nil,
        eventID: GitHubEventID? = nil,
        sourceRevision: String? = nil,
        rawSnapshotID: RawAPISnapshotID? = nil,
        confidence: RelationConfidence,
        confirmation: EvidenceConfirmation,
        observedAt: Date,
        excerpt: String? = nil
    ) {
        self.id = id
        self.source = source
        self.locator = locator
        self.authority = authority
        self.nodeID = nodeID
        self.eventID = eventID
        self.sourceRevision = sourceRevision
        self.rawSnapshotID = rawSnapshotID
        self.confidence = confidence
        self.confirmation = confirmation
        self.observedAt = observedAt
        self.excerpt = excerpt
    }

    /// Compatibility for non-persisted rule fixtures that predate durable
    /// provenance. New persisted relation evidence must use the designated
    /// initializer above; this deliberately labels the missing authority as
    /// unverified instead of guessing a GitHub endpoint or local workflow.
    @available(*, deprecated, message: "Provide explicit evidence locator, authority, confidence, and confirmation.")
    init(
        id: EvidenceID,
        source: EvidenceSource,
        nodeID: GitHubNodeID? = nil,
        eventID: GitHubEventID? = nil,
        sourceRevision: String? = nil,
        observedAt: Date,
        excerpt: String? = nil
    ) {
        self.init(
            id: id,
            source: source,
            locator: .legacyUnverified,
            authority: .legacyUnverified,
            nodeID: nodeID,
            eventID: eventID,
            sourceRevision: sourceRevision,
            rawSnapshotID: nil,
            confidence: .provisional,
            confirmation: .provisional,
            observedAt: observedAt,
            excerpt: excerpt
        )
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
