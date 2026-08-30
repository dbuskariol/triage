import Foundation

enum GitHubReadMethod: String, Sendable {
    case get = "GET"
    case head = "HEAD"
}

enum GitHubHTTPValidatorError: Error, Equatable, Sendable {
    case missingValidator
    case invalidETag
    case invalidLastModified
}

/// Conditional metadata for one exact GitHub REST request.
///
/// GitHub ETags are authoritative when available. `Last-Modified` is retained
/// for an explicit `If-Modified-Since` fallback only when no ETag is present.
struct GitHubHTTPValidators: Equatable, Sendable {
    let eTag: String?
    let lastModified: String?

    init(eTag: String?, lastModified: String?) throws {
        guard eTag != nil || lastModified != nil else {
            throw GitHubHTTPValidatorError.missingValidator
        }
        guard Self.isValid(eTag) else {
            throw GitHubHTTPValidatorError.invalidETag
        }
        guard Self.isValid(lastModified) else {
            throw GitHubHTTPValidatorError.invalidLastModified
        }
        self.eTag = eTag
        self.lastModified = lastModified
    }

    fileprivate var headers: [String: String] {
        if let eTag {
            return ["If-None-Match": eTag]
        }
        if let lastModified {
            return ["If-Modified-Since": lastModified]
        }
        return [:]
    }

    private static func isValid(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && value.count <= 2_048
            && !value.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || scalar.value == 0x7f
            }
    }
}

struct GitHubRESTRequest: Sendable {
    let method: GitHubReadMethod
    private let path: String?
    private let absoluteURL: URL?
    private let query: [URLQueryItem]
    let headers: [String: String]

    init(
        method: GitHubReadMethod = .get,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        validators: GitHubHTTPValidators? = nil
    ) throws {
        guard path.hasPrefix("/"),
              !path.split(separator: "/").contains("..")
        else {
            throw GitHubTransportError.invalidPath
        }
        self.method = method
        self.path = path
        absoluteURL = nil
        self.query = query
        self.headers = try Self.merging(headers: headers, validators: validators)
    }

    init(
        method: GitHubReadMethod = .get,
        nextPageURL: URL,
        headers: [String: String] = [:],
        validators: GitHubHTTPValidators? = nil
    ) throws {
        guard nextPageURL.scheme == "https", nextPageURL.host == "api.github.com" else {
            throw GitHubTransportError.invalidBaseURL
        }
        self.method = method
        path = nil
        absoluteURL = nextPageURL
        query = []
        self.headers = try Self.merging(headers: headers, validators: validators)
    }

    func resolvedURL(baseURL: URL) throws -> URL {
        if let absoluteURL {
            return absoluteURL
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path!
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw GitHubTransportError.invalidURL
        }
        return url
    }

    var pathForClassification: String? {
        path ?? absoluteURL?.path
    }

    private static func merging(
        headers: [String: String],
        validators: GitHubHTTPValidators?
    ) throws -> [String: String] {
        guard !headers.keys.contains(where: {
            $0.caseInsensitiveCompare("If-None-Match") == .orderedSame
                || $0.caseInsensitiveCompare("If-Modified-Since") == .orderedSame
        }) else {
            throw GitHubTransportError.conditionalHeadersRequireTypedValidator
        }
        guard let validators else { return headers }
        return headers.merging(validators.headers) { _, validator in validator }
    }
}

struct GitHubRESTResponse: Sendable {
    let statusCode: Int
    let url: URL
    let headers: [String: String]
    let body: Data

    func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

enum GitHubTransportError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidPath
    case invalidURL
    case unexpectedResponse
    case responseTooLarge
    case conditionalHeadersRequireTypedValidator
}

protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol BoundedHTTPSession: HTTPSession {
    func data(
        for request: URLRequest,
        maximumResponseBodyBytes: Int
    ) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPSession: BoundedHTTPSession {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubTransportError.unexpectedResponse
        }
        return (data, httpResponse)
    }

    func data(
        for request: URLRequest,
        maximumResponseBodyBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubTransportError.unexpectedResponse
        }

        var body = Data()
        body.reserveCapacity(min(maximumResponseBodyBytes, 64 * 1_024))
        for try await byte in bytes {
            guard body.count < maximumResponseBodyBytes else {
                throw GitHubTransportError.responseTooLarge
            }
            body.append(byte)
        }
        return (body, httpResponse)
    }
}

actor GitHubRESTTransport {
    static let apiVersion = "2026-03-10"
    static let defaultBaseURL = URL(string: "https://api.github.com")!
    static let maximumResponseBodyBytes = 2 * 1_024 * 1_024

    private let session: any HTTPSession
    private let baseURL: URL
    private let userAgent: String

    init(
        session: any HTTPSession = URLSessionHTTPSession(),
        baseURL: URL = GitHubRESTTransport.defaultBaseURL,
        userAgent: String = "Triage/0.1.0"
    ) throws {
        guard baseURL.scheme == "https", baseURL.host == "api.github.com" else {
            throw GitHubTransportError.invalidBaseURL
        }
        self.session = session
        self.baseURL = baseURL
        self.userAgent = userAgent
    }

    func send(
        _ request: GitHubRESTRequest,
        credential: SecretValue?
    ) async throws -> GitHubRESTResponse {
        let url = try request.resolvedURL(baseURL: baseURL)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let credential {
            urlRequest.setValue(
                "Bearer \(credential.rawValue)",
                forHTTPHeaderField: "Authorization"
            )
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (body, response) = try await boundedData(for: urlRequest)
        guard body.count <= Self.maximumResponseBodyBytes else {
            throw GitHubTransportError.responseTooLarge
        }

        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let name = entry.key as? String else { return }
            result[name] = String(describing: entry.value)
        }
        return GitHubRESTResponse(
            statusCode: response.statusCode,
            url: response.url ?? url,
            headers: headers,
            body: body
        )
    }

    private func boundedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let boundedSession = session as? any BoundedHTTPSession {
            return try await boundedSession.data(
                for: request,
                maximumResponseBodyBytes: Self.maximumResponseBodyBytes
            )
        }
        let result = try await session.data(for: request)
        guard result.0.count <= Self.maximumResponseBodyBytes else {
            throw GitHubTransportError.responseTooLarge
        }
        return result
    }
}
