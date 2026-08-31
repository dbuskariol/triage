import Foundation

enum CoverageFeature: String, CaseIterable, Codable, Sendable {
    case repositories
    case teams
    case issues
    case pullRequests
    case reviews
    case reviewThreads
    /// The exact, pull-request-scoped GraphQL status-check rollup. This is
    /// intentionally distinct from review history: an unavailable rollup must
    /// never be interpreted as an all-green pull request.
    case statusChecks
    case timelines
    case notifications
    case discussions
    case discussionComments
    case discussionReplies
    case projects
    case projectItems
    case roleDiscovery
    /// The selected organization's REST metadata is source authority for the
    /// capability/access probe; it deliberately has its own replay stream.
    case organizationMetadata
}

enum CoverageStatus: String, Codable, Sendable {
    case complete
    case partial
    case unavailable
    case requiresSSO
    case requiresApproval
    case failed
    case unknown
}

enum FreshnessStatus: String, Codable, Sendable {
    case fresh
    case refreshing
    case stale
    case partial
    case offline
    case authenticationRequired
    case ssoRequired
    case approvalRequired
    case rateLimited
    case failed
}

struct FreshnessState: Codable, Equatable, Sendable {
    let status: FreshnessStatus
    let lastSuccessfulSyncAt: Date?
    let nextRetryAt: Date?
    let detail: String?

    init(
        status: FreshnessStatus,
        lastSuccessfulSyncAt: Date? = nil,
        nextRetryAt: Date? = nil,
        detail: String? = nil
    ) {
        self.status = status
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.nextRetryAt = nextRetryAt
        self.detail = detail
    }
}

struct CoverageRecord: Codable, Equatable, Sendable {
    let accountID: AccountID
    let organizationID: OrganizationID
    let repositoryID: RepositoryID?
    let feature: CoverageFeature
    let streamID: SyncStreamID
    let intervalStart: Date?
    let intervalEnd: Date?
    let credentialRevision: CredentialRevision
    let capabilityRevision: CapabilityRevision
    let status: CoverageStatus
    let lastSuccessfulAt: Date?
    let failureDetail: String?
}

struct SynchronizationScope: Hashable, Codable, Sendable {
    let accountID: AccountID
    let organizationID: OrganizationID
    let credentialRevision: CredentialRevision
    let capabilityRevision: CapabilityRevision
}
