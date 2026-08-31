import Foundation

enum GitHubIdentityClientError: Error, Equatable, Sendable {
    case invalidOrganizationLogin
    case paginationLoop
    case paginationLimitExceeded
    case invalidPaginationLink
    case duplicateOrganization
    case notModifiedWithoutCachedState
    case organizationInventoryResponseTooLarge
    case organizationResponseTooLarge
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
    /// Every decoded page is retained so the post-account receipt owner can
    /// bind its complete traversal to raw page evidence rather than treating a
    /// collapsed list as proof of inventory completeness.
    let pages: [GitHubOrganizationInventoryPage]
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

struct GitHubOrganizationInventoryPage: Sendable {
    let page: GitHubPage<GitHubOrganizationDTO>
    let requestKey: String
    let nextRequestKey: String?
}

struct GitHubRepositoryInventory: Sendable {
    let repositories: [GitHubRepositoryDTO]
    let ssoHeaders: [GitHubSSOHeader]

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }
}

actor GitHubIdentityClient {
    /// `/user/orgs` is a complete-inventory authority only within this decoded
    /// response budget, including all traversed pages.
    private static let maximumOrganizationInventoryResponseBytes = 1 * 1_024 * 1_024
    private static let maximumOrganizationResponseBytes = 256 * 1_024

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
            let page = try await client.getPage(
                GitHubOrganizationDTO.self,
                request: try GitHubRESTRequest(
                    path: "/user/orgs",
                    query: [URLQueryItem(name: "per_page", value: "100")],
                    validators: validators
                )
            )
            guard page.payload.count <= Self.maximumOrganizationInventoryResponseBytes else {
                throw GitHubIdentityClientError.organizationInventoryResponseTooLarge
            }
            return .modified(page)
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
        var totalPayloadBytes = 0
        try Self.consumeOrganizationInventoryPayload(
            initialPage.payload,
            totalPayloadBytes: &totalPayloadBytes
        )
        var page = initialPage
        var currentRequestKey = "GET /user/orgs?per_page=100"
        var organizations: [GitHubOrganizationDTO] = []
        var organizationIDs = Set<UInt64>()
        var organizationNodeIDs = Set<String>()
        var organizationLogins = Set<String>()
        var pages = [GitHubOrganizationInventoryPage(
            page: initialPage,
            requestKey: currentRequestKey,
            nextRequestKey: page.nextPageURL.flatMap(Self.canonicalInventoryRequestKey(for:))
        )]
        var ssoHeaders = [page.ssoHeader].compactMap { $0 }
        var visitedPageURLs = Set<String>()
        var pageCount = 1

        func append(_ values: [GitHubOrganizationDTO]) throws {
            for organization in values {
                guard organizationIDs.insert(organization.id).inserted,
                      organizationNodeIDs.insert(organization.nodeID).inserted,
                      organizationLogins.insert(organization.login.lowercased()).inserted
                else {
                    throw GitHubIdentityClientError.duplicateOrganization
                }
                organizations.append(organization)
            }
        }
        try append(page.values)

        while let nextPageURL = page.nextPageURL {
            try Task.checkCancellation()
            try Self.validatePaginationLink(
                nextPageURL,
                rawLinkHeader: page.linkHeader,
                currentPage: pageCount
            )
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
            try Self.consumeOrganizationInventoryPayload(
                page.payload,
                totalPayloadBytes: &totalPayloadBytes
            )
            pageCount += 1
            currentRequestKey = Self.canonicalInventoryRequestKey(for: nextPageURL) ?? "GET /invalid-user-orgs-page"
            try append(page.values)
            pages.append(GitHubOrganizationInventoryPage(
                page: page,
                requestKey: currentRequestKey,
                nextRequestKey: page.nextPageURL.flatMap(Self.canonicalInventoryRequestKey(for:))
            ))
            if let ssoHeader = page.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
        }
        try Self.validateTerminalLinkHeader(page.nextPageURL, rawLinkHeader: page.linkHeader)

        return .modified(GitHubOrganizationInventory(
            organizations: organizations,
            pages: pages,
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
        do {
            let response = try await client.getResponse(
                GitHubOrganizationDTO.self,
                request: try GitHubRESTRequest(path: "/orgs/\(login)", validators: validators)
            )
            guard response.payload.count <= Self.maximumOrganizationResponseBytes else {
                throw GitHubIdentityClientError.organizationResponseTooLarge
            }
            return .modified(response)
        } catch let failure as GitHubFailure where failure.statusCode == 304 {
            return .notModified(ssoHeader: failure.ssoHeader)
        }
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

    private nonisolated static func validateTerminalLinkHeader(
        _ nextURL: URL?, rawLinkHeader: String?
    ) throws {
        guard let rawLinkHeader,
              !rawLinkHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        guard let parsed = GitHubLinkHeader(rawLinkHeader),
              parsed.isWellFormed,
              parsed.nextPageURL == nextURL
        else {
            throw GitHubIdentityClientError.invalidPaginationLink
        }
    }

    private nonisolated static func validatePaginationLink(
        _ url: URL,
        rawLinkHeader: String?,
        currentPage: Int
    ) throws {
        try validateTerminalLinkHeader(url, rawLinkHeader: rawLinkHeader)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              components.host?.caseInsensitiveCompare("api.github.com") == .orderedSame,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.percentEncodedPath == "/user/orgs"
        else {
            throw GitHubIdentityClientError.invalidPaginationLink
        }
        let items = components.queryItems ?? []
        let pages = items.filter { $0.name == "page" }.map(\.value)
        let perPage = items.filter { $0.name == "per_page" }.map(\.value)
        guard items.count == pages.count + perPage.count,
              pages.count == 1,
              let rawPage = pages[0],
              rawPage.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.numericType != nil }),
              let page = Int(rawPage),
              page > 0,
              String(page) == rawPage,
              page == currentPage + 1,
              perPage == ["100"]
        else {
            throw GitHubIdentityClientError.invalidPaginationLink
        }
    }

    private nonisolated static func canonicalInventoryRequestKey(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath == "/user/orgs",
              let page = components.queryItems?.first(where: { $0.name == "page" })?.value,
              let pageNumber = Int(page), pageNumber > 0, String(pageNumber) == page
        else { return nil }
        return "GET /user/orgs?page=\(pageNumber)&per_page=100"
    }

    private nonisolated static func consumeOrganizationInventoryPayload(
        _ payload: Data,
        totalPayloadBytes: inout Int
    ) throws {
        guard payload.count <= maximumOrganizationInventoryResponseBytes - totalPayloadBytes else {
            throw GitHubIdentityClientError.organizationInventoryResponseTooLarge
        }
        totalPayloadBytes += payload.count
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
