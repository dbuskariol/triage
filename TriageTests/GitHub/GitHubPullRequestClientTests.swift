import XCTest
@testable import Triage

final class GitHubPullRequestClientTests: XCTestCase {
    func testReviewInventoryPaginatesDeduplicatesAndAggregatesSSOHeaders() async throws {
        let secondPage = URL(string: "https://api.github.com/repos/acme/widget/pulls/42/reviews?page=2")!
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PullRequestPagingSession(responses: [
                    "/repos/acme/widget/pulls/42/reviews?per_page=100": (
                        Data(#"[{"id":1,"node_id":"R_1","state":"APPROVED","body":null,"submitted_at":"2025-01-01T00:00:00Z"}]"#.utf8),
                        [
                            "Link": "<\(secondPage.absoluteString)>; rel=\"next\"",
                            "X-GitHub-SSO": "partial-results; organizations=1"
                        ]
                    ),
                    "/repos/acme/widget/pulls/42/reviews?page=2": (
                        Data(#"[{"id":1,"node_id":"R_1","state":"APPROVED","body":null,"submitted_at":"2025-01-01T00:00:00Z"},{"id":2,"node_id":"R_2","state":"CHANGES_REQUESTED","body":"Please revise","submitted_at":"2025-01-02T00:00:00Z"}]"#.utf8),
                        ["X-GitHub-SSO": "partial-results; organizations=2"]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let inventory = try await GitHubPullRequestClient(client: client).allReviews(
            repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
            number: 42
        )

        XCTAssertEqual(inventory.reviews.map(\.nodeID), ["R_1", "R_2"])
        XCTAssertEqual(inventory.ssoHeader, .partialResults(Set([1, 2])))
    }
}

private actor PullRequestPagingSession: HTTPSession {
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
