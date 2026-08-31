import Foundation

enum GitHubIdentityClientError: Error, Equatable, Sendable {
    case invalidOrganizationLogin
    case paginationLoop
    case paginationLimitExceeded
    case notModifiedWithoutCachedState
}

/// A conditional identity response preserves a 304 as transport evidence. The
/// caller that owns an exact scoped, durable normalized record decides whether
/// it can be replayed; a client must never turn a 304 into an empty identity.
enum GitHubIdentityFetch<Value: Sendable>: Sendable {
    case modified(GitHubResponse<Value>)
    case notModified(ssoHeader: GitHubSSOHeader?)
}

enum GitHubOrganizationPageFetch: Sendable {
    case modified(GitHubPage<GitHubOrganizationDTO>)
    case notModified(ssoHeader: GitHubSSOHeader?)
}

enum GitHubOrganizationInventoryFetch: Sendable {
    case modified(GitHubOrganizationInventory)
    case notModified(ssoHeader: GitHubSSOHeader?)
}

struct GitHubOrganizationInventory: Sendable {
    let organizations: [GitHubOrganizationDTO]
    let ssoHeaders: [GitHubSSOHeader]

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }

    var partialResultsSSOHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders.map { header in
            guard case .partialResults = header else { return nil }
            return header
        })
    }
}

struct GitHubRepositoryInventory: Sendable {
    let repositories: [GitHubRepositoryDTO]
    let ssoHeaders: [GitHubSSOHeader]

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }
}

actor GitHubIdentityClient {
    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
    }

    func authenticatedUser() async throws -> GitHubResponse<GitHubUserDTO> {
        let result = try await fetchAuthenticatedUser(validators: nil)
        guard case let .modified(response) = result else {
            throw GitHubIdentityClientError.notModifiedWithoutCachedState
        }
        return response
    }

    func fetchAuthenticatedUser(
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubIdentityFetch<GitHubUserDTO> {
        try await conditionalResponse(
            GitHubUserDTO.self,
            request: try GitHubRESTRequest(path: "/user", validators: validators)
        )
    }

    func organizations() async throws -> GitHubPage<GitHubOrganizationDTO> {
        let result = try await fetchOrganizations(validators: nil)
        guard case let .modified(page) = result else {
            throw GitHubIdentityClientError.notModifiedWithoutCachedState
        }
        return page
    }

    func fetchOrganizations(
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubOrganizationPageFetch {
        do {
            return .modified(try await client.getPage(
            GitHubOrganizationDTO.self,
            request: try GitHubRESTRequest(
                path: "/user/orgs",
                query: [URLQueryItem(name: "per_page", value: "100")],
                validators: validators
            )
            ))
        } catch let failure as GitHubFailure where failure.statusCode == 304 {
            return .notModified(ssoHeader: failure.ssoHeader)
        }
    }

    func allOrganizations() async throws -> GitHubOrganizationInventory {
        let result = try await fetchAllOrganizations(validators: nil)
        guard case let .modified(inventory) = result else {
            throw GitHubIdentityClientError.notModifiedWithoutCachedState
        }
        return inventory
    }

    func fetchAllOrganizations(
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubOrganizationInventoryFetch {
        let initial = try await fetchOrganizations(validators: validators)
        let initialPage: GitHubPage<GitHubOrganizationDTO>
        switch initial {
        case let .modified(page):
            initialPage = page
        case let .notModified(ssoHeader):
            return .notModified(ssoHeader: ssoHeader)
        }
        var page = initialPage
        var organizations: [GitHubOrganizationDTO] = []
        var organizationIDs = Set<UInt64>()
        var ssoHeaders = [page.ssoHeader].compactMap { $0 }
        var visitedPageURLs = Set<String>()
        var pageCount = 1

        func append(_ values: [GitHubOrganizationDTO]) {
            for organization in values where organizationIDs.insert(organization.id).inserted {
                organizations.append(organization)
            }
        }
        append(page.values)

        while let nextPageURL = page.nextPageURL {
            try Task.checkCancellation()
            guard visitedPageURLs.insert(nextPageURL.absoluteString).inserted else {
                throw GitHubIdentityClientError.paginationLoop
            }
            guard pageCount < 100 else {
                throw GitHubIdentityClientError.paginationLimitExceeded
            }

            page = try await client.getPage(
                GitHubOrganizationDTO.self,
                request: try GitHubRESTRequest(nextPageURL: nextPageURL)
            )
            pageCount += 1
            append(page.values)
            if let ssoHeader = page.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
        }

        return .modified(GitHubOrganizationInventory(
            organizations: organizations,
            ssoHeaders: ssoHeaders
        ))
    }

    func organization(named login: String) async throws -> GitHubResponse<GitHubOrganizationDTO> {
        let result = try await fetchOrganization(named: login, validators: nil)
        guard case let .modified(response) = result else {
            throw GitHubIdentityClientError.notModifiedWithoutCachedState
        }
        return response
    }

    func fetchOrganization(
        named login: String,
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubIdentityFetch<GitHubOrganizationDTO> {
        try validateOrganizationLogin(login)
        return try await conditionalResponse(
            GitHubOrganizationDTO.self,
            request: try GitHubRESTRequest(path: "/orgs/\(login)", validators: validators)
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

    func allRepositories(in organization: String) async throws -> GitHubRepositoryInventory {
        var page = try await repositories(in: organization)
        var repositories = page.values
        var ssoHeaders = [page.ssoHeader].compactMap { $0 }
        while let nextPageURL = page.nextPageURL {
            try Task.checkCancellation()
            page = try await client.getPage(
                GitHubRepositoryDTO.self,
                request: GitHubRESTRequest(nextPageURL: nextPageURL)
            )
            repositories.append(contentsOf: page.values)
            if let ssoHeader = page.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
        }
        return GitHubRepositoryInventory(
            repositories: repositories,
            ssoHeaders: ssoHeaders
        )
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

    private func conditionalResponse<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: GitHubRESTRequest
    ) async throws -> GitHubIdentityFetch<Value> {
        do {
            return .modified(try await client.getResponse(type, request: request))
        } catch let failure as GitHubFailure where failure.statusCode == 304 {
            return .notModified(ssoHeader: failure.ssoHeader)
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
    let hasDiscussions: Bool?
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
        case hasDiscussions = "has_discussions"
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case owner
    }
}
