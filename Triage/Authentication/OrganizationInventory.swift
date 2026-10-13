import Foundation

/// Turns the organizations GitHub lists for a credential into stored
/// organizations and their access, for connecting and replacing credentials.
enum OrganizationInventory {
    static func organization(from dto: GitHubOrganizationDTO) throws -> GitHubOrganization {
        guard let nodeID = GitHubNodeID(rawValue: dto.nodeID),
              let organizationID = OrganizationID(rawValue: dto.nodeID)
        else {
            throw AccountConnectionError.invalidGitHubIdentity
        }
        return GitHubOrganization(
            id: organizationID,
            githubOrganizationID: dto.id,
            nodeID: nodeID,
            login: dto.login,
            avatarURL: dto.avatarURL
        )
    }

    static func access(
        accountID: AccountID,
        organizationID: OrganizationID,
        state: OrganizationAccessState,
        at date: Date
    ) -> OrganizationAccess {
        OrganizationAccess(
            accountID: accountID,
            organizationID: organizationID,
            state: state,
            capabilityRevision: CapabilityRevision(rawValue: UUID().uuidString.lowercased())!,
            capabilities: GitHubCapability.allCases
                .filter { $0.scope == .organization }
                .map { CapabilityAvailability(capability: $0, status: .unknown, checkedAt: date) },
            checkedAt: date
        )
    }
}
