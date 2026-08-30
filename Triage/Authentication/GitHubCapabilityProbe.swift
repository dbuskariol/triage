import Foundation

enum GitHubCapabilityProbeError: Error, Equatable, Sendable {
    case organizationIdentityMismatch
}

struct OrganizationProbeResult: Sendable {
    let organization: GitHubOrganizationDTO?
    let repositories: [GitHubRepositoryDTO]
    let accessState: OrganizationAccessState
    let ssoHeader: GitHubSSOHeader?
    let capabilities: [CapabilityAvailability]
}

actor GitHubCapabilityProbe {
    private let identityClient: GitHubIdentityClient
    private let restClient: GitHubRESTClient?
    private let clock: @Sendable () -> Date

    init(
        identityClient: GitHubIdentityClient,
        restClient: GitHubRESTClient? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identityClient = identityClient
        self.restClient = restClient
        self.clock = clock
    }

    func probe(
        organization: GitHubOrganization,
        accountLogin: String? = nil
    ) async throws -> OrganizationProbeResult {
        let checkedAt = clock()
        do {
            let organizationResponse = try await identityClient.organization(named: organization.login)
            guard organizationResponse.value.id == organization.githubOrganizationID,
                  organizationResponse.value.nodeID == organization.nodeID.rawValue
            else {
                throw GitHubCapabilityProbeError.organizationIdentityMismatch
            }
            let repositoriesPage = try await identityClient.repositories(in: organization.login)
            let ssoHeader = GitHubSSOHeader.combined([
                organizationResponse.ssoHeader,
                repositoriesPage.ssoHeader
            ])?.scoped(to: organization.githubOrganizationID)
            let state = OrganizationAccessEvaluator.state(
                statusCode: 200,
                ssoHeader: ssoHeader
            )
            let probedStatuses: [GitHubCapability: CapabilityStatus]
            if state == .available, let restClient {
                probedStatuses = try await probeSupplementalCapabilities(
                    client: restClient,
                    organization: organization,
                    accountLogin: accountLogin,
                    repositories: repositoriesPage.values
                )
            } else {
                probedStatuses = [:]
            }
            return OrganizationProbeResult(
                organization: organizationResponse.value,
                repositories: repositoriesPage.values,
                accessState: state,
                ssoHeader: ssoHeader,
                capabilities: capabilities(
                    privateRepositories: repositoriesPage.values.contains(where: \.isPrivate),
                    probedStatuses: probedStatuses,
                    state: state,
                    checkedAt: checkedAt
                )
            )
        } catch let failure as GitHubFailure {
            let state = OrganizationAccessEvaluator.state(
                statusCode: failure.statusCode,
                ssoHeader: failure.ssoHeader,
                accessRestriction: failure.accessRestriction
            )
            return OrganizationProbeResult(
                organization: nil,
                repositories: [],
                accessState: state,
                ssoHeader: failure.ssoHeader,
                capabilities: capabilities(
                    privateRepositories: false,
                    probedStatuses: [:],
                    state: state,
                    checkedAt: checkedAt
                )
            )
        }
    }

    func probeAccountCapabilities() async throws -> [CapabilityAvailability] {
        let checkedAt = clock()
        guard let restClient else {
            return [
                CapabilityAvailability(
                    capability: .notifications,
                    status: .unknown,
                    checkedAt: checkedAt
                )
            ]
        }
        let status = try await probeAccountCapability(client: restClient) {
            try await restClient.getPage(
                CapabilityProbeObject.self,
                request: GitHubRESTRequest(
                    path: "/notifications",
                    query: [
                        URLQueryItem(name: "all", value: "true"),
                        URLQueryItem(name: "per_page", value: "1")
                    ]
                )
            ).ssoHeader
        }
        return [
            CapabilityAvailability(
                capability: .notifications,
                status: status,
                checkedAt: checkedAt
            )
        ]
    }

    private func capabilities(
        privateRepositories: Bool,
        probedStatuses: [GitHubCapability: CapabilityStatus],
        state: OrganizationAccessState,
        checkedAt: Date
    ) -> [CapabilityAvailability] {
        GitHubCapability.allCases
            .filter { $0.scope == .organization }
            .map { capability in
            let status: CapabilityStatus
            if unsupportedCapabilityStatus(for: capability) == .unavailable {
                status = .unavailable
            } else {
                switch state {
            case .ssoAuthorizationRequired, .partialSSOAuthorization:
                status = .requiresSSO
            case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
                status = .requiresApproval
            case .available where capability == .privateRepositories:
                status = privateRepositories ? .available : (probedStatuses[capability] ?? .unknown)
            case .available:
                status = probedStatuses[capability] ?? unsupportedCapabilityStatus(for: capability)
            case .inaccessible, .insufficientPermission, .organizationPolicyBlocked:
                status = .unavailable
            case .credentialExpired, .unknown:
                status = .unknown
                    }
            }
            return CapabilityAvailability(
                capability: capability,
                status: status,
                checkedAt: checkedAt
            )
        }
    }

    private func unsupportedCapabilityStatus(for capability: GitHubCapability) -> CapabilityStatus {
        switch capability {
        case .pullRequestReviewThreads, .discussions, .projects, .projectFields:
            .unknown
        case .copilot:
            .unavailable
        case .copilotModels:
            .unavailable
        case .privateRepositories,
             .visibleTeams,
             .issueAndPullRequestSearch,
             .pullRequestReviews,
             .issueTimeline,
             .notifications:
            .unknown
        }
    }

    private func probeSupplementalCapabilities(
        client: GitHubRESTClient,
        organization: GitHubOrganization,
        accountLogin: String?,
        repositories: [GitHubRepositoryDTO]
    ) async throws -> [GitHubCapability: CapabilityStatus] {
        var statuses: [GitHubCapability: CapabilityStatus] = [:]
        statuses[.visibleTeams] = try await probe(client: client, organization: organization) {
            try await client.getPage(
                CapabilityProbeObject.self,
                request: GitHubRESTRequest(
                    path: "/orgs/\(organization.login)/teams",
                    query: [URLQueryItem(name: "per_page", value: "1")]
                )
            ).ssoHeader
        }
        if let accountLogin {
            statuses[.issueAndPullRequestSearch] = try await probe(client: client, organization: organization) {
                let query = try GitHubIssueSearchQuery(
                    organizationLogin: organization.login,
                    userLogin: accountLogin,
                    state: .open,
                    relationship: .involves
                )
                return try await GitHubIssueSearchClient(client: client).searchResponse(query).ssoHeader
            }
        }
        try Task.checkCancellation()

        guard let repository = repositories.first(where: { !$0.isArchived }),
              let repositoryPath = try? GitHubRepositoryPath(
                  owner: repository.owner.login,
                  repository: repository.name
              )
        else {
            return statuses
        }

        let pullRequests: GitHubPage<CapabilityProbePullRequest>
        do {
            pullRequests = try await client.getPage(
                CapabilityProbePullRequest.self,
                request: GitHubRESTRequest(
                    path: "\(repositoryPath.path)/pulls",
                    query: [
                        URLQueryItem(name: "state", value: "open"),
                        URLQueryItem(name: "per_page", value: "1")
                    ]
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if capabilityStatus(for: error, organization: organization) == .requiresSSO {
                statuses[.pullRequestReviews] = .requiresSSO
                statuses[.issueTimeline] = .requiresSSO
            }
            return statuses
        }

        if let ssoHeader = pullRequests.ssoHeader?.scoped(to: organization.githubOrganizationID) {
            let status = capabilityStatus(for: ssoHeader)
            statuses[.pullRequestReviews] = status
            statuses[.issueTimeline] = status
            return statuses
        }
        guard let pullRequest = pullRequests.values.first else {
            return statuses
        }
        statuses[.pullRequestReviews] = try await probe(client: client, organization: organization) {
            let reviews = try await GitHubPullRequestClient(client: client).reviews(
                repository: repositoryPath,
                number: pullRequest.number
            )
            let requestedReviewers = try await GitHubPullRequestClient(client: client).requestedReviewers(
                repository: repositoryPath,
                number: pullRequest.number
            )
            return GitHubSSOHeader.combined([reviews.ssoHeader, requestedReviewers.ssoHeader])
        }
        try Task.checkCancellation()
        statuses[.issueTimeline] = try await probe(client: client, organization: organization) {
            try await GitHubTimelineClient(client: client).timeline(
                repository: repositoryPath,
                issueOrPullRequestNumber: pullRequest.number
            ).ssoHeader
        }
        return statuses
    }

    private func probe(
        client: GitHubRESTClient,
        organization: GitHubOrganization,
        operation: @escaping @Sendable () async throws -> GitHubSSOHeader?
    ) async throws -> CapabilityStatus {
        do {
            return capabilityStatus(for: try await operation(), organization: organization)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return capabilityStatus(for: error, organization: organization)
        }
    }

    private func probeAccountCapability(
        client: GitHubRESTClient,
        operation: @escaping @Sendable () async throws -> GitHubSSOHeader?
    ) async throws -> CapabilityStatus {
        do {
            return capabilityStatus(for: try await operation())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return capabilityStatus(for: error)
        }
    }

    private func capabilityStatus(
        for header: GitHubSSOHeader?,
        organization: GitHubOrganization
    ) -> CapabilityStatus {
        capabilityStatus(for: header?.scoped(to: organization.githubOrganizationID))
    }

    private func capabilityStatus(for header: GitHubSSOHeader?) -> CapabilityStatus {
        switch header {
        case .authorizationRequired, .partialResults:
            .requiresSSO
        case .malformed:
            .unknown
        case nil:
            .available
        }
    }

    private func capabilityStatus(
        for error: Error,
        organization: GitHubOrganization
    ) -> CapabilityStatus {
        guard let failure = error as? GitHubFailure else {
            return .unknown
        }
        if let ssoHeader = failure.ssoHeader?.scoped(to: organization.githubOrganizationID),
           case .authorizationRequired = ssoHeader {
            return .requiresSSO
        }
        if let ssoHeader = failure.ssoHeader?.scoped(to: organization.githubOrganizationID),
           case .partialResults = ssoHeader {
            return .requiresSSO
        }
        switch failure.accessRestriction {
        case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
            return .requiresApproval
        case .organizationPolicyBlocked:
            return .unavailable
        case nil:
            break
        }
        switch failure.kind {
        case .forbidden, .notFound:
            return .unavailable
        case .unauthorized,
             .rateLimited,
             .secondaryRateLimited,
             .serverFailure,
             .unexpectedResponse:
            return .unknown
        }
    }

    private func capabilityStatus(for error: Error) -> CapabilityStatus {
        guard let failure = error as? GitHubFailure else {
            return .unknown
        }
        if let ssoHeader = failure.ssoHeader,
           case .authorizationRequired = ssoHeader {
            return .requiresSSO
        }
        if let ssoHeader = failure.ssoHeader,
           case .partialResults = ssoHeader {
            return .requiresSSO
        }
        switch failure.accessRestriction {
        case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
            return .requiresApproval
        case .organizationPolicyBlocked:
            return .unavailable
        case nil:
            break
        }
        switch failure.kind {
        case .forbidden, .notFound:
            return .unavailable
        case .unauthorized,
             .rateLimited,
             .secondaryRateLimited,
             .serverFailure,
             .unexpectedResponse:
            return .unknown
        }
    }
}

private struct CapabilityProbeObject: Decodable, Sendable {}

private struct CapabilityProbePullRequest: Decodable, Sendable {
    let number: Int
}
