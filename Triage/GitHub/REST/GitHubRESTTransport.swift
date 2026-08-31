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
    /// Source-specific decoded body ceiling. Most REST sources use the shared
    /// 2 MiB contract limit, while a few smaller endpoints have stricter caps.
    let maximumResponseBodyBytes: Int

    init(
        method: GitHubReadMethod = .get,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        validators: GitHubHTTPValidators? = nil,
        maximumResponseBodyBytes: Int = GitHubRESTTransport.maximumResponseBodyBytes
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
        guard maximumResponseBodyBytes > 0,
              maximumResponseBodyBytes <= GitHubRESTTransport.maximumResponseBodyBytes
        else { throw GitHubTransportError.invalidResponseBodyLimit }
        self.maximumResponseBodyBytes = maximumResponseBodyBytes
    }

    init(
        method: GitHubReadMethod = .get,
        nextPageURL: URL,
        headers: [String: String] = [:],
        validators: GitHubHTTPValidators? = nil,
        maximumResponseBodyBytes: Int = GitHubRESTTransport.maximumResponseBodyBytes
    ) throws {
        // Link headers are remote input. Reject every non-exact authority
        // before this URL can reach URLRequest and receive an Authorization
        // header in the transport.
        guard GitHubAPIResponseAuthority.isValid(nextPageURL) else {
            throw GitHubTransportError.invalidBaseURL
        }
        self.method = method
        path = nil
        absoluteURL = nextPageURL
        query = []
        self.headers = try Self.merging(headers: headers, validators: validators)
        guard maximumResponseBodyBytes > 0,
              maximumResponseBodyBytes <= GitHubRESTTransport.maximumResponseBodyBytes
        else { throw GitHubTransportError.invalidResponseBodyLimit }
        self.maximumResponseBodyBytes = maximumResponseBodyBytes
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
    case invalidResponseAuthority
    case unexpectedResponse
    case responseTooLarge
    case invalidResponseBodyLimit
    case conditionalHeadersRequireTypedValidator
}

/// Responses must remain on the same HTTPS GitHub API authority as the
/// request. This is checked after every request as a fail-closed backstop for
/// injected sessions and for any redirect behavior outside our session delegate.
enum GitHubAPIResponseAuthority {
    static func isValid(_ url: URL?) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              components.host?.caseInsensitiveCompare("api.github.com") == .orderedSame,
              components.port == nil,
              components.user == nil,
              components.password == nil
        else {
            return false
        }
        return true
    }
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

/// Creates isolated transport sessions for every production GitHub and OAuth
/// request path. Callers that need deterministic behavior continue to inject an
/// `HTTPSession` directly.
enum TriageHTTPSessionFactory {
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func makeSession() -> URLSession {
        URLSession(
            configuration: makeConfiguration(),
            delegate: GitHubRedirectAuthorityDelegate(),
            delegateQueue: nil
        )
    }
}

private final class GitHubRedirectAuthorityDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // The session factory is also used for GitHub OAuth requests, which do
        // not start at the REST API authority. Restrict only redirects for API
        // requests; the final-response checks remain the injected-session
        // backstop for REST and GraphQL.
        guard GitHubAPIResponseAuthority.isValid(task.originalRequest?.url) else {
            completionHandler(request)
            return
        }
        completionHandler(GitHubAPIResponseAuthority.isValid(request.url) ? request : nil)
    }
}

struct URLSessionHTTPSession: BoundedHTTPSession {
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? TriageHTTPSessionFactory.makeSession()
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
    static let defaultUserAgent = "Triage/0.1.0"
    static let defaultBaseURL = URL(string: "https://api.github.com")!
    static let maximumResponseBodyBytes = 2 * 1_024 * 1_024

    private let session: any HTTPSession
    private let baseURL: URL
    private let userAgent: String

    init(
        session: any HTTPSession = URLSessionHTTPSession(),
        baseURL: URL = GitHubRESTTransport.defaultBaseURL,
        userAgent: String = GitHubRESTTransport.defaultUserAgent
    ) throws {
        // Keep the configured base authority subject to the identical policy
        // as response and pagination URLs. A post-response check is too late
        // because the request has already carried the caller's credential.
        guard GitHubAPIResponseAuthority.isValid(baseURL) else {
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

        let (body, response) = try await boundedData(
            for: urlRequest,
            maximumResponseBodyBytes: request.maximumResponseBodyBytes
        )
        guard GitHubAPIResponseAuthority.isValid(response.url) else {
            throw GitHubTransportError.invalidResponseAuthority
        }
        guard body.count <= request.maximumResponseBodyBytes else {
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

    private func boundedData(
        for request: URLRequest,
        maximumResponseBodyBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        if let boundedSession = session as? any BoundedHTTPSession {
            return try await boundedSession.data(
                for: request,
                maximumResponseBodyBytes: maximumResponseBodyBytes
            )
        }
        let result = try await session.data(for: request)
        guard result.0.count <= maximumResponseBodyBytes else {
            throw GitHubTransportError.responseTooLarge
        }
        return result
    }
}
