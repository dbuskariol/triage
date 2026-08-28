import Foundation

enum GitHubIssueSearchError: Error, Equatable, Sendable {
    case invalidOrganizationLogin
    case invalidUserLogin
    case invalidQualifier
    case conflictingUpdatedConstraints
}

enum GitHubIssueSearchState: String, Sendable {
    case open
    case closed
}

enum GitHubIssueSearchRelationship: Hashable, Sendable {
    case involves
    case authored
    case assigned
    case mentioned
    case commented
    case reviewRequested
    case reviewInvolves

    var qualifier: String {
        switch self {
        case .involves: "involves"
        case .authored: "author"
        case .assigned: "assignee"
        case .mentioned: "mentions"
        case .commented: "commenter"
        case .reviewRequested: "review-requested"
        case .reviewInvolves: "review-involves"
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
        var qualifiers = [
            "org:\(organizationLogin)",
            "is:\(state.rawValue)",
            "\(relationship.qualifier):\(userLogin)"
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

protocol GitHubIssueSearchExecuting: Sendable {
    func searchResponse(
        _ query: GitHubIssueSearchQuery,
        page: Int
    ) async throws -> GitHubResponse<GitHubIssueSearchPage>
}

actor GitHubIssueSearchClient: GitHubIssueSearchExecuting {
    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
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
        try await client.getResponse(
            GitHubIssueSearchPage.self,
            request: GitHubRESTRequest(
                path: "/search/issues",
                query: [
                    URLQueryItem(name: "q", value: query.value),
                    URLQueryItem(name: "sort", value: "updated"),
                    URLQueryItem(name: "order", value: "desc"),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(max(page, 1)))
                ]
            )
        )
    }
}
