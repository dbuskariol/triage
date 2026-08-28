import Foundation

enum GitHubRepositoryPathError: Error, Equatable, Sendable {
    case invalidOwner
    case invalidRepository
    case invalidPullRequestNumber
}

enum GitHubPullRequestClientError: Error, Equatable, Sendable {
    case paginationLoop
    case paginationLimitExceeded
}

struct GitHubRepositoryPath: Sendable {
    let owner: String
    let repository: String

    init(owner: String, repository: String) throws {
        guard Self.isPathComponent(owner) else { throw GitHubRepositoryPathError.invalidOwner }
        guard Self.isPathComponent(repository) else { throw GitHubRepositoryPathError.invalidRepository }
        self.owner = owner
        self.repository = repository
    }

    var path: String { "/repos/\(owner)/\(repository)" }

    private static func isPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || "-._".unicodeScalars.contains($0))
            }
    }
}

struct GitHubPullRequestReviewDTO: Codable, Sendable {
    let id: UInt64
    let nodeID: String
    let state: String
    let body: String?
    let submittedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case state, body
        case submittedAt = "submitted_at"
    }
}

struct GitHubRequestedReviewersDTO: Codable, Sendable {
    let users: [Reviewer]
    let teams: [Reviewer]

    struct Reviewer: Codable, Sendable {
        let nodeID: String
        let login: String?
        let slug: String?

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case login, slug
        }
    }
}

struct GitHubPullRequestReviewInventory: Sendable {
    let reviews: [GitHubPullRequestReviewDTO]
    let pages: [GitHubPage<GitHubPullRequestReviewDTO>]
    let ssoHeaders: [GitHubSSOHeader]

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }
}

actor GitHubPullRequestClient {
    private static let maximumReviewPages = 100

    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
    }

    func reviews(
        repository: GitHubRepositoryPath,
        number: Int
    ) async throws -> GitHubPage<GitHubPullRequestReviewDTO> {
        guard number > 0 else { throw GitHubRepositoryPathError.invalidPullRequestNumber }
        return try await client.getPage(
            GitHubPullRequestReviewDTO.self,
            request: GitHubRESTRequest(
                path: "\(repository.path)/pulls/\(number)/reviews",
                query: [URLQueryItem(name: "per_page", value: "100")]
            )
        )
    }

    func allReviews(
        repository: GitHubRepositoryPath,
        number: Int
    ) async throws -> GitHubPullRequestReviewInventory {
        var page = try await reviews(repository: repository, number: number)
        var reviews: [GitHubPullRequestReviewDTO] = []
        var pages = [page]
        var reviewNodeIDs = Set<String>()
        var ssoHeaders = [page.ssoHeader].compactMap { $0 }
        var visitedPageURLs = Set<String>()
        var pageCount = 1

        func append(_ values: [GitHubPullRequestReviewDTO]) {
            for review in values where reviewNodeIDs.insert(review.nodeID).inserted {
                reviews.append(review)
            }
        }
        append(page.values)

        while let nextPageURL = page.nextPageURL {
            try Task.checkCancellation()
            guard visitedPageURLs.insert(nextPageURL.absoluteString).inserted else {
                throw GitHubPullRequestClientError.paginationLoop
            }
            guard pageCount < Self.maximumReviewPages else {
                throw GitHubPullRequestClientError.paginationLimitExceeded
            }
            page = try await client.getPage(
                GitHubPullRequestReviewDTO.self,
                request: GitHubRESTRequest(nextPageURL: nextPageURL)
            )
            pageCount += 1
            pages.append(page)
            append(page.values)
            if let ssoHeader = page.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
        }

        return GitHubPullRequestReviewInventory(
            reviews: reviews,
            pages: pages,
            ssoHeaders: ssoHeaders
        )
    }

    func requestedReviewers(
        repository: GitHubRepositoryPath,
        number: Int
    ) async throws -> GitHubResponse<GitHubRequestedReviewersDTO> {
        guard number > 0 else { throw GitHubRepositoryPathError.invalidPullRequestNumber }
        return try await client.getResponse(
            GitHubRequestedReviewersDTO.self,
            request: GitHubRESTRequest(
                path: "\(repository.path)/pulls/\(number)/requested_reviewers"
            )
        )
    }
}
