import XCTest
@testable import Triage

final class GitHubRepositoryTeamClientTests: XCTestCase {
    func testRepositoryInventoryPaginatesAndRetainsRawPages() async throws {
        let nextPage = URL(
            string: "https://api.github.com/orgs/acme/repos?page=2&type=all&per_page=100"
        )!
        let session = RepositoryTeamPagingSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": (
                Data("[\(repository(id: 1, nodeID: "R_1", name: "one"))]".utf8),
                ["Link": "<\(nextPage.absoluteString)>; rel=\"next\""],
                200
            ),
            "/orgs/acme/repos?page=2&type=all&per_page=100": (
                Data("[\(repository(id: 2, nodeID: "R_2", name: "two"))]".utf8),
                [:],
                200
            )
        ])
        let client = try repositoryClient(session: session)

        let inventory = try await client.allRepositories(in: "acme")

        XCTAssertEqual(inventory.values.map(\.nodeID), ["R_1", "R_2"])
        XCTAssertEqual(inventory.pages.map(\.endpoint), [
            "/orgs/acme/repos?type=all&per_page=100",
            "/orgs/acme/repos?page=2&type=all&per_page=100"
        ])
        let requestedURLs = await session.requestedURLs()
        XCTAssertEqual(requestedURLs.last?.absoluteString, nextPage.absoluteString)
    }

    func testRepositoryPaginationRejectsAlteredOrMissingControlParametersBeforeSecondRequest() async throws {
        let invalidLinks = [
            "https://api.github.com/orgs/acme/repos?page=2&type=public&per_page=100",
            "https://api.github.com/orgs/acme/repos?page=2&type=private&per_page=100",
            "https://api.github.com/orgs/acme/repos?type=all&per_page=100",
            "https://api.github.com/orgs/acme/repos?page=2&per_page=100",
            "https://api.github.com/orgs/acme/repos?page=2&type=all",
            "https://api.github.com/orgs/acme/repos?page=2&type=all&type=all&per_page=100",
            "https://api.github.com/orgs/acme/repos?page=2&type=all&per_page=100&per_page=100",
            "https://api.github.com/orgs/acme/repos?page=2&type=all&per_page=99"
        ]
        for link in invalidLinks {
            try await assertInvalidRepositoryNextLink(
                link,
                expectedError: .invalidPaginationLink
            )
        }
    }

    func testRepositoryPaginationRejectsFragmentsUnknownParametersAndInvalidPageValues() async throws {
        let invalidLinks = [
            "https://api.github.com/orgs/acme/repos?page=2&type=all&per_page=100#private",
            "https://api.github.com/orgs/acme/repos?page=2&type=all&per_page=100&visibility=all",
            "https://api.github.com/orgs/acme/repos?page=2&page=3&type=all&per_page=100",
            "https://api.github.com/orgs/acme/repos?page=0&type=all&per_page=100",
            "https://api.github.com/orgs/acme/repos?page=-2&type=all&per_page=100",
            "https://api.github.com/orgs/acme/repos?page=02&type=all&per_page=100"
        ]
        for link in invalidLinks {
            try await assertInvalidRepositoryNextLink(
                link,
                expectedError: .invalidPaginationLink
            )
        }
    }

    func testRepositoryPaginationRejectsRepeatedNonForwardAndOutOfRangePages() async throws {
        for page in ["1", "101"] {
            try await assertInvalidRepositoryNextLink(
                "https://api.github.com/orgs/acme/repos?page=\(page)&type=all&per_page=100",
                expectedError: page == "1" ? .paginationLoop : .paginationLimitExceeded
            )
        }
    }

    func testRepositoryPaginationRejectsCrossScopeTargetsBeforeSecondRequest() async throws {
        let invalidLinks = [
            "https://api.github.com/orgs/other/repos?page=2&type=all&per_page=100",
            "https://api.github.com/orgs/acme/teams?page=2&type=all&per_page=100",
            "https://example.com/orgs/acme/repos?page=2&type=all&per_page=100",
            "http://api.github.com/orgs/acme/repos?page=2&type=all&per_page=100",
            "https://api.github.com:443/orgs/acme/repos?page=2&type=all&per_page=100",
            "https://user@api.github.com/orgs/acme/repos?page=2&type=all&per_page=100"
        ]
        for link in invalidLinks {
            try await assertInvalidRepositoryNextLink(
                link,
                expectedError: .invalidPaginationLink
            )
        }
    }

    func testRepositoryPaginationRejectsARepeatedServerURLBeforeThirdRequest() async throws {
        let nextPage = "https://api.github.com/orgs/acme/repos?page=2&type=all&per_page=100"
        let session = RepositoryTeamPagingSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": (
                Data("[\(repository(id: 1, nodeID: "R_1", name: "one"))]".utf8),
                ["Link": "<\(nextPage)>; rel=\"next\""],
                200
            ),
            "/orgs/acme/repos?page=2&type=all&per_page=100": (
                Data("[\(repository(id: 2, nodeID: "R_2", name: "two"))]".utf8),
                ["Link": "<\(nextPage)>; rel=\"next\""],
                200
            )
        ])
        let client = try repositoryClient(session: session)

        do {
            _ = try await client.allRepositories(in: "acme")
            XCTFail("A repeated next-page URL must not produce an authoritative inventory.")
        } catch {
            XCTAssertEqual(error as? GitHubRepositoryTeamClientError, .paginationLoop)
        }
        let requestCount = await session.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testRepositoryPaginationRejectsANonForwardPageBeforeThirdRequest() async throws {
        let pageThree = "https://api.github.com/orgs/acme/repos?per_page=100&page=3&type=all"
        let pageTwo = "https://api.github.com/orgs/acme/repos?type=all&per_page=100&page=2"
        let session = RepositoryTeamPagingSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": (
                Data("[\(repository(id: 1, nodeID: "R_1", name: "one"))]".utf8),
                ["Link": "<\(pageThree)>; rel=\"next\""],
                200
            ),
            "/orgs/acme/repos?per_page=100&page=3&type=all": (
                Data("[\(repository(id: 3, nodeID: "R_3", name: "three"))]".utf8),
                ["Link": "<\(pageTwo)>; rel=\"next\""],
                200
            )
        ])
        let client = try repositoryClient(session: session)

        do {
            _ = try await client.allRepositories(in: "acme")
            XCTFail("A backward page number must not produce an authoritative inventory.")
        } catch {
            XCTAssertEqual(error as? GitHubRepositoryTeamClientError, .paginationLoop)
        }
        let requestCount = await session.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testTeamMembershipTreatsNotFoundAsUnknownVisibility() async throws {
        let client = GitHubRepositoryTeamClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(
                    session: RepositoryTeamPagingSession(responses: [
                        "/orgs/acme/teams/triage/memberships/octocat": (Data(), [:], 404)
                    ])
                ),
                credential: SecretValue("token")
            )
        )
        let membership = try await client.membership(
            in: "acme",
            teamSlug: "triage",
            accountLogin: "octocat"
        )

        guard case .unknown = membership else {
            return XCTFail("Expected an ambiguous 404 to remain unknown.")
        }
    }

    func testRepositoryFetchUsesETagPrecedenceAndPreservesNotModifiedState() async throws {
        let session = RepositoryTeamPagingSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": (Data(), [:], 304)
        ])
        let client = GitHubRepositoryTeamClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: session),
                credential: SecretValue("token")
            )
        )

        let result = try await client.fetchRepositories(
            in: "acme",
            validators: GitHubHTTPValidators(
                eTag: "\"inventory-v1\"",
                lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"
            )
        )

        guard case .notModified = result else {
            return XCTFail("A 304 must not be interpreted as an empty inventory.")
        }
        let ifNoneMatch = await session.header(named: "If-None-Match")
        XCTAssertEqual(ifNoneMatch, "\"inventory-v1\"")
        let ifModifiedSince = await session.header(named: "If-Modified-Since")
        XCTAssertNil(ifModifiedSince)
    }

    func testRepositoryFetchUsesLastModifiedFallback() async throws {
        let session = RepositoryTeamPagingSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": (Data(), [:], 304)
        ])
        let client = GitHubRepositoryTeamClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: session),
                credential: SecretValue("token")
            )
        )

        let result = try await client.fetchRepositories(
            in: "acme",
            validators: GitHubHTTPValidators(
                eTag: nil,
                lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"
            )
        )

        guard case .notModified = result else {
            return XCTFail("A conditional 304 must preserve cached inventory.")
        }
        let ifNoneMatch = await session.header(named: "If-None-Match")
        let ifModifiedSince = await session.header(named: "If-Modified-Since")
        XCTAssertNil(ifNoneMatch)
        XCTAssertEqual(
            ifModifiedSince,
            "Wed, 21 Oct 2015 07:28:00 GMT"
        )
    }

    func testRepositoryFetchRejectsUnsolicitedNotModified() async throws {
        let client = GitHubRepositoryTeamClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(
                    session: RepositoryTeamPagingSession(responses: [
                        "/orgs/acme/repos?type=all&per_page=100": (Data(), [:], 304)
                    ])
                ),
                credential: SecretValue("token")
            )
        )

        do {
            _ = try await client.fetchRepositories(in: "acme", validators: nil)
            XCTFail("An unsolicited 304 has no cached-state authority.")
        } catch let error as GitHubRepositoryTeamClientError {
            XCTAssertEqual(error, .notModifiedWithoutCachedState)
        }
    }

    func testRepositoryNotModifiedPreservesAuthorizationRequiredSSOHeader() async throws {
        let recoveryURL = URL(string: "https://github.com/orgs/acme/sso")!
        let session = RepositoryTeamPagingSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": (
                Data(),
                ["X-GitHub-SSO": "required; url=\(recoveryURL.absoluteString)"],
                304
            )
        ])
        let client = try repositoryClient(session: session)

        let result = try await client.fetchRepositories(
            in: "acme",
            validators: GitHubHTTPValidators(
                eTag: "\"inventory-v1\"",
                lastModified: nil
            )
        )

        guard case let .notModified(ssoHeader) = result else {
            return XCTFail("A conditional 304 must preserve its SSO header.")
        }
        XCTAssertEqual(ssoHeader, GitHubSSOHeader.authorizationRequired(recoveryURL))
    }

    func testTeamNotModifiedPreservesPartialResultsSSOHeader() async throws {
        let session = RepositoryTeamPagingSession(responses: [
            "/orgs/acme/teams?per_page=100": (
                Data(),
                ["X-GitHub-SSO": "partial-results; organizations=1,2"],
                304
            )
        ])
        let client = try repositoryClient(session: session)

        let result = try await client.fetchTeams(
            in: "acme",
            validators: GitHubHTTPValidators(
                eTag: "\"teams-v1\"",
                lastModified: nil
            )
        )

        guard case let .notModified(ssoHeader) = result else {
            return XCTFail("A conditional 304 must preserve its SSO header.")
        }
        XCTAssertEqual(ssoHeader, GitHubSSOHeader.partialResults(Set([1, 2])))
    }

    private func repository(id: UInt64, nodeID: String, name: String) -> String {
        """
        {"id":\(id),"node_id":"\(nodeID)","name":"\(name)","private":true,"archived":false,
        "has_discussions":true,"html_url":"https://github.com/acme/\(name)",
        "updated_at":"2025-01-01T00:00:00Z","owner":{"login":"acme"}}
        """
    }

    private func assertInvalidRepositoryNextLink(
        _ nextLink: String,
        expectedError: GitHubRepositoryTeamClientError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let session = RepositoryTeamPagingSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": (
                Data("[]".utf8),
                ["Link": "<\(nextLink)>; rel=\"next\""],
                200
            )
        ])
        let client = try repositoryClient(session: session)

        do {
            _ = try await client.allRepositories(in: "acme")
            XCTFail(
                "An invalid next-page link must not produce an authoritative inventory: \(nextLink)",
                file: file,
                line: line
            )
        } catch {
            XCTAssertEqual(
                error as? GitHubRepositoryTeamClientError,
                expectedError,
                "Unexpected error for \(nextLink)",
                file: file,
                line: line
            )
        }
        let requestCount = await session.requestCount()
        XCTAssertEqual(requestCount, 1, file: file, line: line)
    }

    private func repositoryClient(
        session: RepositoryTeamPagingSession
    ) throws -> GitHubRepositoryTeamClient {
        GitHubRepositoryTeamClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: session),
                credential: SecretValue("token")
            )
        )
    }

}

private actor RepositoryTeamPagingSession: HTTPSession {
    private let responses: [String: (Data, [String: String], Int)]
    private var headers = [[String: String]]()
    private var capturedURLs = [URL]()

    init(responses: [String: (Data, [String: String], Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        capturedURLs.append(url)
        let key = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard let response = responses[key] else {
            throw URLError(.resourceUnavailable)
        }
        headers.append(request.allHTTPHeaderFields ?? [:])
        return (
            response.0,
            HTTPURLResponse(
                url: url,
                statusCode: response.2,
                httpVersion: nil,
                headerFields: response.1
            )!
        )
    }

    func header(named name: String) -> String? {
        headers.last?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func requestCount() -> Int {
        capturedURLs.count
    }

    func requestedURLs() -> [URL] {
        capturedURLs
    }
}
