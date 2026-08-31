import XCTest
@testable import Triage

final class GitHubRESTTransportTests: XCTestCase {
    func testProductionSessionConfigurationDisablesPersistenceAndConnectivityWaiting() {
        let configuration = TriageHTTPSessionFactory.makeConfiguration()

        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testTransportBuildsAReadOnlyAuthenticatedGitHubRequest() async throws {
        let session = RecordingSession()
        let transport = try GitHubRESTTransport(session: session)
        let request = try GitHubRESTRequest(
            path: "/user",
            query: [URLQueryItem(name: "per_page", value: "100")],
            validators: GitHubHTTPValidators(eTag: "\"etag\"", lastModified: nil)
        )

        _ = try await transport.send(request, credential: SecretValue("token"))
        let captured = try await session.request()

        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.absoluteString, "https://api.github.com/user?per_page=100")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "User-Agent"), GitHubRESTTransport.defaultUserAgent)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "If-None-Match"), "\"etag\"")
    }

    func testConditionalHeadersUseETagPrecedenceAndLastModifiedFallback() throws {
        let eTagOnly = try GitHubRESTRequest(
            path: "/user",
            validators: GitHubHTTPValidators(eTag: "\"etag\"", lastModified: nil)
        )
        XCTAssertEqual(eTagOnly.headers["If-None-Match"], "\"etag\"")
        XCTAssertNil(eTagOnly.headers["If-Modified-Since"])

        let lastModifiedOnly = try GitHubRESTRequest(
            path: "/user",
            validators: GitHubHTTPValidators(
                eTag: nil,
                lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"
            )
        )
        XCTAssertNil(lastModifiedOnly.headers["If-None-Match"])
        XCTAssertEqual(
            lastModifiedOnly.headers["If-Modified-Since"],
            "Wed, 21 Oct 2015 07:28:00 GMT"
        )

        let both = try GitHubRESTRequest(
            path: "/user",
            validators: GitHubHTTPValidators(
                eTag: "\"etag\"",
                lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"
            )
        )
        XCTAssertEqual(both.headers["If-None-Match"], "\"etag\"")
        XCTAssertNil(both.headers["If-Modified-Since"])

        let unconditional = try GitHubRESTRequest(path: "/user")
        XCTAssertNil(unconditional.headers["If-None-Match"])
        XCTAssertNil(unconditional.headers["If-Modified-Since"])
    }

    func testConditionalValidatorsRejectMissingUnsafeAndGenericHeaderValues() {
        XCTAssertThrowsError(try GitHubHTTPValidators(eTag: nil, lastModified: nil)) {
            XCTAssertEqual($0 as? GitHubHTTPValidatorError, .missingValidator)
        }
        XCTAssertThrowsError(
            try GitHubHTTPValidators(eTag: "\"etag\"\r\nInjected: true", lastModified: nil)
        ) {
            XCTAssertEqual($0 as? GitHubHTTPValidatorError, .invalidETag)
        }
        XCTAssertThrowsError(
            try GitHubHTTPValidators(eTag: nil, lastModified: "unsafe\u{007f}date")
        ) {
            XCTAssertEqual($0 as? GitHubHTTPValidatorError, .invalidLastModified)
        }
        XCTAssertThrowsError(
            try GitHubRESTRequest(path: "/user", headers: ["if-none-match": "\"etag\""])
        ) {
            XCTAssertEqual(
                $0 as? GitHubTransportError,
                .conditionalHeadersRequireTypedValidator
            )
        }
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

    func testTransportRejectsOversizedFallbackResponse() async throws {
        let session = RecordingSession(
            body: Data(repeating: 0, count: GitHubRESTTransport.maximumResponseBodyBytes + 1)
        )
        let transport = try GitHubRESTTransport(session: session)

        do {
            _ = try await transport.send(try GitHubRESTRequest(path: "/user"), credential: SecretValue("token"))
            XCTFail("Expected response size failure.")
        } catch let error as GitHubTransportError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testTransportRejectsRedirectedFinalResponseOutsideGitHubAPI() async throws {
        for url in [
            URL(string: "https://example.invalid/user")!,
            URL(string: "http://api.github.com/user")!
        ] {
            let transport = try GitHubRESTTransport(
                session: RecordingSession(responseURL: url)
            )

            do {
                _ = try await transport.send(
                    try GitHubRESTRequest(path: "/user"),
                    credential: SecretValue("token")
                )
                XCTFail("A final response outside the GitHub HTTPS API authority must fail closed.")
            } catch let error as GitHubTransportError {
                XCTAssertEqual(error, .invalidResponseAuthority)
            }
        }
    }

    func testTransportAcceptsExactGitHubAPIFinalResponseAuthority() async throws {
        let responseURL = URL(string: "https://api.github.com/user?redirected=true")!
        let transport = try GitHubRESTTransport(
            session: RecordingSession(responseURL: responseURL)
        )

        let response = try await transport.send(
            try GitHubRESTRequest(path: "/user"),
            credential: SecretValue("token")
        )

        XCTAssertEqual(response.url, responseURL)
    }

    func testTransportRejectsNonExactOutboundBaseAuthorityBeforeSending() throws {
        for url in [
            URL(string: "https://api.github.com:444")!,
            URL(string: "https://user@api.github.com")!
        ] {
            XCTAssertThrowsError(
                try GitHubRESTTransport(
                    session: RecordingSession(),
                    baseURL: url
                )
            ) { error in
                XCTAssertEqual(error as? GitHubTransportError, .invalidBaseURL)
            }
        }
    }

    func testRequestRejectsNonExactPaginationAuthorityBeforeSending() {
        for url in [
            URL(string: "https://api.github.com:444/user?page=2")!,
            URL(string: "https://user@api.github.com/user?page=2")!
        ] {
            XCTAssertThrowsError(try GitHubRESTRequest(nextPageURL: url)) { error in
                XCTAssertEqual(error as? GitHubTransportError, .invalidBaseURL)
            }
        }
    }

    func testTransportPropagatesCancellation() async throws {
        let transport = try GitHubRESTTransport(session: CancellingSession())

        do {
            _ = try await transport.send(try GitHubRESTRequest(path: "/user"), credential: SecretValue("token"))
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            return
        }
    }
}

private actor RecordingSession: HTTPSession {
    private var capturedRequest: URLRequest?
    private let headers: [String: String]
    private let body: Data
    private let responseURL: URL?

    init(
        headers: [String: String] = [:],
        body: Data = Data(),
        responseURL: URL? = nil
    ) {
        self.headers = headers
        self.body = body
        self.responseURL = responseURL
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequest = request
        return (
            body,
            HTTPURLResponse(
                url: responseURL ?? request.url!,
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

private struct CancellingSession: HTTPSession {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw CancellationError()
    }
}
