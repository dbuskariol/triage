import Foundation

enum GitHubNodeHydrationNormalizationError: Error, Equatable, Sendable {
    case missingRequestedNode(String)
    case duplicateNode(String)
    case unsupportedNodeType(String)
    case invalidNodeID
    case invalidRepositoryID
    case invalidNumber
    case invalidTitle
    case invalidURL
    case invalidState(String)
    case invalidDates
}

struct GitHubNodeHydrationPayload: Codable, Sendable {
    let nodes: [Node?]
    let rateLimit: RateLimit

    struct RateLimit: Codable, Sendable {
        let cost: Int
        let remaining: Int
        let resetAt: Date
    }

    struct Node: Codable, Sendable {
        let typeName: String
        let id: String
        let databaseId: Int?
        let number: Int
        let title: String
        let body: String?
        let url: URL
        let state: String
        let createdAt: Date
        let updatedAt: Date
        let closedAt: Date?
        let mergedAt: Date?
        let isDraft: Bool?
        let author: Actor?
        let repository: Repository
        let assignees: Connection<Actor>?
        let labels: Connection<Label>?
        let reviewRequests: Connection<ReviewRequest>?
        let closingIssuesReferences: Connection<NodeReference>?

        enum CodingKeys: String, CodingKey {
            case typeName = "__typename"
            case id, databaseId, number, title, body, url, state, createdAt, updatedAt, closedAt, mergedAt, isDraft
            case author, repository, assignees, labels, reviewRequests, closingIssuesReferences
        }
    }

    struct Actor: Codable, Sendable {
        let id: String
        let login: String?
        let avatarUrl: URL?
    }

    struct Repository: Codable, Sendable {
        let id: String
        let nameWithOwner: String
        let isPrivate: Bool
        let isArchived: Bool
        let hasDiscussions: Bool
        let url: URL
    }

    struct Label: Codable, Sendable {
        let id: String
        let name: String
        let color: String
    }

    struct ReviewRequest: Codable, Sendable {
        let requestedReviewer: RequestedReviewer?
    }

    struct RequestedReviewer: Codable, Sendable {
        let id: String?
        let login: String?
        let avatarUrl: URL?
    }
    struct NodeReference: Codable, Sendable {
        let id: String
    }

    struct Connection<Value: Codable & Sendable>: Codable, Sendable {
        let nodes: [Value?]
    }
}

enum GitHubNodeHydrationNormalizer {
    static func normalize(
        _ payload: GitHubNodeHydrationPayload,
        requestedNodeIDs: Set<GitHubNodeID>,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: (GitHubNodeHydrationPayload.Repository) -> RepositoryID?,
        observedAt: Date
    ) throws -> [NormalizedGitHubNode] {
        var normalizedByID = [GitHubNodeID: NormalizedGitHubNode]()

        for payloadNode in payload.nodes {
            guard let payloadNode else { continue }
            guard let nodeID = GitHubNodeID(rawValue: payloadNode.id) else {
                throw GitHubNodeHydrationNormalizationError.invalidNodeID
            }
            guard requestedNodeIDs.contains(nodeID) else {
                throw GitHubNodeHydrationNormalizationError.missingRequestedNode(payloadNode.id)
            }
            guard normalizedByID[nodeID] == nil else {
                throw GitHubNodeHydrationNormalizationError.duplicateNode(payloadNode.id)
            }
            guard let resolvedRepositoryID = repositoryID(payloadNode.repository) else {
                throw GitHubNodeHydrationNormalizationError.invalidRepositoryID
            }

            normalizedByID[nodeID] = try normalize(
                payloadNode,
                nodeID: nodeID,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: resolvedRepositoryID,
                observedAt: observedAt
            )
        }

        guard normalizedByID.count == requestedNodeIDs.count else {
            let missing = requestedNodeIDs.first { normalizedByID[$0] == nil }!
            throw GitHubNodeHydrationNormalizationError.missingRequestedNode(missing.rawValue)
        }
        return normalizedByID.values.sorted { $0.nodeID.rawValue < $1.nodeID.rawValue }
    }

    private static func normalize(
        _ node: GitHubNodeHydrationPayload.Node,
        nodeID: GitHubNodeID,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: RepositoryID,
        observedAt: Date
    ) throws -> NormalizedGitHubNode {
        guard node.number > 0 else { throw GitHubNodeHydrationNormalizationError.invalidNumber }
        guard !node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubNodeHydrationNormalizationError.invalidTitle
        }
        guard node.url.scheme == "https", node.url.host == "github.com" else {
            throw GitHubNodeHydrationNormalizationError.invalidURL
        }
        guard node.createdAt <= node.updatedAt,
              node.closedAt.map({ $0 >= node.createdAt }) ?? true,
              node.mergedAt.map({ $0 >= node.createdAt }) ?? true
        else {
            throw GitHubNodeHydrationNormalizationError.invalidDates
        }

        let kind: GitHubContentKind
        let state: GitHubItemState
        switch node.typeName {
        case "Issue":
            kind = .issue
            switch node.state.uppercased() {
            case "OPEN": state = .open
            case "CLOSED": state = .closed
            default: throw GitHubNodeHydrationNormalizationError.invalidState(node.state)
            }
        case "PullRequest":
            kind = .pullRequest
            switch node.state.uppercased() {
            case "OPEN": state = node.isDraft == true ? .draft : .open
            case "CLOSED": state = node.mergedAt == nil ? .closed : .merged
            case "MERGED": state = .merged
            default: throw GitHubNodeHydrationNormalizationError.invalidState(node.state)
            }
        default:
            throw GitHubNodeHydrationNormalizationError.unsupportedNodeType(node.typeName)
        }

        return NormalizedGitHubNode(
            nodeID: nodeID,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            kind: kind,
            numericID: node.databaseId.map(String.init),
            number: node.number,
            title: node.title,
            state: state,
            url: node.url,
            bodyMarkdown: node.body,
            authorID: node.author.flatMap { ActorID(rawValue: $0.id) },
            createdAt: node.createdAt,
            updatedAt: node.updatedAt,
            closedAt: node.closedAt,
            mergedAt: node.mergedAt,
            sourceRevision: node.updatedAt.ISO8601Format(),
            observedAt: observedAt,
            accessibility: .accessible
        )
    }
}
