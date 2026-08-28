import XCTest
@testable import Triage

final class GitHubIdentityClientTests: XCTestCase {
    func testOrganizationInventoryPaginatesDeduplicatesAndAggregatesSSOHeaders() async throws {
        let secondPage = URL(string: "https://api.github.com/user/orgs?page=2")!
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/user/orgs": (
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
                    "/user/orgs": (
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
        {"id":1,"node_id":"R_1","name":"one","private":true,"archived":false,
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
        XCTAssertEqual(inventory.ssoHeader, .partialResults(Set([1, 2])))
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
