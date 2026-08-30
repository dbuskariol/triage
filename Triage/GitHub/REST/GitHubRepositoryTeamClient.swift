import Foundation

enum GitHubRepositoryTeamClientError: Error, Equatable, Sendable {
    case invalidOrganizationLogin
    case invalidAccountLogin
    case paginationLoop
    case paginationLimitExceeded
    case pageObjectLimitExceeded
    case notModifiedWithoutCachedState
    case ambiguousMembershipVisibility
    case invalidRepository
    case repositoryOutsideOrganization
    case duplicateRepository
    case invalidTeam
    case duplicateTeam
    case invalidMembership
}

enum GitHubRepositoryTeamFetch<Value: Sendable>: Sendable {
    case modified(GitHubRepositoryTeamInventory<Value>)
    case notModified
}

struct GitHubRepositoryTeamPage<Value: Sendable>: Sendable {
    let page: GitHubPage<Value>
    let endpoint: String
}

struct GitHubRepositoryTeamInventory<Value: Sendable>: Sendable {
    let values: [Value]
    let pages: [GitHubRepositoryTeamPage<Value>]
    let ssoHeaders: [GitHubSSOHeader]

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }
}

struct GitHubTeamDTO: Codable, Equatable, Sendable {
    let id: UInt64
    let nodeID: String
    let name: String
    let slug: String
    let privacy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case name
        case slug
        case privacy
    }
}

struct GitHubTeamMembershipDTO: Codable, Equatable, Sendable {
    let state: String
    let role: String?
}

enum GitHubTeamMembership: Sendable {
    case member(GitHubResponse<GitHubTeamMembershipDTO>)
    case authoritativeNonMembership(GitHubResponse<GitHubTeamMembershipDTO>)
    case unknown
}

