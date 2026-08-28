import Foundation

struct OrganizationProbeResult: Sendable {
    let organization: GitHubOrganizationDTO?
    let repositories: [GitHubRepositoryDTO]
    let accessState: OrganizationAccessState
    let ssoHeader: GitHubSSOHeader?
    let capabilities: [CapabilityAvailability]
}

actor GitHubCapabilityProbe {
    private let identityClient: GitHubIdentityClient
    private let clock: @Sendable () -> Date

    init(
        identityClient: GitHubIdentityClient,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identityClient = identityClient
        self.clock = clock
    }

    func probe(organizationLogin: String) async throws -> OrganizationProbeResult {
        let checkedAt = clock()
        do {
            let organizationResponse = try await identityClient.organization(named: organizationLogin)
            let repositoriesPage = try await identityClient.repositories(in: organizationLogin)
            let ssoHeader = organizationResponse.ssoHeader ?? repositoriesPage.ssoHeader
            let state = OrganizationAccessEvaluator.state(
                statusCode: 200,
                ssoHeader: ssoHeader
            )
            return OrganizationProbeResult(
                organization: organizationResponse.value,
                repositories: repositoriesPage.values,
                accessState: state,
                ssoHeader: ssoHeader,
                capabilities: capabilities(
                    privateRepositories: repositoriesPage.values.contains(where: \.isPrivate),
                    state: state,
                    checkedAt: checkedAt
                )
            )
        } catch let failure as GitHubFailure {
            let state = OrganizationAccessEvaluator.state(
                statusCode: failure.statusCode,
                ssoHeader: failure.ssoHeader
            )
            return OrganizationProbeResult(
                organization: nil,
                repositories: [],
                accessState: state,
                ssoHeader: failure.ssoHeader,
                capabilities: capabilities(
                    privateRepositories: false,
                    state: state,
                    checkedAt: checkedAt
                )
            )
        }
    }

    private func capabilities(
        privateRepositories: Bool,
        state: OrganizationAccessState,
        checkedAt: Date
    ) -> [CapabilityAvailability] {
        GitHubCapability.allCases.map { capability in
            let status: CapabilityStatus
            switch state {
            case .ssoAuthorizationRequired, .partialSSOAuthorization:
                status = .requiresSSO
            case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
                status = .requiresApproval
            case .available where capability == .privateRepositories:
                status = privateRepositories ? .available : .unknown
            case .available:
                status = .unknown
            case .inaccessible, .insufficientPermission, .organizationPolicyBlocked:
                status = .unavailable
            case .credentialExpired, .unknown:
                status = .unknown
            }
            return CapabilityAvailability(
                capability: capability,
                status: status,
                checkedAt: checkedAt
            )
        }
    }
}
