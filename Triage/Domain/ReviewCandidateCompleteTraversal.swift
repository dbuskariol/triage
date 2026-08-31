import Foundation

/// The source stream represented by one immutable, fully traversed candidate.
/// A receipt is deliberately independent of normalized review rows so it can
/// authorize replacement only after raw source coverage is complete.
enum ReviewCandidateTraversalSegmentKind: String, CaseIterable, Codable, Sendable {
    case reviewHistory
    case requestedReviewers
    case reviewThreads
    case threadComments
}

struct ReviewCandidateTraversalPage: Equatable, Sendable {
    /// One-based position within its segment.
    let ordinal: Int
    let rawSnapshotID: RawAPISnapshotID
    let requestIdentity: ConditionalRequestIdentity
    let endpoint: String
    let eTag: String?
    let lastModified: String?
    let payload: Data
    /// Exactly the final page of every segment is terminal.
    let isTerminal: Bool

    init(
        ordinal: Int,
        rawSnapshotID: RawAPISnapshotID,
        requestIdentity: ConditionalRequestIdentity,
        endpoint: String,
        eTag: String? = nil,
        lastModified: String? = nil,
        payload: Data,
        isTerminal: Bool
    ) {
        self.ordinal = ordinal
        self.rawSnapshotID = rawSnapshotID
        self.requestIdentity = requestIdentity
        self.endpoint = endpoint
        self.eTag = eTag
        self.lastModified = lastModified
        self.payload = payload
        self.isTerminal = isTerminal
    }
}

struct ReviewCandidateTraversalSegment: Equatable, Sendable {
    let kind: ReviewCandidateTraversalSegmentKind
    /// Required only for `.threadComments`; this makes every discovered
    /// thread's comment traversal independently auditable.
    let parentThreadNodeID: GitHubNodeID?
    let pages: [ReviewCandidateTraversalPage]

    init(
        kind: ReviewCandidateTraversalSegmentKind,
        parentThreadNodeID: GitHubNodeID? = nil,
        pages: [ReviewCandidateTraversalPage]
    ) {
        self.kind = kind
        self.parentThreadNodeID = parentThreadNodeID
        self.pages = pages
    }
}

struct ReviewCandidateCompleteTraversal: Sendable {
    let id: UUID
    let scope: SynchronizationScope
    let feature: CoverageFeature
    let streamID: SyncStreamID
    let candidate: PullRequestReviewCandidate
    /// The current pull-request node source revision observed before traversal.
    let candidateSourceRevision: String
    let parserVersion: Int
    let observedAt: Date
    /// Stable digest of normalized candidate content. Exactly 32 bytes.
    let normalizedDigest: Data
    /// For `.reviewThreads`, exactly the normalized discovered thread IDs.
    let discoveredThreadNodeIDs: [GitHubNodeID]
    /// For `.reviewThreads`, the exact normalized comment IDs for every
    /// discovered thread. This binds each independently paginated raw comment
    /// connection to the replacement it may authorize.
    let discoveredCommentNodeIDsByThread: [GitHubNodeID: [GitHubNodeID]]
    let segments: [ReviewCandidateTraversalSegment]

    init(
        id: UUID = UUID(),
        scope: SynchronizationScope,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        candidate: PullRequestReviewCandidate,
        candidateSourceRevision: String,
        parserVersion: Int,
        observedAt: Date,
        normalizedDigest: Data,
        discoveredThreadNodeIDs: [GitHubNodeID] = [],
        discoveredCommentNodeIDsByThread: [GitHubNodeID: [GitHubNodeID]] = [:],
        segments: [ReviewCandidateTraversalSegment]
    ) {
        self.id = id
        self.scope = scope
        self.feature = feature
        self.streamID = streamID
        self.candidate = candidate
        self.candidateSourceRevision = candidateSourceRevision
        self.parserVersion = parserVersion
        self.observedAt = observedAt
        self.normalizedDigest = normalizedDigest
        self.discoveredThreadNodeIDs = discoveredThreadNodeIDs
        self.discoveredCommentNodeIDsByThread = discoveredCommentNodeIDsByThread
        self.segments = segments
    }
}

/// Opaque proof supplied to a destructive normalizer. It is useful only while
/// its source authority and candidate source revision are still current.
struct ReviewCandidateCompleteTraversalReceiptToken: Equatable, Hashable, Sendable {
    let id: UUID
    let scope: SynchronizationScope
    let feature: CoverageFeature
    let streamID: SyncStreamID
    let candidateNodeID: GitHubNodeID
    let repositoryID: RepositoryID
    let candidateSourceRevision: String
}
