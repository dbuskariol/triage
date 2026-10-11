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

struct GitHubUndecodablePage: Equatable, Sendable {
    let payload: Data
    let linkHeader: String?
    let etag: String?
    let lastModified: String?
    let ssoHeader: GitHubSSOHeader?
}

enum GitHubPageDecodingResult<Value: Sendable>: Sendable {
    case page(GitHubPage<Value>)
    case undecodable(GitHubUndecodablePage)
}

struct GitHubResponse<Value: Sendable>: Sendable {
    let value: Value
    let payload: Data
    let linkHeader: String?
    let etag: String?
    let lastModified: String?
    let ssoHeader: GitHubSSOHeader?
    /// When the credential that made the request expires, if it does.
    let credentialExpiresAt: Date?
    let source: GitHubResponseSource

    init(
        value: Value,
        payload: Data,
        linkHeader: String? = nil,
        etag: String?,
        lastModified: String?,
        ssoHeader: GitHubSSOHeader?,
        credentialExpiresAt: Date? = nil,
        source: GitHubResponseSource = .network
    ) {
        self.credentialExpiresAt = credentialExpiresAt
        self.value = value
        self.payload = payload
        self.linkHeader = linkHeader
        self.etag = etag
        self.lastModified = lastModified
        self.ssoHeader = ssoHeader
        self.source = source
    }
}

enum GitHubResponseSource: Equatable, Sendable {
    case network
    case replay(RawAPISnapshotID)
}

struct GitHubUndecodableResponse: Equatable, Sendable {
    let payload: Data
    let linkHeader: String?
    let etag: String?
    let lastModified: String?
    let ssoHeader: GitHubSSOHeader?
}

enum GitHubResponseDecodingResult<Value: Sendable>: Sendable {
    case response(GitHubResponse<Value>)
    case undecodable(GitHubUndecodableResponse)
}

enum GitHubRESTClientError: Error, Equatable, Sendable {
    case outsidePersonalWorkScope
    case invalidJSON
    case responseTooLarge
}

