import Foundation

enum GitHubDiscussionClientError: Error, Equatable, Sendable {
    case paginationLoop([GitHubDiscussionRawPage])
    case paginationLimitExceeded([GitHubDiscussionRawPage])
    case queryCostExceeded([GitHubDiscussionRawPage])
    case missingRequestedRepository([GitHubDiscussionRawPage])
    case incompleteConnection([GitHubDiscussionRawPage])
    case missingData([GitHubDiscussionRawPage])
    case undecodableResponse([GitHubDiscussionRawPage])
    case partialResponse([GitHubDiscussionRawPage])
    case ssoResponse([GitHubDiscussionRawPage], GitHubSSOHeader)
    case normalizationFailed([GitHubDiscussionRawPage])
    case aggregateLimitExceeded([GitHubDiscussionRawPage])
}

struct GitHubDiscussionRawPage: Equatable, Sendable {
    let endpoint: String
    /// Canonical operation and variables for the exact GraphQL request which
    /// produced this page. It is deliberately distinct from the local page
    /// storage endpoint so raw evidence cannot be reused across cursors.
    let requestKey: String
    let payload: Data

    init(endpoint: String, requestKey: String? = nil, payload: Data) {
        self.endpoint = endpoint
        self.requestKey = requestKey ?? endpoint
        self.payload = payload
    }
}

struct GitHubDiscussionInventory: Sendable {
    let discussions: [GitHubDiscussionRecord]
    let rawPages: [GitHubDiscussionRawPage]
    let pageCount: Int
}

actor GitHubDiscussionClient {
    private static let maximumPages = 100
    private static let maximumQueryCost = 500
    private let client: GitHubGraphQLClient

    init(client: GitHubGraphQLClient) {
        self.client = client
    }

    func allDiscussions(
        repositoryNodeID: GitHubNodeID,
        githubOrganizationID: UInt64,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> GitHubDiscussionInventory {
        try Task.checkCancellation()
        try await validateScope()
        let query = try GitHubGraphQLQueries.repositoryDiscussions()
        var after: String?
        var cursors = Set<String>()
        var pages = [GitHubDiscussionRawPage]()
        var collected = [GitHubDiscussionPayload.Discussion]()
        var totalCost = 0
        var totalBytes = 0

        while true {
            try await validateScope()
            guard pages.count < Self.maximumPages else {
                throw GitHubDiscussionClientError.paginationLimitExceeded(pages)
            }
            let decodingResult = try await client.executePreservingUndecodableResponse(
                query,
                variables: CursorVariables(repositoryID: repositoryNodeID.rawValue, after: after),
                as: GitHubDiscussionPayload.self
            )
            try Task.checkCancellation()
            try await validateScope()
            let response: GitHubGraphQLResponse<GitHubDiscussionPayload>
            switch decodingResult {
            case let .response(decoded):
                response = decoded
            case let .undecodable(undecodable):
                let rawPage = GitHubDiscussionRawPage(
                    endpoint: "graphql:TriageRepositoryDiscussions/repository=\(repositoryNodeID.rawValue)/page=\(pages.count + 1)",
                    requestKey: Self.requestKey(repositoryNodeID: repositoryNodeID, after: after),
                    payload: undecodable.payload
                )
                if let header = undecodable.metadata.ssoHeader?.scoped(to: githubOrganizationID) {
                    throw GitHubDiscussionClientError.ssoResponse(pages + [rawPage], header)
                }
                throw GitHubDiscussionClientError.undecodableResponse(pages + [rawPage])
            }
            let rawPage = GitHubDiscussionRawPage(
                endpoint: "graphql:TriageRepositoryDiscussions/repository=\(repositoryNodeID.rawValue)/page=\(pages.count + 1)",
                requestKey: Self.requestKey(repositoryNodeID: repositoryNodeID, after: after),
                payload: response.payload
            )
            if let header = response.metadata.ssoHeader?.scoped(to: githubOrganizationID) {
                throw GitHubDiscussionClientError.ssoResponse(pages + [rawPage], header)
            }
            guard response.errors.isEmpty else {
                throw GitHubDiscussionClientError.partialResponse(pages + [rawPage])
            }
            guard let payload = response.data else {
                throw GitHubDiscussionClientError.missingData(pages + [rawPage])
            }
            guard payload.rateLimit.cost >= 0, payload.rateLimit.cost <= Self.maximumQueryCost else {
                throw GitHubDiscussionClientError.queryCostExceeded(pages + [rawPage])
            }
            guard totalCost <= Self.maximumQueryCost - payload.rateLimit.cost,
                  totalBytes <= Self.maximumPayloadBytes - rawPage.payload.count
            else {
                throw GitHubDiscussionClientError.aggregateLimitExceeded(pages + [rawPage])
            }
            totalCost += payload.rateLimit.cost
            totalBytes += rawPage.payload.count
            pages.append(rawPage)
            guard let repository = payload.node, repository.id == repositoryNodeID.rawValue else {
                throw GitHubDiscussionClientError.missingRequestedRepository(pages)
            }
            guard !repository.discussions.nodes.contains(where: { $0 == nil }) else {
                throw GitHubDiscussionClientError.incompleteConnection(pages)
            }
            collected.append(contentsOf: repository.discussions.nodes.compactMap { $0 })
            guard repository.discussions.pageInfo.hasNextPage else { break }
            guard let cursor = repository.discussions.pageInfo.endCursor,
                  cursors.insert(cursor).inserted
            else {
                throw GitHubDiscussionClientError.paginationLoop(pages)
            }
            after = cursor
        }
        do {
            return GitHubDiscussionInventory(
                discussions: try GitHubDiscussionNormalizer.normalize(collected),
                rawPages: pages,
                pageCount: pages.count
            )
        } catch {
            throw GitHubDiscussionClientError.normalizationFailed(pages)
        }
    }

    private struct CursorVariables: Encodable, Sendable {
        let repositoryID: String
        let after: String?
    }

    private nonisolated static func requestKey(repositoryNodeID: GitHubNodeID, after: String?) -> String {
        "graphql:TriageRepositoryDiscussions/repository=\(repositoryNodeID.rawValue)/after=\(cursorComponent(after))"
    }

    private nonisolated static func cursorComponent(_ cursor: String?) -> String {
        guard let cursor else { return "none" }
        return Data(cursor.utf8).base64EncodedString()
    }

    private static let maximumPayloadBytes = 4 * 1_024 * 1_024
}
