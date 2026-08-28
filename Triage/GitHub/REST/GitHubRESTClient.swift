import Foundation

struct GitHubPage<Value: Sendable>: Sendable {
    let values: [Value]
    let nextPageURL: URL?
    let etag: String?
    let lastModified: String?
    let ssoHeader: GitHubSSOHeader?
}

struct GitHubResponse<Value: Sendable>: Sendable {
    let value: Value
    let payload: Data
    let etag: String?
    let lastModified: String?
    let ssoHeader: GitHubSSOHeader?
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
                nextPageURL: GitHubLinkHeader(response.header(named: "Link"))?.nextPageURL,
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

    init?(_ value: String?) {
        guard let value, !value.isEmpty else { return nil }

        let values = value.split(separator: ",", omittingEmptySubsequences: true)
        let nextURLs: [URL] = values.compactMap { component in
            let parts = component.split(separator: ";", maxSplits: 1)
            guard parts.count == 2,
                  parts[1].contains(#"rel="next""#)
            else {
                return nil
            }
            let urlString = parts[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: urlString)
        }
        nextPageURL = nextURLs.first
    }
}