actor GitHubRepositoryTeamClient {
    private static let maximumPages = 100
    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
    }

    func allRepositories(
        in organization: String
    ) async throws -> GitHubRepositoryTeamInventory<GitHubRepositoryDTO> {
        let result = try await fetchRepositories(in: organization, validators: nil)
        guard case let .modified(inventory) = result else {
            throw GitHubRepositoryTeamClientError.notModifiedWithoutCachedState
        }
        return inventory
    }

    func fetchRepositories(
        in organization: String,
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubRepositoryTeamFetch<GitHubRepositoryDTO> {
        try validateOrganizationLogin(organization)
        let result = try await allPages(
            GitHubRepositoryDTO.self,
            path: "/orgs/\(organization)/repos",
            query: [
                URLQueryItem(name: "type", value: "all"),
                URLQueryItem(name: "per_page", value: "100")
            ],
            validators: validators,
            validator: { try Self.validate($0, organization: organization) }
        )
        guard case let .modified(inventory) = result else {
            return .notModified
        }
        guard Set(inventory.values.map(\.id)).count == inventory.values.count,
              Set(inventory.values.map(\.nodeID)).count == inventory.values.count
        else {
            throw GitHubRepositoryTeamClientError.duplicateRepository
        }
        return .modified(inventory)
    }

    func allTeams(
        in organization: String
    ) async throws -> GitHubRepositoryTeamInventory<GitHubTeamDTO> {
        let result = try await fetchTeams(in: organization, validators: nil)
        guard case let .modified(inventory) = result else {
            throw GitHubRepositoryTeamClientError.notModifiedWithoutCachedState
        }
        return inventory
    }

    func fetchTeams(
        in organization: String,
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubRepositoryTeamFetch<GitHubTeamDTO> {
        try validateOrganizationLogin(organization)
        let result = try await allPages(
            GitHubTeamDTO.self,
            path: "/orgs/\(organization)/teams",
            query: [URLQueryItem(name: "per_page", value: "100")],
            validators: validators,
            validator: Self.validate
        )
        guard case let .modified(inventory) = result else {
            return .notModified
        }
        guard Set(inventory.values.map(\.id)).count == inventory.values.count,
              Set(inventory.values.map(\.nodeID)).count == inventory.values.count,
              Set(inventory.values.map(\.slug)).count == inventory.values.count
        else {
            throw GitHubRepositoryTeamClientError.duplicateTeam
        }
        return .modified(inventory)
    }

    func membership(
        in organization: String,
        teamSlug: String,
        accountLogin: String
    ) async throws -> GitHubTeamMembership {
        try validateOrganizationLogin(organization)
        try validateAccountLogin(accountLogin)
        guard Self.isTeamSlug(teamSlug) else {
            throw GitHubRepositoryTeamClientError.invalidTeam
        }
        let endpoint = "/orgs/\(organization)/teams/\(teamSlug)/memberships/\(accountLogin)"
        do {
            let response = try await client.getResponse(
                GitHubTeamMembershipDTO.self,
                request: GitHubRESTRequest(path: endpoint)
            )
            try Self.validate(response.value)
            return .member(response)
        } catch let error as GitHubFailure where error.kind == .notFound && error.ssoHeader == nil {
            return .unknown
        }
    }

    private func allPages<Value: Decodable & Sendable>(
        _ type: Value.Type,
        path: String,
        query: [URLQueryItem],
        validators: GitHubHTTPValidators?,
        validator: (Value) throws -> Void
    ) async throws -> GitHubRepositoryTeamFetch<Value> {
        var endpoint = Self.endpoint(path: path, query: query)
        let initialRequest = try GitHubRESTRequest(
            path: path,
            query: query,
            validators: validators
        )
        var page: GitHubPage<Value>
        do {
            page = try await client.getPage(type, request: initialRequest)
        } catch let failure as GitHubFailure where failure.statusCode == 304 {
            guard validators != nil else {
                throw GitHubRepositoryTeamClientError.notModifiedWithoutCachedState
            }
            return .notModified
        }
        var pages = [GitHubRepositoryTeamPage(page: page, endpoint: endpoint)]
        var values = [Value]()
        var ssoHeaders = [page.ssoHeader].compactMap { $0 }
        var visitedPageURLs = Set<String>()

        try append(page.values, to: &values, validator: validator)
        while let nextPageURL = page.nextPageURL {
            try Task.checkCancellation()
            guard nextPageURL.path == path,
                  nextPageURL.scheme == "https",
                  nextPageURL.host == "api.github.com",
                  visitedPageURLs.insert(nextPageURL.absoluteString).inserted
            else {
                throw GitHubRepositoryTeamClientError.paginationLoop
            }
            guard pages.count < Self.maximumPages else {
                throw GitHubRepositoryTeamClientError.paginationLimitExceeded
            }

            page = try await client.getPage(
                type,
                request: try GitHubRESTRequest(nextPageURL: nextPageURL)
            )
            endpoint = nextPageURL.path + (nextPageURL.query.map { "?\($0)" } ?? "")
            pages.append(GitHubRepositoryTeamPage(page: page, endpoint: endpoint))
            try append(page.values, to: &values, validator: validator)
            if let ssoHeader = page.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
        }
        return .modified(
            GitHubRepositoryTeamInventory(values: values, pages: pages, ssoHeaders: ssoHeaders)
        )
    }

    private func append<Value>(
        _ pageValues: [Value],
        to values: inout [Value],
        validator: (Value) throws -> Void
    ) throws {
        guard pageValues.count <= 100 else {
            throw GitHubRepositoryTeamClientError.pageObjectLimitExceeded
        }
        for value in pageValues {
            try validator(value)
            values.append(value)
        }
    }

    private func validateOrganizationLogin(_ value: String) throws {
        guard Self.isGitHubLogin(value) else {
            throw GitHubRepositoryTeamClientError.invalidOrganizationLogin
        }
    }

    private func validateAccountLogin(_ value: String) throws {
        guard Self.isGitHubLogin(value) else {
            throw GitHubRepositoryTeamClientError.invalidAccountLogin
        }
    }

    private nonisolated static func validate(
        _ repository: GitHubRepositoryDTO,
        organization: String
    ) throws {
        guard repository.owner.login.caseInsensitiveCompare(organization) == .orderedSame else {
            throw GitHubRepositoryTeamClientError.repositoryOutsideOrganization
        }
        guard repository.id > 0,
              GitHubNodeID(rawValue: repository.nodeID) != nil,
              isRepositoryName(repository.name),
              isGitHubLogin(repository.owner.login),
              isGitHubURL(repository.htmlURL, owner: repository.owner.login, repository: repository.name)
        else {
            throw GitHubRepositoryTeamClientError.invalidRepository
        }
    }

    private nonisolated static func validate(_ team: GitHubTeamDTO) throws {
        guard team.id > 0,
              GitHubNodeID(rawValue: team.nodeID) != nil,
              !team.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              team.name.count <= 255,
              isTeamSlug(team.slug),
              team.privacy == nil || team.privacy == "closed" || team.privacy == "secret"
        else {
            throw GitHubRepositoryTeamClientError.invalidTeam
        }
    }

    private nonisolated static func validate(_ membership: GitHubTeamMembershipDTO) throws {
        guard membership.state == "active" || membership.state == "pending",
              membership.role.map({ $0 == "member" || $0 == "maintainer" }) ?? true
        else {
            throw GitHubRepositoryTeamClientError.invalidMembership
        }
    }

    private nonisolated static func isGitHubLogin(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 39 && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-")
        }
    }

    private nonisolated static func isRepositoryName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && !value.contains("/") && !value.contains(where: \.isWhitespace)
    }

    private nonisolated static func isTeamSlug(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 255 && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isLowercase || $0.properties.numericType != nil || $0 == "-")
        }
    }

    private nonisolated static func isGitHubURL(_ url: URL, owner: String, repository: String) -> Bool {
        guard url.scheme == "https",
              url.host == "github.com",
              url.user == nil,
              url.password == nil
        else {
            return false
        }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        return components.count == 2
            && components[0].caseInsensitiveCompare(owner) == .orderedSame
            && components[1] == repository
    }

    private nonisolated static func endpoint(path: String, query: [URLQueryItem]) -> String {
        guard !query.isEmpty else { return path }
        var components = URLComponents()
        components.queryItems = query
        return path + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
    }
}