actor GitHubRESTClient {
    private let transport: GitHubRESTTransport
    private let credential: SecretValue
    private let rateLimitController: GitHubRateLimitController?
    private let requestPriority: GitHubRequestPriority
    private let personalWorkOnly: Bool

    init(
        transport: GitHubRESTTransport,
        credential: SecretValue,
        rateLimitController: GitHubRateLimitController? = nil,
        requestPriority: GitHubRequestPriority = .selectedOrganizationRefresh,
        personalWorkOnly: Bool = false
    ) {
        self.transport = transport
        self.credential = credential
        self.rateLimitController = rateLimitController
        self.requestPriority = requestPriority
        self.personalWorkOnly = personalWorkOnly
    }

    func get<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: GitHubRESTRequest
    ) async throws -> Value {
        try await getResponse(type, request: request).value
    }

    func getResponse<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: GitHubRESTRequest,
        maximumPayloadBytes: Int? = nil
    ) async throws -> GitHubResponse<Value> {
        switch try await getResponsePreservingUndecodablePayload(
            type,
            request: request,
            maximumPayloadBytes: maximumPayloadBytes
        ) {
        case let .response(response):
            return response
        case .undecodable:
            throw GitHubRESTClientError.invalidJSON
        }
    }

    func getResponsePreservingUndecodablePayload<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: GitHubRESTRequest,
        maximumPayloadBytes: Int? = nil
    ) async throws -> GitHubResponseDecodingResult<Value> {
        let response = try await send(request)
        if let failure = GitHubFailureClassifier.classify(response) {
            GitHubDiagnostics.record(failure)
            throw failure
        }
        if let maximumPayloadBytes, response.body.count > maximumPayloadBytes {
            throw GitHubRESTClientError.responseTooLarge
        }
        do {
            return .response(
                GitHubResponse(
                    value: try JSONDecoder.github.decode(Value.self, from: response.body),
                    payload: response.body,
                    linkHeader: response.header(named: "Link"),
                    etag: response.header(named: "ETag"),
                    lastModified: response.header(named: "Last-Modified"),
                    ssoHeader: GitHubSSOHeader(value: response.header(named: "X-GitHub-SSO")),
                    credentialExpiresAt: GitHubCredentialObservation.expirationDate(
                        from: response.header(named: GitHubCredentialObservation.expirationHeader)
                    )
                )
            )
        } catch {
            return .undecodable(
                GitHubUndecodableResponse(
                    payload: response.body,
                    linkHeader: response.header(named: "Link"),
                    etag: response.header(named: "ETag"),
                    lastModified: response.header(named: "Last-Modified"),
                    ssoHeader: GitHubSSOHeader(value: response.header(named: "X-GitHub-SSO"))
                )
            )
        }
    }

    func getPage<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: GitHubRESTRequest
    ) async throws -> GitHubPage<Value> {
        switch try await getPagePreservingUndecodablePayload(type, request: request) {
        case let .page(page):
            return page
        case .undecodable:
            throw GitHubRESTClientError.invalidJSON
        }
    }

    func getPagePreservingUndecodablePayload<Value: Decodable & Sendable>(
        _ type: Value.Type,
        request: GitHubRESTRequest
    ) async throws -> GitHubPageDecodingResult<Value> {
        let response = try await send(request)
        if let failure = GitHubFailureClassifier.classify(response) {
            GitHubDiagnostics.record(failure)
            throw failure
        }
        do {
            return .page(
                GitHubPage(
                    values: try JSONDecoder.github.decode([Value].self, from: response.body),
                    payload: response.body,
                    nextPageURL: GitHubLinkHeader(response.header(named: "Link"))?.nextPageURL,
                    linkHeader: response.header(named: "Link"),
                    etag: response.header(named: "ETag"),
                    lastModified: response.header(named: "Last-Modified"),
                    ssoHeader: GitHubSSOHeader(value: response.header(named: "X-GitHub-SSO"))
                )
            )
        } catch {
            return .undecodable(
                GitHubUndecodablePage(
                    payload: response.body,
                    linkHeader: response.header(named: "Link"),
                    etag: response.header(named: "ETag"),
                    lastModified: response.header(named: "Last-Modified"),
                    ssoHeader: GitHubSSOHeader(value: response.header(named: "X-GitHub-SSO"))
                )
            )
        }
    }

    private func send(_ request: GitHubRESTRequest) async throws -> GitHubRESTResponse {
        let trace = GitHubRequestTrace(operation: GitHubRequestTrace.restCategory(path: request.pathForClassification))
        do {
            let response = try await sendWithRetries(request)
            trace.finish(statusCode: response.statusCode, bytes: response.body.count)
            return response
        } catch {
            trace.fail(error)
            throw error
        }
    }

    private func sendWithRetries(_ request: GitHubRESTRequest) async throws -> GitHubRESTResponse {
        if personalWorkOnly {
            guard let path = request.pathForClassification else { throw GitHubRESTClientError.outsidePersonalWorkScope }
            let parts = path.split(separator: "/")
            let broadCollections: Set<String> = ["repos", "teams", "projects", "members", "public_members", "outside_collaborators"]
            let isBroadCollection = parts.count == 3
                && ["orgs", "organizations", "users"].contains(String(parts[0]))
                && broadCollections.contains(String(parts[2]))
            guard !isBroadCollection, !["/user/repos", "/repositories", "/organizations", "/users"].contains(path) else {
                throw GitHubRESTClientError.outsidePersonalWorkScope
            }
        }
        let resource: GitHubRateLimitResource = request.isSearchRequest ? .search : .core
        guard let rateLimitController else {
            return try await transport.send(request, credential: credential)
        }
        var retriesRemaining = 2
        while true {
            let response: GitHubRESTResponse
            do {
                response = try await rateLimitController.execute(
                    resource: resource,
                    priority: requestPriority
                ) {
                    let response = try await self.transport.send(request, credential: self.credential)
                    try await rateLimitController.record(response: response, fallbackResource: resource)
                    return response
                }
            } catch let error as URLError where retriesRemaining > 0
                && [.cancelled, .networkConnectionLost, .timedOut].contains(error.code) {
                try Task.checkCancellation()
                retriesRemaining -= 1
                GitHubDiagnostics.recordReadRetry(code: error.code.rawValue)
                try await Task.sleep(for: .seconds(1))
                continue
            }
            let failureKind = GitHubFailureClassifier.classify(response)?.kind
            guard retriesRemaining > 0,
                  failureKind == .secondaryRateLimited || failureKind == .rateLimited,
                  await rateLimitController.pauseUntil(for: resource) != nil
            else { return response }
            // Reacquiring the permit honors the recorded account-wide pause.
            // Keep the original page request instead of restarting discovery.
            retriesRemaining -= 1
        }
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
