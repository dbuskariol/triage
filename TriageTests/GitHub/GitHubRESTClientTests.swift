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
                "Last-Modified": "Tue, 01 Sep 2026 00:00:00 GMT"
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

    func testNextPageMustRemainOnGitHubAPI() {
        XCTAssertThrowsError(
            try GitHubRESTRequest(
                nextPageURL: URL(string: "https://example.com/user/orgs?page=2")!
            )
        )
    }
}

private struct OrganizationDTO: Codable, Equatable, Sendable {
    let id: UInt64
    let login: String
}

private actor StubSession: GitHubHTTPSession {
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
