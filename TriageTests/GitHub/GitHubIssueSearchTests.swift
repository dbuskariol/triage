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

    func testBuildsVisibleTeamReviewRequestSearch() throws {
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .teamReviewRequested(
                teamNodeID: GitHubNodeID(rawValue: "T_1")!,
                teamSlug: "mac-apps"
            )
        )

        XCTAssertEqual(
            query.value,
            "org:github is:open team-review-requested:github/mac-apps"
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
                userLogin: "octocat",
                state: .open,
                relationship: .teamReviewRequested(
                    teamNodeID: GitHubNodeID(rawValue: "T_1")!,
                    teamSlug: "Mac Apps"
                )
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
            "org:github is:closed reviewed-by:octocat updated:1970-01-01T00:01:00Z..1970-01-01T00:02:00Z closed:>=1970-01-01"
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

        XCTAssertTrue(response.value.items.isEmpty)
        XCTAssertEqual(response.ssoHeader, .partialResults(Set([1])))
    }

    func testConditionalSearchSendsETagAndReturnsSSOBearingNotModified() async throws {
        let session = SearchSession(
            body: Data(),
            headers: ["X-GitHub-SSO": "partial-results; organizations=1"],
            statusCode: 304
        )
        let client = GitHubIssueSearchClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: session),
                credential: SecretValue("token")
            )
        )
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )

        let result = try await client.searchResult(
            query,
            page: 2,
            ifNoneMatch: "\"search-v1\""
        )

        guard case let .notModified(ssoHeader) = result else {
            return XCTFail("Expected a 304 to remain an explicit not-modified result.")
        }
        XCTAssertEqual(ssoHeader, .partialResults(Set([1])))
        let recordedRequest = await session.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"search-v1\"")
        XCTAssertEqual(request.url?.path, "/search/issues")
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.queryItems?.first { $0.name == "page" }?.value, "2")
    }

    func testSearchRequestIdentityIsExactAndRevisionScoped() throws {
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let scope = SynchronizationScope(
            accountID: AccountID(rawValue: "account-1")!,
            organizationID: OrganizationID(rawValue: "organization-1")!,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )

        let first = try GitHubIssueSearchRequestIdentity(query: query, page: 1, scope: scope)
        let same = try GitHubIssueSearchRequestIdentity(query: query, page: 1, scope: scope)
        let laterPage = try GitHubIssueSearchRequestIdentity(query: query, page: 2, scope: scope)
        let newCredential = try GitHubIssueSearchRequestIdentity(
            query: query,
            page: 1,
            scope: SynchronizationScope(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                credentialRevision: CredentialRevision(rawValue: "credential-2")!,
                capabilityRevision: scope.capabilityRevision
            )
        )
        let newCapability = try GitHubIssueSearchRequestIdentity(
            query: query,
            page: 1,
            scope: SynchronizationScope(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: CapabilityRevision(rawValue: "capability-2")!
            )
        )
        let otherOrganization = try GitHubIssueSearchRequestIdentity(
            query: query,
            page: 1,
            scope: SynchronizationScope(
                accountID: scope.accountID,
                organizationID: OrganizationID(rawValue: "organization-2")!,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision
            )
        )

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first.requestKey, laterPage.requestKey)
        XCTAssertNotEqual(first.requestKey, newCredential.requestKey)
        XCTAssertNotEqual(first.requestKey, newCapability.requestKey)
        XCTAssertNotEqual(first.requestKey, otherOrganization.requestKey)
        XCTAssertTrue(first.endpoint.contains("sort=updated"))
        XCTAssertTrue(first.endpoint.contains("order=desc"))
        XCTAssertTrue(first.endpoint.contains("per_page=100"))
        XCTAssertTrue(first.endpoint.contains("page=1"))
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
    private let statusCode: Int
    private var recordedRequest: URLRequest?

    init(body: Data, headers: [String: String], statusCode: Int = 200) {
        self.body = body
        self.headers = headers
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        recordedRequest = request
        return (
            body,
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }

    func lastRequest() -> URLRequest? {
        recordedRequest
    }
}
