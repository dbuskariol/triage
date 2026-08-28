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

    func testSearchCreatesPreciselyBoundedUpdatedRange() throws {
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .closed,
            relationship: .reviewInvolves,
            closedAfter: Date(timeIntervalSince1970: 0)
        ).bounded(
            to: SearchTimeRange(
                start: Date(timeIntervalSince1970: 60),
                end: Date(timeIntervalSince1970: 120)
            )
        )

        XCTAssertEqual(
            query.value,
            "org:github is:closed review-involves:octocat updated:1970-01-01T00:01:00Z..1970-01-01T00:02:00Z closed:>=1970-01-01"
        )
    }

    func testSearchRejectsConflictingUpdatedConstraints() {
        XCTAssertThrowsError(
            try GitHubIssueSearchQuery(
                organizationLogin: "github",
                userLogin: "octocat",
                state: .open,
                relationship: .involves,
                updatedAfter: Date(timeIntervalSince1970: 0),
                updatedRange: SearchTimeRange(
                    start: Date(timeIntervalSince1970: 60),
                    end: Date(timeIntervalSince1970: 120)
                )
            )
        ) { error in
            XCTAssertEqual(error as? GitHubIssueSearchError, .conflictingUpdatedConstraints)
        }
    }

    func testSearchScopesBoundedQueryToAccessibleRepository() throws {
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        ).scoped(
            to: "github/triage.app_test",
            updatedRange: SearchTimeRange(
                start: Date(timeIntervalSince1970: 60),
                end: Date(timeIntervalSince1970: 120)
            )
        )

        XCTAssertEqual(
            query.value,
            "org:github is:open involves:octocat updated:1970-01-01T00:01:00Z..1970-01-01T00:02:00Z repo:github/triage.app_test"
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

    func testServerTimeUsesGitHubDateHeader() async throws {
        let expected = Date(timeIntervalSince1970: 0)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: SearchSession(
                    body: Data(),
                    headers: ["Date": "Thu, 01 Jan 1970 00:00:00 GMT"]
                )
            ),
            credential: SecretValue("token")
        )

        let serverTime = try await client.serverTime()

        XCTAssertEqual(serverTime, expected)
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
