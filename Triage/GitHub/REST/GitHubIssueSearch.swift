import Foundation

enum GitHubIssueSearchError: Error, Equatable, Sendable {
    case invalidOrganizationLogin
    case invalidUserLogin
    case invalidQualifier
}

enum GitHubIssueSearchState: String, Sendable {
    case open
    case closed
}

enum GitHubIssueSearchRelationship: Sendable {
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

    init(
        organizationLogin: String,
        userLogin: String,
        state: GitHubIssueSearchState,
        relationship: GitHubIssueSearchRelationship,
        updatedAfter: Date? = nil,
        closedAfter: Date? = nil
    ) throws {
        guard Self.isGitHubLogin(organizationLogin) else {
            throw GitHubIssueSearchError.invalidOrganizationLogin
        }
        guard Self.isGitHubLogin(userLogin) else {
            throw GitHubIssueSearchError.invalidUserLogin
        }
        var qualifiers = [
            "org:\(organizationLogin)",
            "is:\(state.rawValue)",
            "\(relationship.qualifier):\(userLogin)"
        ]
        if let updatedAfter {
            qualifiers.append("updated:>=\(Self.dayString(updatedAfter))")
        }
        if let closedAfter {
            qualifiers.append("closed:>=\(Self.dayString(closedAfter))")
        }
        value = qualifiers.joined(separator: " ")
    }

    private static func isGitHubLogin(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 39
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-")
            }
    }

    private static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
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

actor GitHubIssueSearchClient {
    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
    }

    func search(
        _ query: GitHubIssueSearchQuery,
        page: Int = 1
    ) async throws -> GitHubIssueSearchPage {
        try await client.get(
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
