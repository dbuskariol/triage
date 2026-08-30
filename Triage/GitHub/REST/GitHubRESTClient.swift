import Foundation

struct GitHubPage<Value: Sendable>: Sendable {
    let values: [Value]
    let payload: Data
    let nextPageURL: URL?
    let linkHeader: String?
    let etag: String?
    let lastModified: String?
    let ssoHeader: GitHubSSOHeader?

    init(
        values: [Value],
        payload: Data,
        nextPageURL: URL?,
        linkHeader: String? = nil,
        etag: String?,
        lastModified: String?,
        ssoHeader: GitHubSSOHeader?
    ) {
        self.values = values
        self.payload = payload
        self.nextPageURL = nextPageURL
        self.linkHeader = linkHeader
        self.etag = etag
        self.lastModified = lastModified
        self.ssoHeader = ssoHeader
    }
}

struct GitHubResponse<Value: Sendable>: Sendable {
    let value: Value
    let payload: Data
    let linkHeader: String?
    let etag: String?
    let lastModified: String?
    let ssoHeader: GitHubSSOHeader?

    init(
        value: Value,
        payload: Data,
        linkHeader: String? = nil,
        etag: String?,
        lastModified: String?,
        ssoHeader: GitHubSSOHeader?
    ) {
        self.value = value
        self.payload = payload
        self.linkHeader = linkHeader
        self.etag = etag
        self.lastModified = lastModified
        self.ssoHeader = ssoHeader
    }
}

enum GitHubRESTClientError: Error, Equatable, Sendable {
    case invalidJSON
    case missingServerDate
}

actor GitHubRESTClient {
    private let transport: GitHubRESTTransport
    private let credential: SecretValue
    private let rateLimitController: GitHubRateLimitController?
    private let requestPriority: GitHubRequestPriority

    init(
        transport: GitHubRESTTransport,
        credential: SecretValue,
        rateLimitController: GitHubRateLimitController? = nil,
        requestPriority: GitHubRequestPriority = .selectedOrganizationRefresh
    ) {
        self.transport = transport
        self.credential = credential
        self.rateLimitController = rateLimitController
        self.requestPriority = requestPriority
    }

    func get<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: GitHubRESTRequest
    ) async throws -> Value {
        try await getResponse(type, request: request).value
    }

    func getResponse<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: GitHubRESTRequest
    ) async throws -> GitHubResponse<Value> {
        let response = try await send(request)
        if let failure = GitHubFailureClassifier.classify(response) {
            GitHubDiagnostics.record(failure)
            throw failure
        }
        do {
            return GitHubResponse(
                value: try JSONDecoder.github.decode(Value.self, from: response.body),
                payload: response.body,
                linkHeader: response.header(named: "Link"),
                etag: response.header(named: "ETag"),
                lastModified: response.header(named: "Last-Modified"),
                ssoHeader: GitHubSSOHeader(value: response.header(named: "X-GitHub-SSO"))
            )
        } catch {
            throw GitHubRESTClientError.invalidJSON
        }
    }

    func getPage<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: GitHubRESTRequest
    ) async throws -> GitHubPage<Value> {
        let response = try await send(request)
        if let failure = GitHubFailureClassifier.classify(response) {
            GitHubDiagnostics.record(failure)
            throw failure
        }
        do {
            return GitHubPage(
                values: try JSONDecoder.github.decode([Value].self, from: response.body),
                payload: response.body,
                nextPageURL: GitHubLinkHeader(response.header(named: "Link"))?.nextPageURL,
                linkHeader: response.header(named: "Link"),
                etag: response.header(named: "ETag"),
                lastModified: response.header(named: "Last-Modified"),
                ssoHeader: GitHubSSOHeader(value: response.header(named: "X-GitHub-SSO"))
            )
        } catch {
            throw GitHubRESTClientError.invalidJSON
        }
    }

    func serverTime() async throws -> Date {
        let response = try await send(GitHubRESTRequest(path: "/rate_limit"))
        if let failure = GitHubFailureClassifier.classify(response) {
            GitHubDiagnostics.record(failure)
            throw failure
        }
        guard let value = response.header(named: "Date"),
              let date = Self.parseHTTPDate(value)
        else {
            throw GitHubRESTClientError.missingServerDate
        }
        return date
    }

    private func send(_ request: GitHubRESTRequest) async throws -> GitHubRESTResponse {
        let resource: GitHubRateLimitResource = request.isSearchRequest ? .search : .core
        guard let rateLimitController else {
            return try await transport.send(request, credential: credential)
        }
        return try await rateLimitController.execute(
            resource: resource,
            priority: requestPriority
        ) {
            let response = try await self.transport.send(request, credential: self.credential)
            try await rateLimitController.record(response: response, fallbackResource: resource)
            return response
        }
    }

    private nonisolated static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

private extension GitHubRESTRequest {
    var isSearchRequest: Bool {
        pathForClassification == "/search/issues"
    }
}

private extension JSONDecoder {
    static var github: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct GitHubLinkHeader: Equatable, Sendable {
    let nextPageURL: URL?
    let isWellFormed: Bool

    init?(_ value: String?) {
        guard let value, !value.isEmpty else { return nil }
        guard let links = Self.parse(value) else {
            nextPageURL = nil
            isWellFormed = false
            return
        }
        let nextURLs = links.filter(\.isNext).map(\.url)
        guard nextURLs.count <= 1 else {
            nextPageURL = nil
            isWellFormed = false
            return
        }
        nextPageURL = nextURLs.first
        isWellFormed = true
    }

    private static func parse(_ value: String) -> [ParsedLink]? {
        let components = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        var links = [ParsedLink]()
        for component in components {
            let fields = component.split(separator: ";", omittingEmptySubsequences: false)
            guard let target = fields.first?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  target.first == "<",
                  target.last == ">",
                  let url = URL(string: String(target.dropFirst().dropLast())),
                  url.scheme == "https",
                  url.host?.caseInsensitiveCompare("api.github.com") == .orderedSame,
                  fields.count > 1
            else {
                return nil
            }
            var relations = Set<String>()
            for rawParameter in fields.dropFirst() {
                let parameter = rawParameter.trimmingCharacters(in: .whitespacesAndNewlines)
                let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = pair.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rawValue = pair.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard pair.count == 2, !name.isEmpty, !rawValue.isEmpty else {
                    return nil
                }
                let isQuoted = rawValue.first == "\"" || rawValue.last == "\""
                guard !isQuoted || (rawValue.first == "\"" && rawValue.last == "\"" && rawValue.count >= 2)
                else {
                    return nil
                }
                if name.caseInsensitiveCompare("rel") == .orderedSame {
                    let relationValue = isQuoted
                        ? String(rawValue.dropFirst().dropLast())
                        : rawValue
                    guard !relationValue.isEmpty else {
                        return nil
                    }
                    relations.formUnion(
                        relationValue.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
                    )
                }
            }
            links.append(ParsedLink(url: url, isNext: relations.contains("next")))
        }
        return links
    }

    private struct ParsedLink: Sendable {
        let url: URL
        let isNext: Bool
    }
}
