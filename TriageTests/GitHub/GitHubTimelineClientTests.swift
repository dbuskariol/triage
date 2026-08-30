import XCTest
@testable import Triage

final class GitHubTimelineClientTests: XCTestCase {
    func testAllTimelineUsesLinkPaginationAndPreservesEvents() async throws {
        let secondPage = URL(
            string: "https://api.github.com/repos/acme/widget/issues/42/timeline?page=2"
        )!
        let client = GitHubTimelineClient(client: GitHubRESTClient(
            transport: try GitHubRESTTransport(session: TimelinePagingSession(responses: [
                "/repos/acme/widget/issues/42/timeline?per_page=100&page=1": (
                    Data(#"[{"id":1,"event":"assigned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["Link": "<\(secondPage)>; rel=\"next\"", "ETag": "\"timeline-v1\""]
                ),
                "/repos/acme/widget/issues/42/timeline?page=2": (
                    Data(#"[{"id":"2","event":"mentioned","created_at":"2026-01-02T00:00:00Z"}]"#.utf8),
                    [:]
                )
            ])),
            credential: SecretValue("token")
        ))

        let inventory = try await client.allTimeline(
            repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
            issueOrPullRequestNumber: 42
        )

        XCTAssertEqual(inventory.events.map(\.id), ["1", "2"])
        XCTAssertEqual(inventory.pages.count, 2)
        XCTAssertEqual(inventory.pages.first?.etag, "\"timeline-v1\"")
    }

    func testAllTimelineRejectsLinkPaginationLoop() async throws {
        let loopingPage = URL(
            string: "https://api.github.com/repos/acme/widget/issues/42/timeline?page=2"
        )!
        let client = GitHubTimelineClient(client: GitHubRESTClient(
            transport: try GitHubRESTTransport(session: TimelinePagingSession(responses: [
                "/repos/acme/widget/issues/42/timeline?per_page=100&page=1": (
                    Data(#"[{"id":1,"event":"assigned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["Link": "<\(loopingPage)>; rel=\"next\""]
                ),
                "/repos/acme/widget/issues/42/timeline?page=2": (
                    Data(#"[{"id":2,"event":"assigned","created_at":"2026-01-02T00:00:00Z"}]"#.utf8),
                    ["Link": "<\(loopingPage)>; rel=\"next\""]
                )
            ])),
            credential: SecretValue("token")
        ))

        await XCTAssertThrowsErrorAsync {
            _ = try await client.allTimeline(
                repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
                issueOrPullRequestNumber: 42
            )
        } verify: { error in
            XCTAssertEqual(error as? GitHubTimelineClientError, .paginationLoop)
        }
    }

    func testAllTimelineRejectsCrossRepositoryPaginationLink() async throws {
        let foreignPage = "https://api.github.com/repos/acme/other/issues/42/timeline?page=2"
        let client = GitHubTimelineClient(client: GitHubRESTClient(
            transport: try GitHubRESTTransport(session: TimelinePagingSession(responses: [
                "/repos/acme/widget/issues/42/timeline?per_page=100&page=1": (
                    Data(#"[{"id":1,"event":"assigned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["Link": "<\(foreignPage)>; rel=\"next\""]
                )
            ])),
            credential: SecretValue("token")
        ))

        await XCTAssertThrowsErrorAsync {
            _ = try await client.allTimeline(
                repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
                issueOrPullRequestNumber: 42
            )
        } verify: { error in
            XCTAssertEqual(error as? GitHubTimelineClientError, .invalidPaginationLink)
        }
    }
}

private actor TimelinePagingSession: HTTPSession {
    private let responses: [String: (Data, [String: String])]

    init(responses: [String: (Data, [String: String])]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let pathAndQuery = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard let response = responses[pathAndQuery] else { throw URLError(.resourceUnavailable) }
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
