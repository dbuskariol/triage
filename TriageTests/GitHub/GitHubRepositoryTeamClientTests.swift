import XCTest
@testable import Triage

final class GitHubRepositoryTeamClientTests: XCTestCase {
    func testRepositoryInventoryPaginatesAndRetainsRawPages() async throws {
        let nextPage = URL(string: "https://api.github.com/orgs/acme/repos?page=2")!
        let client = GitHubRepositoryTeamClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(
                    session: RepositoryTeamPagingSession(responses: [
                        "/orgs/acme/repos?type=all&per_page=100": (
                            Data("[\(repository(id: 1, nodeID: "R_1", name: "one"))]".utf8),
                            ["Link": "<\(nextPage.absoluteString)>; rel=\"next\""],
                            200
                        ),
                        "/orgs/acme/repos?page=2": (
                            Data("[\(repository(id: 2, nodeID: "R_2", name: "two"))]".utf8),
                            [:],
                            200
                        )
                    ])
                ),
                credential: SecretValue("token")
            )
        )

        let inventory = try await client.allRepositories(in: "acme")

        XCTAssertEqual(inventory.values.map(\.nodeID), ["R_1", "R_2"])
        XCTAssertEqual(inventory.pages.map(\.endpoint), [
            "/orgs/acme/repos?type=all&per_page=100",
            "/orgs/acme/repos?page=2"
        ])
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

    func testRepositoryFetchSendsCachedETagAndPreservesNotModifiedState() async throws {
        let session = RepositoryTeamPagingSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": (Data(), [:], 304)
        ])
        let client = GitHubRepositoryTeamClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: session),
                credential: SecretValue("token")
            )
        )

        let result = try await client.fetchRepositories(in: "acme", eTag: "\"inventory-v1\"")

        guard case .notModified = result else {
            return XCTFail("A 304 must not be interpreted as an empty inventory.")
        }
        let ifNoneMatch = await session.header(named: "If-None-Match")
        XCTAssertEqual(ifNoneMatch, "\"inventory-v1\"")
    }

    private func repository(id: UInt64, nodeID: String, name: String) -> String {
        """
        {"id":\(id),"node_id":"\(nodeID)","name":"\(name)","private":true,"archived":false,
        "has_discussions":true,"html_url":"https://github.com/acme/\(name)",
        "updated_at":"2025-01-01T00:00:00Z","owner":{"login":"acme"}}
        """
    }
}

private actor RepositoryTeamPagingSession: HTTPSession {
    private let responses: [String: (Data, [String: String], Int)]
    private var headers = [[String: String]]()

    init(responses: [String: (Data, [String: String], Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
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
}
