import CryptoKit
import Foundation

enum GitHubIssueSearchError: Error, Equatable, Sendable {
    case invalidOrganizationLogin
    case invalidUserLogin
    case invalidQualifier
    case conflictingUpdatedConstraints
    case invalidPage
    case unexpectedNotModified
    case pageObjectLimitExceeded
}

enum GitHubIssueSearchState: String, Sendable {
    case open
    case closed
    case merged
}

enum GitHubIssueSearchRelationship: Hashable, Sendable {
    case involves
    case authored
    case assigned
    case mentioned
    case commented
    case reviewRequested
    case reviewInvolves
    case teamReviewRequested(teamNodeID: GitHubNodeID, teamSlug: String)

    var qualifier: String {
        switch self {
        case .involves: "involves"
        case .authored: "author"
        case .assigned: "assignee"
        case .mentioned: "mentions"
        case .commented: "commenter"
        case .reviewRequested: "review-requested"
        case .reviewInvolves: "reviewed-by"
        case .teamReviewRequested: "team-review-requested"
        }
    }
}

struct GitHubIssueSearchQuery: Sendable {
    let value: String
    let relationship: GitHubIssueSearchRelationship
    private let organizationLogin: String
    private let userLogin: String
    private let state: GitHubIssueSearchState
    private let closedAfter: Date?
    private let repositoryFullName: String?

    init(
        organizationLogin: String,
        userLogin: String,
        state: GitHubIssueSearchState,
        relationship: GitHubIssueSearchRelationship,
        updatedAfter: Date? = nil,
        closedAfter: Date? = nil,
        updatedRange: SearchTimeRange? = nil,
        repositoryFullName: String? = nil
    ) throws {
        guard Self.isGitHubLogin(organizationLogin) else {
            throw GitHubIssueSearchError.invalidOrganizationLogin
        }
        guard Self.isGitHubLogin(userLogin) else {
            throw GitHubIssueSearchError.invalidUserLogin
        }
        guard updatedAfter == nil || updatedRange == nil else {
            throw GitHubIssueSearchError.conflictingUpdatedConstraints
        }
        guard repositoryFullName.map(Self.isRepositoryFullName) ?? true else {
            throw GitHubIssueSearchError.invalidQualifier
        }
        let relationshipValue: String
        switch relationship {
        case let .teamReviewRequested(_, teamSlug):
            guard Self.isTeamSlug(teamSlug) else {
                throw GitHubIssueSearchError.invalidQualifier
            }
            relationshipValue = "\(organizationLogin)/\(teamSlug)"
        case .involves, .authored, .assigned, .mentioned, .commented, .reviewRequested, .reviewInvolves:
            relationshipValue = userLogin
        }
        var qualifiers = [
            "org:\(organizationLogin)",
            "is:\(state.rawValue)",
            "\(relationship.qualifier):\(relationshipValue)"
        ]
        if let updatedAfter {
            qualifiers.append("updated:>=\(Self.dayString(updatedAfter))")
        }
        if let updatedRange {
            qualifiers.append(
                "updated:\(Self.timestampString(updatedRange.start))..\(Self.timestampString(updatedRange.end))"
            )
        }
        if let closedAfter {
            qualifiers.append("closed:>=\(Self.dayString(closedAfter))")
        }
        if let repositoryFullName {
            qualifiers.append("repo:\(repositoryFullName)")
        }
        self.organizationLogin = organizationLogin
        self.userLogin = userLogin
        self.state = state
        self.relationship = relationship
        self.closedAfter = closedAfter
        self.repositoryFullName = repositoryFullName
        value = qualifiers.joined(separator: " ")
    }

    func bounded(to updatedRange: SearchTimeRange) throws -> GitHubIssueSearchQuery {
        try GitHubIssueSearchQuery(
            organizationLogin: organizationLogin,
            userLogin: userLogin,
            state: state,
            relationship: relationship,
            closedAfter: closedAfter,
            updatedRange: updatedRange,
            repositoryFullName: repositoryFullName
        )
    }

    func scoped(to repositoryFullName: String) throws -> GitHubIssueSearchQuery {
        try GitHubIssueSearchQuery(
            organizationLogin: organizationLogin,
            userLogin: userLogin,
            state: state,
            relationship: relationship,
            closedAfter: closedAfter,
            repositoryFullName: repositoryFullName
        )
    }

    func scoped(
        to repositoryFullName: String,
        updatedRange: SearchTimeRange
    ) throws -> GitHubIssueSearchQuery {
        try scoped(to: repositoryFullName).bounded(to: updatedRange)
    }

    private static func isGitHubLogin(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 39
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-")
            }
    }

    private static func isRepositoryFullName(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else {
            return false
        }
        return (try? GitHubRepositoryPath(
            owner: String(components[0]),
            repository: String(components[1])
        )) != nil
    }

    private static func isTeamSlug(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 255 && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isLowercase || $0.properties.numericType != nil || $0 == "-")
        }
    }

    private static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }
}

struct GitHubIssueSearchPage: Codable, Sendable {
    let totalCount: Int
    let incompleteResults: Bool
    let items: [GitHubIssueSearchItem]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case incompleteResults = "incomplete_results"
        case items
    }
}

