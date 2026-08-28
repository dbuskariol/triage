import Foundation

enum GitHubSearchNormalizationError: Error, Equatable, Sendable {
    case invalidNodeID
    case unknownState(String)
}

enum GitHubSearchNormalizer {
    static func normalize(
        _ item: GitHubIssueSearchItem,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: RepositoryID?,
        observedAt: Date
    ) throws -> NormalizedGitHubNode {
        guard let nodeID = GitHubNodeID(rawValue: item.nodeID) else {
            throw GitHubSearchNormalizationError.invalidNodeID
        }
        let state: GitHubItemState
        switch item.state.lowercased() {
        case "open": state = .open
        case "closed": state = .closed
        default: throw GitHubSearchNormalizationError.unknownState(item.state)
        }
        return NormalizedGitHubNode(
            nodeID: nodeID,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            kind: item.pullRequest == nil ? .issue : .pullRequest,
            numericID: String(item.id),
            number: item.number,
            title: item.title,
            state: state,
            url: item.htmlURL,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            closedAt: item.closedAt,
            mergedAt: nil,
            sourceRevision: item.updatedAt.ISO8601Format(),
            observedAt: observedAt,
            accessibility: .accessible
        )
    }
}
