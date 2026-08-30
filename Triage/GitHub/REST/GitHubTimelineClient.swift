import Foundation

indirect enum GitHubTimelineJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case string(String)
    case array([GitHubTimelineJSONValue])
    case object([String: GitHubTimelineJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([GitHubTimelineJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: GitHubTimelineJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .unsignedInteger(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    func isBounded(
        maximumDepth: Int = 64,
        maximumValues: Int = 20_000,
        maximumStringBytes: Int = 256 * 1_024
    ) -> Bool {
        var remainingValues = maximumValues
        func validate(_ value: GitHubTimelineJSONValue, depth: Int) -> Bool {
            guard depth <= maximumDepth, remainingValues > 0 else { return false }
            remainingValues -= 1
            switch value {
            case .null, .bool, .integer, .unsignedInteger, .number:
                return true
            case let .string(string):
                return string.utf8.count <= maximumStringBytes
            case let .array(values):
                return values.allSatisfy { validate($0, depth: depth + 1) }
            case let .object(values):
                return values.allSatisfy {
                    $0.key.utf8.count <= maximumStringBytes && validate($0.value, depth: depth + 1)
                }
            }
        }
        return validate(self, depth: 0)
    }
}

struct GitHubTimelineEventDTO: Codable, Sendable {
    let id: String?
    let event: String?
    let createdAt: Date?
    let actor: Actor?
    let payload: GitHubTimelineJSONValue

    struct Actor: Codable, Sendable {
        let nodeID: String?
        let login: String?

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case login
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, event, actor
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let payload = try GitHubTimelineJSONValue(from: decoder)
        guard case .object = payload else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Timeline event must be an object.")
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.stringValue(from: container, forKey: .id)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        actor = try container.decodeIfPresent(Actor.self, forKey: .actor)
        self.payload = payload
    }

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
    }

    private static func stringValue(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        guard container.contains(key), !(try container.decodeNil(forKey: key)) else {
            return nil
        }
        if let string = try? container.decode(String.self, forKey: key) {
            return string
        }
        if let integer = try? container.decode(Int64.self, forKey: key) {
            return String(integer)
        }
        if let integer = try? container.decode(UInt64.self, forKey: key) {
            return String(integer)
        }
        return nil
    }
}

enum GitHubTimelineClientError: Error, Equatable, Sendable {
    case paginationLoop
    case paginationLimitExceeded
    case unexpectedNotModified
    case invalidPaginationLink
}

enum GitHubTimelinePageResult: Sendable {
    case page(GitHubPage<GitHubTimelineEventDTO>)
    case notModified(ssoHeader: GitHubSSOHeader?)
}

struct GitHubTimelineInventory: Sendable {
    let events: [GitHubTimelineEventDTO]
    let pages: [GitHubPage<GitHubTimelineEventDTO>]
    let ssoHeaders: [GitHubSSOHeader]
    let isNotModified: Bool

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }
}

actor GitHubTimelineClient {
    private static let maximumTimelinePages = 100
    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
    }

    func timeline(
        repository: GitHubRepositoryPath,
        issueOrPullRequestNumber: Int,
        page: Int = 1
    ) async throws -> GitHubPage<GitHubTimelineEventDTO> {
        switch try await firstPage(
            repository: repository,
            issueOrPullRequestNumber: issueOrPullRequestNumber,
            page: page
        ) {
        case let .page(result):
            return result
        case .notModified:
            throw GitHubTimelineClientError.unexpectedNotModified
        }
    }

    func firstPage(
        repository: GitHubRepositoryPath,
        issueOrPullRequestNumber: Int,
        page: Int = 1,
        ifNoneMatch: String? = nil
    ) async throws -> GitHubTimelinePageResult {
        guard issueOrPullRequestNumber > 0 else {
            throw GitHubRepositoryPathError.invalidPullRequestNumber
        }
        let headers = ifNoneMatch.map { ["If-None-Match": $0] } ?? [:]
        do {
            let result = try await client.getPage(
                GitHubTimelineEventDTO.self,
                request: GitHubRESTRequest(
                    path: "\(repository.path)/issues/\(issueOrPullRequestNumber)/timeline",
                    query: [
                        URLQueryItem(name: "per_page", value: "100"),
                        URLQueryItem(name: "page", value: String(max(page, 1)))
                    ],
                    headers: headers
                )
            )
            try Self.validatePaginationLink(
                result.nextPageURL,
                rawLinkHeader: result.linkHeader,
                repository: repository,
                issueOrPullRequestNumber: issueOrPullRequestNumber
            )
            return .page(result)
        } catch let failure as GitHubFailure where failure.statusCode == 304 {
            return .notModified(ssoHeader: failure.ssoHeader)
        }
    }

    func nextPage(
        _ url: URL,
        repository: GitHubRepositoryPath,
        issueOrPullRequestNumber: Int
    ) async throws -> GitHubPage<GitHubTimelineEventDTO> {
        try Self.validatePaginationLink(
            url,
            repository: repository,
            issueOrPullRequestNumber: issueOrPullRequestNumber
        )
        let result = try await client.getPage(
            GitHubTimelineEventDTO.self,
            request: GitHubRESTRequest(nextPageURL: url)
        )
        try Self.validatePaginationLink(
            result.nextPageURL,
            rawLinkHeader: result.linkHeader,
            repository: repository,
            issueOrPullRequestNumber: issueOrPullRequestNumber
        )
        return result
    }

    func allTimeline(
        repository: GitHubRepositoryPath,
        issueOrPullRequestNumber: Int,
        ifNoneMatch: String? = nil
    ) async throws -> GitHubTimelineInventory {
        let first = try await firstPage(
            repository: repository,
            issueOrPullRequestNumber: issueOrPullRequestNumber,
            ifNoneMatch: ifNoneMatch
        )
        guard case let .page(initialPage) = first else {
            if case let .notModified(ssoHeader) = first {
                return GitHubTimelineInventory(
                    events: [],
                    pages: [],
                    ssoHeaders: [ssoHeader].compactMap { $0 },
                    isNotModified: true
                )
            }
            throw GitHubTimelineClientError.unexpectedNotModified
        }

        var page = initialPage
        var pages = [page]
        var events = page.values
        var ssoHeaders = [page.ssoHeader].compactMap { $0 }
        var visitedPageURLs = Set<String>()

        while let nextPageURL = page.nextPageURL {
            try Task.checkCancellation()
            guard visitedPageURLs.insert(nextPageURL.absoluteString).inserted else {
                throw GitHubTimelineClientError.paginationLoop
            }
            guard pages.count < Self.maximumTimelinePages else {
                throw GitHubTimelineClientError.paginationLimitExceeded
            }
            page = try await nextPage(
                nextPageURL,
                repository: repository,
                issueOrPullRequestNumber: issueOrPullRequestNumber
            )
            pages.append(page)
            events.append(contentsOf: page.values)
            if let ssoHeader = page.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
        }
        return GitHubTimelineInventory(
            events: events,
            pages: pages,
            ssoHeaders: ssoHeaders,
            isNotModified: false
        )
    }

    private nonisolated static func validatePaginationLink(
        _ url: URL?,
        rawLinkHeader: String? = nil,
        repository: GitHubRepositoryPath,
        issueOrPullRequestNumber: Int
    ) throws {
        if let rawLinkHeader, !rawLinkHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = GitHubLinkHeader(rawLinkHeader),
                  parsed.isWellFormed,
                  parsed.nextPageURL == url
            else {
                throw GitHubTimelineClientError.invalidPaginationLink
            }
        }
        guard let url else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host?.caseInsensitiveCompare("api.github.com") == .orderedSame,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.path == "\(repository.path)/issues/\(issueOrPullRequestNumber)/timeline"
        else {
            throw GitHubTimelineClientError.invalidPaginationLink
        }
        let allowedNames: Set<String> = ["page", "per_page"]
        let items = components.queryItems ?? []
        let perPage = items.first(where: { $0.name == "per_page" })?.value.flatMap(Int.init) ?? 100
        guard !items.isEmpty,
              Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ allowedNames.contains($0.name) }),
              let page = items.first(where: { $0.name == "page" })?.value.flatMap(Int.init),
              page > 0,
              perPage > 0,
              perPage <= 100
        else {
            throw GitHubTimelineClientError.invalidPaginationLink
        }
    }
}
