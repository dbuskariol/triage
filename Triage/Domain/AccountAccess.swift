import Foundation

enum AuthenticationKind: String, CaseIterable, Codable, Sendable {
    case oauth
    case fineGrainedPersonalAccessToken
    case classicPersonalAccessToken

    var title: String {
        switch self {
        case .oauth: "GitHub"
        case .fineGrainedPersonalAccessToken: "Fine-grained Personal Access Token"
        case .classicPersonalAccessToken: "Classic Personal Access Token"
        }
    }

    var supportsDirectCopilotAuthentication: Bool {
        self != .classicPersonalAccessToken
    }
}

enum CredentialStatus: String, Codable, Sendable {
    case active
    case expiring
    case expired
    case revoked
    case missing
    case capabilityLimited
}

enum OrganizationAccessState: String, Codable, Sendable {
    case available
    case ssoAuthorizationRequired
    case partialSSOAuthorization
    case organizationApprovalRequired
    case oauthApplicationApprovalRequired
    case organizationPolicyBlocked
    case insufficientPermission
    case inaccessible
    case credentialExpired
    case unknown
}

enum GitHubAccessRestriction: Equatable, Sendable {
    case organizationApprovalRequired
    case oauthApplicationApprovalRequired
    case organizationPolicyBlocked
}

enum CapabilityStatus: String, Codable, Sendable {
    case available
    case unavailable
    case unknown
    case requiresSSO
    case requiresApproval
    case notApplicable
}

enum GitHubCapability: String, CaseIterable, Codable, Sendable {
    case privateRepositories
    case visibleTeams
    case issueAndPullRequestSearch
    case pullRequestReviews
    case pullRequestReviewThreads
    case issueTimeline
    case discussions
    case projects
    case projectFields
    case notifications
    case copilot
    case copilotModels
}

enum GitHubCapabilityScope: Sendable {
    case account
    case organization
}

extension GitHubCapability {
    var scope: GitHubCapabilityScope {
        switch self {
        case .notifications:
            .account
        case .privateRepositories,
             .visibleTeams,
             .issueAndPullRequestSearch,
             .pullRequestReviews,
             .pullRequestReviewThreads,
             .issueTimeline,
             .discussions,
             .projects,
             .projectFields,
             .copilot,
             .copilotModels:
            .organization
        }
    }
}

struct CapabilityAvailability: Codable, Equatable, Sendable {
    let capability: GitHubCapability
    let status: CapabilityStatus
    let checkedAt: Date
    let detail: String?

    init(
        capability: GitHubCapability,
        status: CapabilityStatus,
        checkedAt: Date,
        detail: String? = nil
    ) {
        self.capability = capability
        self.status = status
        self.checkedAt = checkedAt
        self.detail = detail
    }
}

struct AccountCapabilitySnapshot: Codable, Equatable, Sendable {
    let accountID: AccountID
    let capabilities: [CapabilityAvailability]
    let checkedAt: Date

    init(
        accountID: AccountID,
        capabilities: [CapabilityAvailability],
        checkedAt: Date
    ) {
        self.accountID = accountID
        self.capabilities = capabilities
        self.checkedAt = checkedAt
    }

    func status(for capability: GitHubCapability) -> CapabilityStatus {
        capabilities.first(where: { $0.capability == capability })?.status ?? .unknown
    }
}

struct GitHubAccount: Codable, Equatable, Sendable, Identifiable {
    let id: AccountID
    let githubUserID: UInt64
    let nodeID: GitHubNodeID
    let login: String
    let displayName: String?
    let avatarURL: URL?
    let authenticationKind: AuthenticationKind
    let credentialID: CredentialID
    let credentialStatus: CredentialStatus
    let accessTokenExpiresAt: Date?
    let refreshTokenExpiresAt: Date?
    let createdAt: Date
    let lastValidatedAt: Date?

