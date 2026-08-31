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
    case invalidIssueDetails
    case invalidRelatedNodeID
    case duplicateRelatedNodeID
    case incompleteConnection
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
        let locked: Bool?
        let comments: CommentConnection?
        let mergeable: String?
        let headRefName: String?
        let headRefOid: String? = nil
        let baseRefName: String?
        let reviewDecision: String?
        let author: Actor?
        let repository: Repository
        let assignees: Connection<Actor>
        let labels: Connection<Label>
        let reviewRequests: Connection<ReviewRequest>?
        let closingIssuesReferences: Connection<NodeReference>?

        enum CodingKeys: String, CodingKey {
            case typeName = "__typename"
            case id, databaseId, number, title, body, url, state, createdAt, updatedAt, closedAt, mergedAt, isDraft
            case locked, comments, mergeable, headRefName, headRefOid, baseRefName, reviewDecision
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

    struct CommentConnection: Codable, Sendable {
        let totalCount: Int
    }

    struct ReviewRequest: Codable, Sendable {
        let requestedReviewer: RequestedReviewer?
    }

    struct RequestedReviewer: Codable, Sendable {
        let id: String?
        let login: String?
        let slug: String?
        let avatarUrl: URL?
    }
    struct NodeReference: Codable, Sendable {
        let id: String
    }

    struct Connection<Value: Codable & Sendable>: Codable, Sendable {
        let nodes: [Value?]
        let pageInfo: PageInfo
    }

    struct PageInfo: Codable, Sendable {
        let hasNextPage: Bool
    }
}

struct HydratedGitHubNode: Sendable {
    let node: NormalizedGitHubNode
    let details: GitHubNodeDetails
}

