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
    case pageObjectLimitExceeded
}

struct GitHubTimelineUndecodablePageError: Error, Equatable, Sendable {
    let page: GitHubUndecodablePage
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
        validators: GitHubHTTPValidators? = nil
    ) async throws -> GitHubTimelinePageResult {
        guard issueOrPullRequestNumber > 0 else {
            throw GitHubRepositoryPathError.invalidPullRequestNumber
        }
        do {
            let decodingResult = try await client.getPagePreservingUndecodablePayload(
                GitHubTimelineEventDTO.self,
                request: GitHubRESTRequest(
                    path: "\(repository.path)/issues/\(issueOrPullRequestNumber)/timeline",
                    query: [
                        URLQueryItem(name: "per_page", value: "100"),
                        URLQueryItem(name: "page", value: String(max(page, 1)))
                    ],
                    validators: validators
                )
            )
            guard case let .page(result) = decodingResult else {
                if case let .undecodable(page) = decodingResult {
                    throw GitHubTimelineUndecodablePageError(page: page)
                }
                throw GitHubRESTClientError.invalidJSON
            }
            guard result.values.count <= 100 else {
                throw GitHubTimelineClientError.pageObjectLimitExceeded
            }
            try Self.validatePaginationLink(
                result.nextPageURL,
                rawLinkHeader: result.linkHeader,
                repository: repository,
                issueOrPullRequestNumber: issueOrPullRequestNumber,
                currentPage: max(page, 1)
            )
            return .page(result)
        } catch let failure as GitHubFailure where failure.statusCode == 304 {
            guard validators != nil else {
                throw GitHubTimelineClientError.unexpectedNotModified
            }
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
        let decodingResult = try await client.getPagePreservingUndecodablePayload(
            GitHubTimelineEventDTO.self,
            request: GitHubRESTRequest(nextPageURL: url)
        )
        guard case let .page(result) = decodingResult else {
            if case let .undecodable(page) = decodingResult {
                throw GitHubTimelineUndecodablePageError(page: page)
            }
            throw GitHubRESTClientError.invalidJSON
        }
        guard result.values.count <= 100 else {
            throw GitHubTimelineClientError.pageObjectLimitExceeded
        }
        try Self.validatePaginationLink(
            result.nextPageURL,
            rawLinkHeader: result.linkHeader,
            repository: repository,
            issueOrPullRequestNumber: issueOrPullRequestNumber,
            currentPage: try Self.pageNumber(from: url)
        )
        return result
    }

    func allTimeline(
        repository: GitHubRepositoryPath,
        issueOrPullRequestNumber: Int,
        validators: GitHubHTTPValidators? = nil
    ) async throws -> GitHubTimelineInventory {
        let first = try await firstPage(
            repository: repository,
            issueOrPullRequestNumber: issueOrPullRequestNumber,
            validators: validators
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
        issueOrPullRequestNumber: Int,
        currentPage: Int? = nil
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
        guard !items.isEmpty,
              Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ allowedNames.contains($0.name) }),
              items.count == 2,
              let rawPage = items.first(where: { $0.name == "page" })?.value,
              rawPage.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.numericType != nil }),
              let page = Int(rawPage),
              page > 0,
              String(page) == rawPage,
              items.first(where: { $0.name == "per_page" })?.value == "100",
              currentPage.map({ page == $0 + 1 }) ?? true
        else {
            throw GitHubTimelineClientError.invalidPaginationLink
        }
    }

    private nonisolated static func pageNumber(from url: URL) throws -> Int {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "page" })?.value,
              let page = Int(raw), page > 0, String(page) == raw
        else { throw GitHubTimelineClientError.invalidPaginationLink }
        return page
    }
}
