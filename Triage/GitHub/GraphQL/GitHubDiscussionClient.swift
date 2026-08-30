import Foundation

enum GitHubDiscussionClientError: Error, Equatable, Sendable {
    case paginationLoop
    case paginationLimitExceeded
    case queryCostExceeded
    case missingRequestedRepository
    case incompleteConnection
    case partialResponse(GitHubDiscussionRawPage)
    case normalizationFailed([GitHubDiscussionRawPage])
    case aggregateLimitExceeded([GitHubDiscussionRawPage])
}

struct GitHubDiscussionRawPage: Equatable, Sendable {
    let endpoint: String
    let payload: Data
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
        repositoryNodeID: GitHubNodeID
    ) async throws -> GitHubDiscussionInventory {
        let query = try GitHubGraphQLQueries.repositoryDiscussions()
        var after: String?
        var cursors = Set<String>()
        var pages = [GitHubDiscussionRawPage]()
        var collected = [GitHubDiscussionPayload.Discussion]()
        var totalCost = 0
        var totalBytes = 0

        while true {
            guard pages.count < Self.maximumPages else {
                throw GitHubDiscussionClientError.paginationLimitExceeded
            }
            let response = try await client.execute(
                query,
                variables: CursorVariables(repositoryID: repositoryNodeID.rawValue, after: after),
                as: GitHubDiscussionPayload.self
            )
            let rawPage = GitHubDiscussionRawPage(
                endpoint: "graphql:TriageRepositoryDiscussions/repository=\(repositoryNodeID.rawValue)/page=\(pages.count + 1)",
                payload: response.payload
            )
            guard response.errors.isEmpty else {
                throw GitHubDiscussionClientError.partialResponse(rawPage)
            }
            guard let payload = response.data else { throw GitHubGraphQLError.missingData }
            guard payload.rateLimit.cost >= 0, payload.rateLimit.cost <= Self.maximumQueryCost else {
                throw GitHubDiscussionClientError.queryCostExceeded
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
                throw GitHubDiscussionClientError.missingRequestedRepository
            }
            guard !repository.discussions.nodes.contains(where: { $0 == nil }) else {
                throw GitHubDiscussionClientError.incompleteConnection
            }
            collected.append(contentsOf: repository.discussions.nodes.compactMap { $0 })
            guard repository.discussions.pageInfo.hasNextPage else { break }
            guard let cursor = repository.discussions.pageInfo.endCursor,
                  cursors.insert(cursor).inserted
            else {
                throw GitHubDiscussionClientError.paginationLoop
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

    private static let maximumPayloadBytes = 4 * 1_024 * 1_024
}
