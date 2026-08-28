import Foundation

enum GitHubRepositoryPathError: Error, Equatable, Sendable {
    case invalidOwner
    case invalidRepository
    case invalidPullRequestNumber
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

actor GitHubPullRequestClient {
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
}
