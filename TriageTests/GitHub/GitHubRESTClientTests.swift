import XCTest
@testable import Triage

final class GitHubRESTClientTests: XCTestCase {
    func testClientDecodesAPageAndPreservesGitHubNextLink() async throws {
        let nextPage = "https://api.github.com/user/orgs?page=2"
        let session = StubSession(
            body: Data(#"[{"id":1,"login":"github"}]"#.utf8),
            headers: [
                "Link": "<\(nextPage)>; rel=\"next\", <https://api.github.com/user/orgs?page=3>; rel=\"last\"",
                "ETag": "\"etag\"",
                "Last-Modified": "Tue, 01 Sep 2026 00:00:00 GMT",
                "X-GitHub-SSO": "partial-results; organizations=21955855"
            ]
        )
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token")
        )

        let page = try await client.getPage(
            OrganizationDTO.self,
            request: try GitHubRESTRequest(path: "/user/orgs")
        )

        XCTAssertEqual(page.values, [OrganizationDTO(id: 1, login: "github")])
        XCTAssertEqual(page.nextPageURL?.absoluteString, nextPage)
        XCTAssertEqual(page.etag, "\"etag\"")
        XCTAssertEqual(page.lastModified, "Tue, 01 Sep 2026 00:00:00 GMT")
        XCTAssertEqual(page.ssoHeader, .partialResults(Set([21_955_855])))
    }

    func testClientDoesNotExposePrivateErrorBodies() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: StubSession(statusCode: 401, body: Data(#"{"message":"private"}"#.utf8))
            ),
            credential: SecretValue("token")
        )

        do {
            _ = try await client.get(
                OrganizationDTO.self,
                request: try GitHubRESTRequest(path: "/user")
            )
            XCTFail("Expected authentication failure.")
        } catch let error as GitHubFailure {
            XCTAssertEqual(error.kind, .unauthorized)
            XCTAssertEqual(error.statusCode, 401)
        }
    }

    func testClientPreservesSuccessfulRawPayloadForProvenance() async throws {
        let payload = Data(#"{"id":1,"login":"github"}"#.utf8)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: StubSession(body: payload)),
            credential: SecretValue("token")
        )

        let response = try await client.getResponse(
            OrganizationDTO.self,
            request: try GitHubRESTRequest(path: "/user")
        )

        XCTAssertEqual(response.value, OrganizationDTO(id: 1, login: "github"))
        XCTAssertEqual(response.payload, payload)
    }

    func testNextPageMustRemainOnGitHubAPI() {
        XCTAssertThrowsError(
            try GitHubRESTRequest(
                nextPageURL: URL(string: "https://example.com/user/orgs?page=2")!
            )
        )
    }

    func testClientRejectsMalformedPayloadWithoutReturningAnEmptyPage() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: StubSession(body: Data("{".utf8))),
            credential: SecretValue("token")
        )

        do {
            _ = try await client.getPage(
                OrganizationDTO.self,
                request: try GitHubRESTRequest(path: "/user/orgs")
            )
            XCTFail("Expected malformed response failure.")
        } catch let error as GitHubRESTClientError {
            XCTAssertEqual(error, .invalidJSON)
        }
    }

    func testProvenancePageAPIPreservesMalformedPayloadWithoutExposingItAsAnError() async throws {
        let payload = Data(#"{"token":"ghp_privateMalformedPayload""#.utf8)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: StubSession(
                body: payload,
                headers: [
                    "ETag": "malformed-etag",
                    "Last-Modified": "Tue, 01 Sep 2026 00:00:00 GMT"
                ]
            )),
            credential: SecretValue("token")
        )

        let result = try await client.getPagePreservingUndecodablePayload(
            OrganizationDTO.self,
            request: GitHubRESTRequest(path: "/user/orgs")
        )

        guard case let .undecodable(page) = result else {
            return XCTFail("Malformed JSON must remain distinguishable from an authoritative empty page.")
        }
        XCTAssertEqual(page.payload, payload)
        XCTAssertEqual(page.etag, "malformed-etag")
        XCTAssertEqual(page.lastModified, "Tue, 01 Sep 2026 00:00:00 GMT")
    }

    func testProvenanceResponseAPIPreservesMalformedPayloadWithoutTreatingItAsEmpty() async throws {
        let payload = Data(#"{"token":"ghp_privateMalformedResponse""#.utf8)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: StubSession(
                body: payload,
                headers: [
                    "ETag": "malformed-response-etag",
                    "Last-Modified": "Tue, 01 Sep 2026 00:00:00 GMT"
                ]
            )),
            credential: SecretValue("token")
        )

        let result = try await client.getResponsePreservingUndecodablePayload(
            OrganizationDTO.self,
            request: GitHubRESTRequest(path: "/user")
        )

        guard case let .undecodable(response) = result else {
            return XCTFail("Malformed JSON must remain distinguishable from an authoritative object.")
        }
        XCTAssertEqual(response.payload, payload)
        XCTAssertEqual(response.etag, "malformed-response-etag")
        XCTAssertEqual(response.lastModified, "Tue, 01 Sep 2026 00:00:00 GMT")
    }
}

private struct OrganizationDTO: Codable, Equatable, Sendable {
    let id: UInt64
    let login: String
}

private actor StubSession: HTTPSession {
    private let statusCode: Int
    private let body: Data
    private let headers: [String: String]

    init(
        statusCode: Int = 200,
        body: Data = Data(),
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }
}
