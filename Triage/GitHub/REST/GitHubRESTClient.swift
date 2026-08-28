import Foundation

struct GitHubPage<Value: Sendable>: Sendable {
    let values: [Value]
    let nextPageURL: URL?
    let etag: String?
    let lastModified: String?
}

struct GitHubResponse<Value: Sendable>: Sendable {
    let value: Value
    let etag: String?
    let lastModified: String?
    let ssoHeader: GitHubSSOHeader?
}

enum GitHubRESTClientError: Error, Equatable, Sendable {
    case invalidJSON
}

actor GitHubRESTClient {
    private let transport: GitHubRESTTransport
    private let credential: SecretValue

    init(
        transport: GitHubRESTTransport,
        credential: SecretValue
    ) {
        self.transport = transport
        self.credential = credential
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
        let response = try await transport.send(request, credential: credential)
        if let failure = GitHubFailureClassifier.classify(response) {
            GitHubDiagnostics.record(failure)
            throw failure
        }
        do {
            return GitHubResponse(
                value: try JSONDecoder.github.decode(Value.self, from: response.body),
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
        let response = try await transport.send(request, credential: credential)
        if let failure = GitHubFailureClassifier.classify(response) {
            GitHubDiagnostics.record(failure)
            throw failure
        }
        do {
            return GitHubPage(
                values: try JSONDecoder.github.decode([Value].self, from: response.body),
                nextPageURL: GitHubLinkHeader(response.header(named: "Link"))?.nextPageURL,
                etag: response.header(named: "ETag"),
                lastModified: response.header(named: "Last-Modified")
            )
        } catch {
            throw GitHubRESTClientError.invalidJSON
        }
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