struct GitHubIssueSearchItem: Codable, Sendable {
    let id: UInt64
    let nodeID: String
    let number: Int
    let title: String
    let state: String
    let htmlURL: URL
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let pullRequest: PullRequestMarker?
    let repositoryURL: URL

    struct PullRequestMarker: Codable, Sendable {
        let url: URL?
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case number
        case title
        case state
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
        case pullRequest = "pull_request"
        case repositoryURL = "repository_url"
    }
}

struct GitHubIssueSearchRequestIdentity: Equatable, Sendable {
    static let parserVersion = 2

    let requestKey: String
    let endpoint: String
    let queryValue: String
    let page: Int

    init(
        query: GitHubIssueSearchQuery,
        page: Int,
        scope: SynchronizationScope,
        streamID: SyncStreamID
    ) throws {
        guard (1...100).contains(page) else {
            throw GitHubIssueSearchError.invalidPage
        }
        let request = try GitHubIssueSearchClient.request(
            query,
            page: page,
            validators: nil
        )
        let url = try request.resolvedURL(baseURL: URL(string: "https://api.github.com")!)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GitHubTransportError.invalidURL
        }
        let endpoint = components.percentEncodedQuery.map {
            "\(components.percentEncodedPath)?\($0)"
        } ?? components.percentEncodedPath
        let material = [
            "triage-role-search-v2",
            scope.accountID.rawValue,
            scope.organizationID.rawValue,
            CoverageFeature.roleDiscovery.rawValue,
            streamID.rawValue,
            "GET",
            scope.credentialRevision.rawValue,
            scope.capabilityRevision.rawValue,
            String(Self.parserVersion),
            endpoint
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
        requestKey = "role-search:" + digest.map { String(format: "%02x", $0) }.joined()
        self.endpoint = endpoint
        queryValue = query.value
        self.page = page
    }
}

protocol GitHubIssueSearchExecuting: Sendable {
    func searchResult(
        _ query: GitHubIssueSearchQuery,
        page: Int,
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubIssueSearchResult
}

enum GitHubIssueSearchResult: Sendable {
    case response(GitHubResponse<GitHubIssueSearchPage>)
    case undecodable(GitHubUndecodableResponse)
    case notModified(ssoHeader: GitHubSSOHeader?)
}

extension GitHubIssueSearchExecuting {
    func searchResult(
        _ query: GitHubIssueSearchQuery,
        page: Int
    ) async throws -> GitHubIssueSearchResult {
        try await searchResult(query, page: page, validators: nil)
    }

    func searchResponse(
        _ query: GitHubIssueSearchQuery,
        page: Int
    ) async throws -> GitHubResponse<GitHubIssueSearchPage> {
        switch try await searchResult(query, page: page) {
        case let .response(response):
            return response
        case .undecodable:
            throw GitHubRESTClientError.invalidJSON
        case .notModified:
            throw GitHubIssueSearchError.unexpectedNotModified
        }
    }
}

actor GitHubIssueSearchClient: GitHubIssueSearchExecuting {
    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
    }

    func serverTime() async throws -> Date {
        try await client.serverTime()
    }

    func search(
        _ query: GitHubIssueSearchQuery,
        page: Int = 1
    ) async throws -> GitHubIssueSearchPage {
        try await searchResponse(query, page: page).value
    }

    func searchResponse(
        _ query: GitHubIssueSearchQuery,
        page: Int = 1
    ) async throws -> GitHubResponse<GitHubIssueSearchPage> {
        switch try await searchResult(query, page: page) {
        case let .response(response):
            return response
        case .undecodable:
            throw GitHubRESTClientError.invalidJSON
        case .notModified:
            throw GitHubIssueSearchError.unexpectedNotModified
        }
    }

    func searchResult(
        _ query: GitHubIssueSearchQuery,
        page: Int = 1
    ) async throws -> GitHubIssueSearchResult {
        try await searchResult(query, page: page, validators: nil)
    }

    func searchResult(
        _ query: GitHubIssueSearchQuery,
        page: Int,
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubIssueSearchResult {
        do {
            let result = try await client.getResponsePreservingUndecodablePayload(
                GitHubIssueSearchPage.self,
                request: try Self.request(query, page: page, validators: validators)
            )
            switch result {
            case let .response(response):
                guard response.value.items.count <= 100 else {
                    throw GitHubIssueSearchError.pageObjectLimitExceeded
                }
                return .response(response)
            case let .undecodable(response):
                return .undecodable(response)
            }
        } catch let failure as GitHubFailure where failure.statusCode == 304 {
            return .notModified(ssoHeader: failure.ssoHeader)
        }
    }

    nonisolated static func request(
        _ query: GitHubIssueSearchQuery,
        page: Int,
        validators: GitHubHTTPValidators?
    ) throws -> GitHubRESTRequest {
        guard (1...100).contains(page) else {
            throw GitHubIssueSearchError.invalidPage
        }
        return try GitHubRESTRequest(
            path: "/search/issues",
            query: [
                URLQueryItem(name: "q", value: query.value),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ],
            validators: validators
        )
    }

    nonisolated static func decodeReplayPayload(_ payload: Data) throws -> GitHubIssueSearchPage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubIssueSearchPage.self, from: payload)
    }
}
