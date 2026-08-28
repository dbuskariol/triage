import Foundation

enum GitHubIdentityClientError: Error, Equatable, Sendable {
    case invalidOrganizationLogin
}

actor GitHubIdentityClient {
    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
    }

    func authenticatedUser() async throws -> GitHubResponse<GitHubUserDTO> {
        try await client.getResponse(
            GitHubUserDTO.self,
            request: try GitHubRESTRequest(path: "/user")
        )
    }

    func organizations() async throws -> GitHubPage<GitHubOrganizationDTO> {
        try await client.getPage(
            GitHubOrganizationDTO.self,
            request: try GitHubRESTRequest(
                path: "/user/orgs",
                query: [URLQueryItem(name: "per_page", value: "100")]
            )
        )
    }

    func organization(named login: String) async throws -> GitHubResponse<GitHubOrganizationDTO> {
        try validateOrganizationLogin(login)
        return try await client.getResponse(
            GitHubOrganizationDTO.self,
            request: try GitHubRESTRequest(path: "/orgs/\(login)")
        )
    }

    func repositories(in organization: String) async throws -> GitHubPage<GitHubRepositoryDTO> {
        try validateOrganizationLogin(organization)
        return try await client.getPage(
            GitHubRepositoryDTO.self,
            request: try GitHubRESTRequest(
                path: "/orgs/\(organization)/repos",
                query: [
                    URLQueryItem(name: "type", value: "all"),
                    URLQueryItem(name: "per_page", value: "100")
                ]
            )
        )
    }

    func allRepositories(in organization: String) async throws -> [GitHubRepositoryDTO] {
        var page = try await repositories(in: organization)
        var repositories = page.values
        while let nextPageURL = page.nextPageURL {
            page = try await client.getPage(
                GitHubRepositoryDTO.self,
                request: GitHubRESTRequest(nextPageURL: nextPageURL)
            )
            repositories.append(contentsOf: page.values)
        }
        return repositories
    }

    private func validateOrganizationLogin(_ value: String) throws {
        guard !value.isEmpty,
              value.count <= 39,
              value.unicodeScalars.allSatisfy({
                  $0.isASCII
                      && ($0.properties.isAlphabetic
                          || $0.properties.numericType != nil
                          || $0 == "-")
              })
        else {
            throw GitHubIdentityClientError.invalidOrganizationLogin
        }
    }
}

struct GitHubUserDTO: Codable, Equatable, Sendable {
    let id: UInt64
    let nodeID: String
    let login: String
    let name: String?
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case login
        case name
        case avatarURL = "avatar_url"
    }
}

struct GitHubOrganizationDTO: Codable, Equatable, Sendable {
    let id: UInt64
    let nodeID: String
    let login: String
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case login
        case avatarURL = "avatar_url"
    }
}

struct GitHubRepositoryDTO: Codable, Equatable, Sendable {
    let id: UInt64
    let nodeID: String
    let name: String
    let isPrivate: Bool
    let isArchived: Bool
    let htmlURL: URL
    let updatedAt: Date
    let owner: Owner

    struct Owner: Codable, Equatable, Sendable {
        let login: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case name
        case isPrivate = "private"
        case isArchived = "archived"
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case owner
    }
}
