import Foundation

enum GitHubReadMethod: String, Sendable {
    case get = "GET"
    case head = "HEAD"
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
        headers: [String: String] = [:]
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
        self.headers = headers
    }

    init(
        method: GitHubReadMethod = .get,
        nextPageURL: URL,
        headers: [String: String] = [:]
    ) throws {
        guard nextPageURL.scheme == "https", nextPageURL.host == "api.github.com" else {
            throw GitHubTransportError.invalidBaseURL
        }
        self.method = method
        path = nil
        absoluteURL = nextPageURL
        query = []
        self.headers = headers
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
}

protocol GitHubHTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionGitHubHTTPSession: GitHubHTTPSession {
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
}

actor GitHubRESTTransport {
    static let apiVersion = "2026-03-10"
    static let defaultBaseURL = URL(string: "https://api.github.com")!
    static let maximumResponseBodyBytes = 10 * 1_024 * 1_024

    private let session: any GitHubHTTPSession
    private let baseURL: URL
    private let userAgent: String

    init(
        session: any GitHubHTTPSession = URLSessionGitHubHTTPSession(),
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

        let (body, response) = try await session.data(for: urlRequest)
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
}
