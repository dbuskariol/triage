import XCTest
@testable import Triage

final class GitHubRESTTransportTests: XCTestCase {
    func testTransportBuildsAReadOnlyAuthenticatedGitHubRequest() async throws {
        let session = RecordingSession()
        let transport = try GitHubRESTTransport(session: session)
        let request = try GitHubRESTRequest(
            path: "/user",
            query: [URLQueryItem(name: "per_page", value: "100")],
            headers: ["If-None-Match": "\"etag\""]
        )

        _ = try await transport.send(request, credential: SecretValue("token"))
        let captured = try await session.request()

        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.absoluteString, "https://api.github.com/user?per_page=100")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "If-None-Match"), "\"etag\"")
    }

    func testTransportRejectsNonGitHubAndTraversalPaths() async throws {
        XCTAssertThrowsError(
            try GitHubRESTTransport(baseURL: URL(string: "https://example.com")!)
        )
        XCTAssertThrowsError(try GitHubRESTRequest(path: "user"))
        XCTAssertThrowsError(try GitHubRESTRequest(path: "/repos/../user"))
    }

    func testResponseHeadersAreCaseInsensitive() async throws {
        let session = RecordingSession(headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"])
        let transport = try GitHubRESTTransport(session: session)
        let response = try await transport.send(
            try GitHubRESTRequest(method: .head, path: "/orgs/acme"),
            credential: nil
        )

        XCTAssertEqual(response.header(named: "x-github-sso"), "required; url=https://github.com/orgs/acme/sso")
    }
}

private actor RecordingSession: HTTPSession {
    private var capturedRequest: URLRequest?
    private let headers: [String: String]

    init(headers: [String: String] = [:]) {
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequest = request
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }

    func request() throws -> URLRequest {
        guard let capturedRequest else {
            throw GitHubTransportError.unexpectedResponse
        }
        return capturedRequest
    }
}
