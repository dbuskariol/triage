import Foundation

/// Read-only transport for the account-scoped GitHub notifications feed.
///
/// Notification records are discovery evidence. They must never be used to
/// mutate GitHub read state or to replace normalized issue/pull-request
/// content. The client deliberately exposes no mutation endpoint.
enum GitHubNotificationClientError: Error, Equatable, Sendable {
    case unexpectedNotModified
    case invalidNotification
    case duplicateNotification
    case paginationLoop
    case paginationLimitExceeded
    case invalidPaginationLink
    case pageObjectLimitExceeded
}

enum GitHubNotificationReason: String, Codable, CaseIterable, Sendable {
    case assign
    case author
    case comment
    case mention
    case teamMention
    case reviewRequested
    case securityAlert
    case stateChange
    case subscribed
    case ciActivity

    init?(githubValue: String) {
        switch githubValue {
        case "assign": self = .assign
        case "author": self = .author
        case "comment": self = .comment
        case "mention": self = .mention
        case "team_mention": self = .teamMention
        case "review_requested": self = .reviewRequested
        case "security_alert": self = .securityAlert
        case "state_change": self = .stateChange
        case "subscribed": self = .subscribed
        case "ci_activity": self = .ciActivity
        default: return nil
        }
    }
}

struct GitHubNotificationDTO: Codable, Equatable, Sendable {
    struct Repository: Codable, Equatable, Sendable {
        let id: UInt64
        let nodeID: String
        let name: String
        let fullName: String
        let owner: Owner

        struct Owner: Codable, Equatable, Sendable {
            let login: String
        }

        enum CodingKeys: String, CodingKey {
            case id
            case nodeID = "node_id"
            case name
            case fullName = "full_name"
            case owner
        }
    }

    struct Subject: Codable, Equatable, Sendable {
        let title: String
        let url: URL?
        let latestCommentURL: URL?
        let type: String

        enum CodingKeys: String, CodingKey {
            case title, url, type
            case latestCommentURL = "latest_comment_url"
        }
    }

    let id: String
    let unread: Bool
    let reason: String
    let updatedAt: Date
    let lastReadAt: Date?
    let repository: Repository
    let subject: Subject

    enum CodingKeys: String, CodingKey {
        case id, unread, reason, repository, subject
        case updatedAt = "updated_at"
        case lastReadAt = "last_read_at"
    }

    var knownReason: GitHubNotificationReason? {
        GitHubNotificationReason(githubValue: reason)
    }
}

struct GitHubNotificationPage: Sendable {
    let page: GitHubPage<GitHubNotificationDTO>
    let endpoint: String
}

struct GitHubNotificationInventory: Sendable {
    let notifications: [GitHubNotificationDTO]
    let pages: [GitHubNotificationPage]
    let ssoHeaders: [GitHubSSOHeader]

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }
}

enum GitHubNotificationFetch: Sendable {
    case modified(GitHubNotificationInventory)
    case notModified(ssoHeader: GitHubSSOHeader?)
}

