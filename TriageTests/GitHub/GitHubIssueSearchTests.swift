import XCTest
@testable import Triage

final class GitHubIssueSearchTests: XCTestCase {
    func testBuildsRoleQualifiedOpenSearch() throws {
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .reviewRequested
        )

        XCTAssertEqual(
            query.value,
            "org:github is:open review-requested:octocat"
        )
    }

    func testSearchRejectsUntrustedQualifierInputs() {
        XCTAssertThrowsError(
            try GitHubIssueSearchQuery(
                organizationLogin: "github org",
                userLogin: "octocat",
                state: .open,
                relationship: .involves
            )
        )
        XCTAssertThrowsError(
            try GitHubIssueSearchQuery(
                organizationLogin: "github",
                userLogin: "octocat is:closed",
                state: .open,
                relationship: .involves
            )
        )
    }

    func testSearchResponseRetainsSuccessfulSSOHeader() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: SearchSession(
                    body: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8),
                    headers: ["X-GitHub-SSO": "partial-results; organizations=1"]
                )
            ),
            credential: SecretValue("token")
        )
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )

        let response = try await GitHubIssueSearchClient(client: client).searchResponse(query)

        XCTAssertEqual(response.value.items, [])
        XCTAssertEqual(response.ssoHeader, .partialResults(Set([1])))
    }
}

private actor SearchSession: HTTPSession {
    private let body: Data
    private let headers: [String: String]

    init(body: Data, headers: [String: String]) {
        self.body = body
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        return (
            body,
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }
}