    init(
        id: AccountID,
        githubUserID: UInt64,
        nodeID: GitHubNodeID,
        login: String,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        authenticationKind: AuthenticationKind,
        credentialID: CredentialID,
        credentialStatus: CredentialStatus,
        accessTokenExpiresAt: Date? = nil,
        refreshTokenExpiresAt: Date? = nil,
        createdAt: Date,
        lastValidatedAt: Date? = nil
    ) {
        self.id = id
        self.githubUserID = githubUserID
        self.nodeID = nodeID
        self.login = login
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.authenticationKind = authenticationKind
        self.credentialID = credentialID
        self.credentialStatus = credentialStatus
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.createdAt = createdAt
        self.lastValidatedAt = lastValidatedAt
    }

    func replacingCredentialExpiration(
        accessTokenExpiresAt: Date?,
        refreshTokenExpiresAt: Date?,
        status: CredentialStatus,
        validatedAt: Date
    ) -> GitHubAccount {
        GitHubAccount(
            id: id,
            githubUserID: githubUserID,
            nodeID: nodeID,
            login: login,
            displayName: displayName,
            avatarURL: avatarURL,
            authenticationKind: authenticationKind,
            credentialID: credentialID,
            credentialStatus: status,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            createdAt: createdAt,
            lastValidatedAt: validatedAt
        )
    }

    func replacingCredentialStatus(_ status: CredentialStatus) -> GitHubAccount {
        GitHubAccount(
            id: id,
            githubUserID: githubUserID,
            nodeID: nodeID,
            login: login,
            displayName: displayName,
            avatarURL: avatarURL,
            authenticationKind: authenticationKind,
            credentialID: credentialID,
            credentialStatus: status,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            createdAt: createdAt,
            lastValidatedAt: lastValidatedAt
        )
    }

    func replacingCredential(
        credentialID: CredentialID,
        login: String,
        displayName: String?,
        avatarURL: URL?,
        accessTokenExpiresAt: Date?,
        refreshTokenExpiresAt: Date?,
        status: CredentialStatus,
        validatedAt: Date
    ) -> GitHubAccount {
        GitHubAccount(
            id: id,
            githubUserID: githubUserID,
            nodeID: nodeID,
            login: login,
            displayName: displayName,
            avatarURL: avatarURL,
            authenticationKind: authenticationKind,
            credentialID: credentialID,
            credentialStatus: status,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            createdAt: createdAt,
            lastValidatedAt: validatedAt
        )
    }
}

struct GitHubOrganization: Codable, Equatable, Sendable, Identifiable {
    let id: OrganizationID
    let githubOrganizationID: UInt64
    let nodeID: GitHubNodeID
    let login: String
    let displayName: String?
    let avatarURL: URL?

    init(
        id: OrganizationID,
        githubOrganizationID: UInt64,
        nodeID: GitHubNodeID,
        login: String,
        displayName: String? = nil,
        avatarURL: URL? = nil
    ) {
        self.id = id
        self.githubOrganizationID = githubOrganizationID
        self.nodeID = nodeID
        self.login = login
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

struct OrganizationAccess: Codable, Equatable, Sendable {
    let accountID: AccountID
    let organizationID: OrganizationID
    let state: OrganizationAccessState
    let capabilityRevision: CapabilityRevision
    let capabilities: [CapabilityAvailability]
    let checkedAt: Date

    init(
        accountID: AccountID,
        organizationID: OrganizationID,
        state: OrganizationAccessState,
        capabilityRevision: CapabilityRevision,
        capabilities: [CapabilityAvailability],
        checkedAt: Date
    ) {
        self.accountID = accountID
        self.organizationID = organizationID
        self.state = state
        self.capabilityRevision = capabilityRevision
        self.capabilities = capabilities
        self.checkedAt = checkedAt
    }

    func status(for capability: GitHubCapability) -> CapabilityStatus {
        capabilities.first(where: { $0.capability == capability })?.status ?? .unknown
    }
}