actor GitHubNotificationClient {
    static let endpointPath = "/notifications"
    static let firstPageQuery = [
        URLQueryItem(name: "all", value: "true"),
        URLQueryItem(name: "participating", value: "false"),
        URLQueryItem(name: "per_page", value: "100")
    ]
    static let firstPageRequestKey = "GET /notifications?all=true&participating=false&per_page=100"

    private static let maximumPages = 100
    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
    }

    func allNotifications() async throws -> GitHubNotificationInventory {
        let result = try await fetchNotifications(validators: nil)
        guard case let .modified(inventory) = result else {
            throw GitHubNotificationClientError.unexpectedNotModified
        }
        return inventory
    }

    /// Fetches the exact account-notifications collection. A 304 is kept as a
    /// distinct result so the source repository can validate its independent
    /// request authority and normalized-state receipt before treating it as a
    /// successful unchanged interval.
    func fetchNotifications(
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubNotificationFetch {
        let initialRequest = try GitHubRESTRequest(
            path: Self.endpointPath,
            query: Self.firstPageQuery,
            validators: validators
        )
        var page: GitHubPage<GitHubNotificationDTO>
        do {
            page = try await client.getPage(GitHubNotificationDTO.self, request: initialRequest)
        } catch let failure as GitHubFailure where failure.statusCode == 304 {
            return .notModified(ssoHeader: failure.ssoHeader)
        }

        var values = [GitHubNotificationDTO]()
        var notificationIDs = Set<String>()
        var pages = [GitHubNotificationPage(
            page: page,
            endpoint: Self.firstPageEndpoint
        )]
        var ssoHeaders = [page.ssoHeader].compactMap { $0 }
        var visitedURLs = Set<String>()
        var currentPageNumber = 1

        try Self.append(page.values, to: &values, notificationIDs: &notificationIDs)
        while let nextURL = page.nextPageURL {
            try Task.checkCancellation()
            let nextPageNumber = try Self.validatePaginationLink(
                nextURL,
                rawLinkHeader: page.linkHeader,
                currentPageNumber: currentPageNumber
            )
            guard visitedURLs.insert(nextURL.absoluteString).inserted else {
                throw GitHubNotificationClientError.paginationLoop
            }
            guard pages.count < Self.maximumPages else {
                throw GitHubNotificationClientError.paginationLimitExceeded
            }
            page = try await client.getPage(
                GitHubNotificationDTO.self,
                request: try GitHubRESTRequest(nextPageURL: nextURL)
            )
            currentPageNumber = nextPageNumber
            pages.append(.init(page: page, endpoint: Self.endpoint(forPage: nextPageNumber)))
            try Self.append(page.values, to: &values, notificationIDs: &notificationIDs)
            if let ssoHeader = page.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
        }
        // An absent Link header is valid terminal pagination. A present but
        // malformed Link header is never silently accepted as terminal.
        try Self.validateTerminalLinkHeader(page.nextPageURL, rawLinkHeader: page.linkHeader)
        return .modified(.init(notifications: values, pages: pages, ssoHeaders: ssoHeaders))
    }

    private static let firstPageEndpoint = "/notifications?all=true&participating=false&per_page=100"

    private nonisolated static func append(
        _ pageValues: [GitHubNotificationDTO],
        to values: inout [GitHubNotificationDTO],
        notificationIDs: inout Set<String>
    ) throws {
        guard pageValues.count <= 100 else {
            throw GitHubNotificationClientError.pageObjectLimitExceeded
        }
        for value in pageValues {
            try validate(value)
            guard notificationIDs.insert(value.id).inserted else {
                throw GitHubNotificationClientError.duplicateNotification
            }
            values.append(value)
        }
    }

    private nonisolated static func validate(_ notification: GitHubNotificationDTO) throws {
        guard isOpaqueIdentifier(notification.id),
              notification.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              notification.lastReadAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              notification.repository.id > 0,
              GitHubNodeID(rawValue: notification.repository.nodeID) != nil,
              isRepositoryName(notification.repository.name),
              notification.repository.fullName == "\(notification.repository.owner.login)/\(notification.repository.name)",
              isGitHubLogin(notification.repository.owner.login),
              !notification.subject.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              notification.subject.title.count <= 8_192,
              isSubjectType(notification.subject.type),
              isGitHubAPIURL(notification.subject.url),
              isGitHubAPIURL(notification.subject.latestCommentURL),
              isReason(notification.reason)
        else {
            throw GitHubNotificationClientError.invalidNotification
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
            throw GitHubNotificationClientError.invalidPaginationLink
        }
    }

    private nonisolated static func validatePaginationLink(
        _ url: URL,
        rawLinkHeader: String?,
        currentPageNumber: Int
    ) throws -> Int {
        try validateTerminalLinkHeader(url, rawLinkHeader: rawLinkHeader)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              components.host?.caseInsensitiveCompare("api.github.com") == .orderedSame,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.percentEncodedPath == endpointPath
        else {
            throw GitHubNotificationClientError.invalidPaginationLink
        }
        let items = components.queryItems ?? []
        let all = items.filter { $0.name == "all" }.map(\.value)
        let participating = items.filter { $0.name == "participating" }.map(\.value)
        let perPage = items.filter { $0.name == "per_page" }.map(\.value)
        let pages = items.filter { $0.name == "page" }.map(\.value)
        guard items.count == 4,
              all == ["true"],
              participating == ["false"],
              perPage == ["100"],
              pages.count == 1,
              let rawPage = pages[0],
              rawPage.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.numericType != nil }),
              let pageNumber = Int(rawPage),
              pageNumber > 0,
              String(pageNumber) == rawPage
        else {
            throw GitHubNotificationClientError.invalidPaginationLink
        }
        guard pageNumber <= maximumPages else {
            throw GitHubNotificationClientError.paginationLimitExceeded
        }
        guard pageNumber == currentPageNumber + 1 else {
            throw GitHubNotificationClientError.paginationLoop
        }
        return pageNumber
    }

    private nonisolated static func endpoint(forPage page: Int) -> String {
        "\(firstPageEndpoint)&page=\(page)"
    }

    private nonisolated static func isOpaqueIdentifier(_ value: String) -> Bool {
        (1...512).contains(value.count) && value.unicodeScalars.allSatisfy {
            !$0.properties.isWhitespace && $0.value >= 0x20 && $0.value != 0x7F
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

    private nonisolated static func isSubjectType(_ value: String) -> Bool {
        ["Issue", "PullRequest", "Commit", "Release", "Discussion", "RepositoryVulnerabilityAlert", "CheckSuite"].contains(value)
    }

    private nonisolated static func isGitHubAPIURL(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.scheme == "https" && url.host?.caseInsensitiveCompare("api.github.com") == .orderedSame
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    private nonisolated static func isReason(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isLowercase || $0.properties.numericType != nil || $0 == "_")
        }
    }
}