enum GitHubNodeDetails: Sendable {
    case issue(
        isLocked: Bool,
        commentsCount: Int,
        assigneeNodeIDs: [GitHubNodeID],
        labelNodeIDs: [GitHubNodeID],
        labelNames: [String]
    )
    case pullRequest(
        isDraft: Bool,
        mergeableState: String?,
        headRef: String?,
        baseRef: String?,
        reviewDecision: String?,
        assigneeNodeIDs: [GitHubNodeID],
        labelNodeIDs: [GitHubNodeID],
        labelNames: [String]
    )
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
        try normalizeHydrated(
            payload,
            requestedNodeIDs: requestedNodeIDs,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            observedAt: observedAt
        ).map(\.node)
    }

    static func normalizeHydrated(
        _ payload: GitHubNodeHydrationPayload,
        requestedNodeIDs: Set<GitHubNodeID>,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: (GitHubNodeHydrationPayload.Repository) -> RepositoryID?,
        observedAt: Date
    ) throws -> [HydratedGitHubNode] {
        var normalizedByID = [GitHubNodeID: HydratedGitHubNode]()

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

            let node = try normalize(
                payloadNode,
                nodeID: nodeID,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: resolvedRepositoryID,
                observedAt: observedAt
            )
            normalizedByID[nodeID] = HydratedGitHubNode(
                node: node,
                details: try details(from: payloadNode, kind: node.kind)
            )
        }

        guard normalizedByID.count == requestedNodeIDs.count else {
            let missing = requestedNodeIDs.first { normalizedByID[$0] == nil }!
            throw GitHubNodeHydrationNormalizationError.missingRequestedNode(missing.rawValue)
        }
        return normalizedByID.values.sorted { $0.node.nodeID.rawValue < $1.node.nodeID.rawValue }
    }

    private static func details(
        from node: GitHubNodeHydrationPayload.Node,
        kind: GitHubContentKind
    ) throws -> GitHubNodeDetails {
        switch kind {
        case .issue:
            guard let locked = node.locked, let comments = node.comments, comments.totalCount >= 0 else {
                throw GitHubNodeHydrationNormalizationError.invalidIssueDetails
            }
            let assigneeNodeIDs = try validatedAssigneeNodeIDs(node.assignees)
            let labelNodeIDs = try validatedLabelNodeIDs(node.labels)
            return .issue(
                isLocked: locked,
                commentsCount: comments.totalCount,
                assigneeNodeIDs: assigneeNodeIDs,
                labelNodeIDs: labelNodeIDs,
                labelNames: node.labels.nodes.compactMap(\.?).map(\.name).sorted()
            )
        case .pullRequest:
            guard let isDraft = node.isDraft else {
                throw GitHubNodeHydrationNormalizationError.invalidIssueDetails
            }
            let assigneeNodeIDs = try validatedAssigneeNodeIDs(node.assignees)
            let labelNodeIDs = try validatedLabelNodeIDs(node.labels)
            try validateReviewRequests(node.reviewRequests)
            try validateClosingReferences(node.closingIssuesReferences)
            return .pullRequest(
                isDraft: isDraft,
                mergeableState: node.mergeable,
                headRef: node.headRefName,
                baseRef: node.baseRefName,
                reviewDecision: node.reviewDecision,
                assigneeNodeIDs: assigneeNodeIDs,
                labelNodeIDs: labelNodeIDs,
                labelNames: node.labels.nodes.compactMap(\.?).map(\.name).sorted()
            )
        default:
            preconditionFailure("Hydration only supports issue and pull request nodes.")
        }

    }

    private static func validatedAssigneeNodeIDs(
        _ connection: GitHubNodeHydrationPayload.Connection<GitHubNodeHydrationPayload.Actor>
    ) throws -> [GitHubNodeID] {
        let nodeIDs = try validatedConnection(connection, identifier: validNodeID)
        return nodeIDs
    }

    private static func validatedLabelNodeIDs(
        _ connection: GitHubNodeHydrationPayload.Connection<GitHubNodeHydrationPayload.Label>
    ) throws -> [GitHubNodeID] {
        try validatedConnection(connection, identifier: validNodeID)
    }

    private static func validateReviewRequests(
        _ connection: GitHubNodeHydrationPayload.Connection<GitHubNodeHydrationPayload.ReviewRequest>?
    ) throws {
        guard let connection else { return }
        _ = try validatedConnection(connection) { request in
            guard let id = request.requestedReviewer?.id,
                  let nodeID = GitHubNodeID(rawValue: id)
            else { throw GitHubNodeHydrationNormalizationError.invalidRelatedNodeID }
            return nodeID
        }
    }

    private static func validateClosingReferences(
        _ connection: GitHubNodeHydrationPayload.Connection<GitHubNodeHydrationPayload.NodeReference>?
    ) throws {
        guard let connection else { return }
        _ = try validatedConnection(connection) { reference in
            guard let nodeID = GitHubNodeID(rawValue: reference.id) else {
                throw GitHubNodeHydrationNormalizationError.invalidRelatedNodeID
            }
            return nodeID
        }
    }

    private static func validatedConnection<Value>(
        _ connection: GitHubNodeHydrationPayload.Connection<Value>,
        identifier: (Value) throws -> GitHubNodeID
    ) throws -> [GitHubNodeID] where Value: Codable & Sendable {
        guard !connection.pageInfo.hasNextPage,
              connection.nodes.count <= 50,
              !connection.nodes.contains(where: { $0 == nil })
        else { throw GitHubNodeHydrationNormalizationError.incompleteConnection }
        let identifiers = try connection.nodes.map { node -> GitHubNodeID in
            guard let node else { throw GitHubNodeHydrationNormalizationError.incompleteConnection }
            return try identifier(node)
        }
        guard Set(identifiers).count == identifiers.count else {
            throw GitHubNodeHydrationNormalizationError.duplicateRelatedNodeID
        }
        return identifiers
    }

    private static func validNodeID(_ value: GitHubNodeHydrationPayload.Actor) throws -> GitHubNodeID {
        guard let nodeID = GitHubNodeID(rawValue: value.id) else {
            throw GitHubNodeHydrationNormalizationError.invalidRelatedNodeID
        }
        return nodeID
    }

    private static func validNodeID(_ value: GitHubNodeHydrationPayload.Label) throws -> GitHubNodeID {
        guard let nodeID = GitHubNodeID(rawValue: value.id) else {
            throw GitHubNodeHydrationNormalizationError.invalidRelatedNodeID
        }
        return nodeID
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
            pullRequestHeadCommitSHA: kind == .pullRequest ? validCommitSHA(node.headRefOid) : nil,
            observedAt: observedAt,
            accessibility: .accessible
        )
    }

    private static func validCommitSHA(_ value: String?) -> String? {
        guard let value, value.count == 64,
              value.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.numericType != nil || (97...102).contains($0.value)) })
        else { return nil }
        return value
    }
}
