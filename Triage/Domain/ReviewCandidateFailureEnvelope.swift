import Foundation

/// A deliberately header-free classification for a terminal review-candidate
/// source attempt. The associated durable raw snapshots remain encrypted in
/// the vault; this record retains only redacted, user-safe context.
enum ReviewCandidateFailureClassification: String, CaseIterable, Codable, Sendable {
    case authenticationRequired
    case ssoRequired
    case approvalRequired
    case rateLimited
    case unavailableOrPermission
    case transportFailure
    case serverFailure
    case malformedResponse
    case normalizationFailure
}

/// Distinguishes a request that reached a durable terminal response from a
/// source attempt for which a response body must not be retained as raw
/// provenance. The latter is deliberately limited to transport failures and
/// bodyless GitHub access responses, never arbitrary HTTP error payloads.
enum ReviewCandidateFailureRawProvenance: Equatable, Sendable {
    case terminalRawPage
    case zeroRawTransportFailure
    case zeroRawBodylessHTTPAccessFailure(statusCode: Int)
}

/// A raw page accumulated before a terminal candidate failure. `ordinal` is
/// one-based and must be contiguous within its exact request identity when it
/// is published. The only response header values accepted are cache validators;
/// authorization, cookie, and SSO headers have no representation here.
struct ReviewCandidateFailureRawPage: Equatable, Sendable {
    let ordinal: Int
    let rawSnapshotID: RawAPISnapshotID
    let requestIdentity: ConditionalRequestIdentity
    let endpoint: String
    let eTag: String?
    let lastModified: String?
    let payload: Data

    init(
        ordinal: Int,
        rawSnapshotID: RawAPISnapshotID,
        requestIdentity: ConditionalRequestIdentity,
        endpoint: String,
        eTag: String? = nil,
        lastModified: String? = nil,
        payload: Data
    ) {
        self.ordinal = ordinal
        self.rawSnapshotID = rawSnapshotID
        self.requestIdentity = requestIdentity
        self.endpoint = endpoint
        self.eTag = eTag
        self.lastModified = lastModified
        self.payload = payload
    }
}

/// The data supplied for one failed candidate attempt. `requestIdentity` is
/// intentionally exact: account, organization, feature, stream, credential
/// revision, capability revision, and request key must all agree with the
/// envelope before it is made durable.
struct ReviewCandidateFailurePublication: Sendable {
    let id: UUID
    let scope: SynchronizationScope
    let feature: CoverageFeature
    let streamID: SyncStreamID
    let candidate: PullRequestReviewCandidate
    let requestIdentity: ConditionalRequestIdentity
    let parserVersion: Int
    let attemptedAt: Date
    let terminalAt: Date
    let classification: ReviewCandidateFailureClassification
    let redactedDiagnostic: String
    let rawProvenance: ReviewCandidateFailureRawProvenance
    let rawPages: [ReviewCandidateFailureRawPage]

    init(
        id: UUID = UUID(),
        scope: SynchronizationScope,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        candidate: PullRequestReviewCandidate,
        requestIdentity: ConditionalRequestIdentity,
        parserVersion: Int,
        attemptedAt: Date,
        terminalAt: Date,
        classification: ReviewCandidateFailureClassification,
        redactedDiagnostic: String,
        rawProvenance: ReviewCandidateFailureRawProvenance = .terminalRawPage,
        rawPages: [ReviewCandidateFailureRawPage]
    ) {
        self.id = id
        self.scope = scope
        self.feature = feature
        self.streamID = streamID
        self.candidate = candidate
        self.requestIdentity = requestIdentity
        self.parserVersion = parserVersion
        self.attemptedAt = attemptedAt
        self.terminalAt = terminalAt
        self.classification = classification
        self.redactedDiagnostic = redactedDiagnostic
        self.rawProvenance = rawProvenance
        self.rawPages = rawPages
    }
}

/// Immutable, query-safe evidence for a terminal failed review candidate.
/// It carries raw snapshot identifiers rather than bodies or headers.
struct ReviewCandidateFailureEnvelope: Equatable, Sendable {
    let id: UUID
    let scope: SynchronizationScope
    let feature: CoverageFeature
    let streamID: SyncStreamID
    let candidateNodeID: GitHubNodeID
    let repositoryID: RepositoryID
    let requestIdentity: ConditionalRequestIdentity
    let parserVersion: Int
    let attemptedAt: Date
    let terminalAt: Date
    let classification: ReviewCandidateFailureClassification
    let redactedDiagnostic: String
    let rawSnapshotIDs: [RawAPISnapshotID]
}
