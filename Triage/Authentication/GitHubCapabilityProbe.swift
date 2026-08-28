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
    private let clock: @Sendable () -> Date

    init(
        identityClient: GitHubIdentityClient,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identityClient = identityClient
        self.clock = clock
    }

    func probe(organization: GitHubOrganization) async throws -> OrganizationProbeResult {
        let checkedAt = clock()
        do {
            let organizationResponse = try await identityClient.organization(named: organization.login)
            guard organizationResponse.value.id == organization.githubOrganizationID,
                  organizationResponse.value.nodeID == organization.nodeID.rawValue
            else {
                throw GitHubCapabilityProbeError.organizationIdentityMismatch
            }
            let repositoriesPage = try await identityClient.repositories(in: organization.login)
            let ssoHeader = scopedSSOHeader(
                organizationResponse.ssoHeader ?? repositoriesPage.ssoHeader,
                organization: organization
            )
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

    private func scopedSSOHeader(
        _ header: GitHubSSOHeader?,
        organization: GitHubOrganization
    ) -> GitHubSSOHeader? {
        guard case let .partialResults(organizationIDs)? = header else {
            return header
        }
        guard organizationIDs.contains(organization.githubOrganizationID) else {
            return nil
        }
        return .partialResults([organization.githubOrganizationID])
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
