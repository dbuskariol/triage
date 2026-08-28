import Foundation

struct GitHubTimelineEventDTO: Codable, Sendable {
    let id: String?
    let event: String?
    let createdAt: Date?
    let actor: Actor?

    struct Actor: Codable, Sendable {
        let nodeID: String?
        let login: String?

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case login
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, event, actor
        case createdAt = "created_at"
    }
}

actor GitHubTimelineClient {
    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
    }

    func timeline(
        repository: GitHubRepositoryPath,
        issueOrPullRequestNumber: Int,
        page: Int = 1
    ) async throws -> GitHubPage<GitHubTimelineEventDTO> {
        guard issueOrPullRequestNumber > 0 else {
            throw GitHubRepositoryPathError.invalidPullRequestNumber
        }
        return try await client.getPage(
            GitHubTimelineEventDTO.self,
            request: GitHubRESTRequest(
                path: "\(repository.path)/issues/\(issueOrPullRequestNumber)/timeline",
                query: [
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(max(page, 1)))
                ]
            )
        )
    }
}
