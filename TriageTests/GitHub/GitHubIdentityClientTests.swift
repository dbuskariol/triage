import XCTest
@testable import Triage

final class GitHubIdentityClientTests: XCTestCase {
    func testAuthenticatedUserRejectsRevokedAndMalformedIdentityWithoutYieldingAProfile() async throws {
        let revokedSession = IdentityFixtureSession(responses: [
            "/user": .init(statusCode: 401, body: Data(#"{"message":"Bad credentials"}"#.utf8))
        ])
        let revokedClient = try identityClient(session: revokedSession)

        do {
            _ = try await GitHubIdentityClient(client: revokedClient).authenticatedUser()
            XCTFail("A revoked credential must not yield a replacement profile.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.kind, .unauthorized)
        }
        let revokedPaths = await revokedSession.requestedPaths()
        XCTAssertEqual(revokedPaths, ["/user"])

        let malformedSession = IdentityFixtureSession(responses: [
            "/user": .init(statusCode: 200, body: Data(#"{"id":"not-a-number"}"#.utf8))
        ])
        let malformedClient = try identityClient(session: malformedSession)

        do {
            _ = try await GitHubIdentityClient(client: malformedClient).authenticatedUser()
            XCTFail("An invalid identity payload must not yield a profile to overwrite local state.")
        } catch let error as GitHubRESTClientError {
            XCTAssertEqual(error, .invalidJSON)
        }
        let malformedPaths = await malformedSession.requestedPaths()
        XCTAssertEqual(malformedPaths, ["/user"])
    }

    func testEmptyOrganizationPageIsASuccessfulInventoryRatherThanNegativeEvidence() async throws {
        let session = IdentityFixtureSession(responses: [
            "/user/orgs?per_page=100": .init(statusCode: 200, body: Data("[]".utf8))
        ])
        let client = try identityClient(session: session)

        let page = try await GitHubIdentityClient(client: client).organizations()

        XCTAssertTrue(page.values.isEmpty)
        XCTAssertNil(page.nextPageURL)
        XCTAssertNil(page.ssoHeader)
        let requestedPaths = await session.requestedPaths()
        XCTAssertEqual(requestedPaths, ["/user/orgs?per_page=100"])
    }

    func testSelectedOrganizationSSOAndApprovalFailuresRemainScopedToThatOrganization() async throws {
        let ssoSession = IdentityFixtureSession(responses: [
            "/orgs/acme": .init(
                statusCode: 403,
                body: Data(#"{"message":"SSO required"}"#.utf8),
                headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"]
            ),
            "/orgs/other": .init(
                statusCode: 200,
                body: Data(#"{"id":2,"node_id":"O_2","login":"other"}"#.utf8)
            )
        ])
        let ssoClient = try identityClient(session: ssoSession)
        let identity = GitHubIdentityClient(client: ssoClient)

        do {
            _ = try await identity.organization(named: "acme")
            XCTFail("SSO must block only the selected organization request.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.kind, .forbidden)
            XCTAssertEqual(
                failure.ssoHeader,
                .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso")!)
            )
        }
        let other = try await identity.organization(named: "other")
        XCTAssertEqual(other.value.login, "other")
        let ssoPaths = await ssoSession.requestedPaths()
        XCTAssertEqual(ssoPaths, ["/orgs/acme", "/orgs/other"])

        let approvalSession = IdentityFixtureSession(responses: [
            "/orgs/acme": .init(
                statusCode: 403,
                body: Data(#"{"message":"Personal access token pending approval"}"#.utf8)
            )
        ])
        let approvalClient = try identityClient(session: approvalSession)

        do {
            _ = try await GitHubIdentityClient(client: approvalClient).organization(named: "acme")
            XCTFail("Organization approval must remain an explicit access failure.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.accessRestriction, .organizationApprovalRequired)
        }
        let approvalPaths = await approvalSession.requestedPaths()
        XCTAssertEqual(approvalPaths, ["/orgs/acme"])
    }

    func testOrganizationInventoryPaginatesDeduplicatesAndAggregatesSSOHeaders() async throws {
        let secondPage = URL(string: "https://api.github.com/user/orgs?page=2")!
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/user/orgs?per_page=100": (
                        Data(#"[{"id":1,"node_id":"O_1","login":"first"}]"#.utf8),
                        [
                            "Link": "<\(secondPage.absoluteString)>; rel=\"next\"",
                            "X-GitHub-SSO": "partial-results; organizations=1"
                        ]
                    ),
                    "/user/orgs?page=2": (
                        Data(#"[{"id":1,"node_id":"O_1","login":"first-renamed"},{"id":2,"node_id":"O_2","login":"second"}]"#.utf8),
                        ["X-GitHub-SSO": "partial-results; organizations=2"]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let inventory = try await GitHubIdentityClient(client: client).allOrganizations()

        XCTAssertEqual(inventory.organizations.map(\.id), [1, 2])
        XCTAssertEqual(inventory.organizations.map(\.login), ["first", "second"])
        XCTAssertEqual(inventory.ssoHeader, .partialResults(Set([1, 2])))
    }

    func testOrganizationInventoryRejectsPaginationLoops() async throws {
        let loopURL = URL(string: "https://api.github.com/user/orgs?page=2")!
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/user/orgs?per_page=100": (
                        Data(#"[{"id":1,"node_id":"O_1","login":"first"}]"#.utf8),
                        ["Link": "<\(loopURL.absoluteString)>; rel=\"next\""]
                    ),
                    "/user/orgs?page=2": (
                        Data(#"[{"id":2,"node_id":"O_2","login":"second"}]"#.utf8),
                        ["Link": "<\(loopURL.absoluteString)>; rel=\"next\""]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: client).allOrganizations()
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .paginationLoop)
        }
    }

    func testRepositoryInventoryRetainsSSOHeadersAcrossPages() async throws {
        let secondPage = URL(string: "https://api.github.com/orgs/acme/repos?page=2")!
        let repository = """
        {"id":1,"node_id":"R_1","name":"one","private":true,"archived":false,"has_discussions":true,
        "html_url":"https://github.com/acme/one","updated_at":"2025-01-01T00:00:00Z",
        "owner":{"login":"acme"}}
        """
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/orgs/acme/repos?type=all&per_page=100": (
                        Data("[\(repository)]".utf8),
                        [
                            "Link": "<\(secondPage.absoluteString)>; rel=\"next\"",
                            "X-GitHub-SSO": "partial-results; organizations=1"
                        ]
                    ),
                    "/orgs/acme/repos?page=2": (
                        Data("[\(repository.replacingOccurrences(of: "\"R_1\"", with: "\"R_2\""))]".utf8),
                        ["X-GitHub-SSO": "partial-results; organizations=2"]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let inventory = try await GitHubIdentityClient(client: client).allRepositories(in: "acme")

        XCTAssertEqual(inventory.repositories.map(\.nodeID), ["R_1", "R_2"])
        XCTAssertTrue(inventory.repositories.allSatisfy { $0.hasDiscussions == true })
        XCTAssertEqual(inventory.ssoHeader, .partialResults(Set([1, 2])))
    }

    func testRepositoryInventoryAcceptsAnOmittedDiscussionsField() async throws {
        let repository = """
        [{"id":1,"node_id":"R_1","name":"one","private":true,"archived":false,
        "html_url":"https://github.com/acme/one","updated_at":"2025-01-01T00:00:00Z",
        "owner":{"login":"acme"}}]
        """
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/orgs/acme/repos?type=all&per_page=100": (Data(repository.utf8), [:])
                ])
            ),
            credential: SecretValue("token")
        )

        let inventory = try await GitHubIdentityClient(client: client).allRepositories(in: "acme")

        XCTAssertEqual(inventory.repositories.map(\.hasDiscussions), [nil])
    }

    private func identityClient(session: IdentityFixtureSession) throws -> GitHubRESTClient {
        GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token")
        )
    }
}

private actor IdentityFixtureSession: HTTPSession {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    private let responses: [String: Response]
    private var paths = [String]()

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let path = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard let response = responses[path] else { throw URLError(.resourceUnavailable) }
        paths.append(path)
        return (
            response.body,
            HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
            )!
        )
    }

    func requestedPaths() -> [String] {
        paths
    }
}

private actor PagingSession: HTTPSession {
    private let responses: [String: (Data, [String: String])]

    init(responses: [String: (Data, [String: String])]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let pathAndQuery = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard let response = responses[pathAndQuery] else {
            throw URLError(.resourceUnavailable)
        }
        return (
            response.0,
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: response.1
            )!
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        verify(error)
    }
}
