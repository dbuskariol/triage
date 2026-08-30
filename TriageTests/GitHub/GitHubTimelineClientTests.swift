import XCTest
@testable import Triage

final class GitHubTimelineClientTests: XCTestCase {
    func testFirstPageSendsConditionalValidatorAndReturnsNotModifiedWithoutInventingEvents() async throws {
        let session = ConditionalTimelineSession()
        let client = GitHubTimelineClient(client: GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token")
        ))

        let result = try await client.firstPage(
            repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
            issueOrPullRequestNumber: 42,
            validators: GitHubHTTPValidators(
                eTag: "\"timeline-v1\"",
                lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"
            )
        )

        guard case let .notModified(ssoHeader) = result else {
            return XCTFail("A 304 response must retain cached source state instead of inventing an empty page.")
        }
        XCTAssertNil(ssoHeader)
        let observedValidator = await session.ifNoneMatch()
        let observedLastModified = await session.ifModifiedSince()
        XCTAssertEqual(observedValidator, "\"timeline-v1\"")
        XCTAssertNil(observedLastModified)
    }

    func testFirstPageUsesLastModifiedFallback() async throws {
        let session = ConditionalTimelineSession()
        let client = GitHubTimelineClient(client: GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token")
        ))

        let result = try await client.firstPage(
            repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
            issueOrPullRequestNumber: 42,
            validators: GitHubHTTPValidators(
                eTag: nil,
                lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"
            )
        )

        guard case .notModified = result else {
            return XCTFail("A Last-Modified-authorized 304 must retain cached source state.")
        }
        let observedETag = await session.ifNoneMatch()
        let observedLastModified = await session.ifModifiedSince()
        XCTAssertNil(observedETag)
        XCTAssertEqual(
            observedLastModified,
            "Wed, 21 Oct 2015 07:28:00 GMT"
        )
    }

    func testFirstPageRejectsUnsolicitedNotModified() async throws {
        let client = GitHubTimelineClient(client: GitHubRESTClient(
            transport: try GitHubRESTTransport(session: ConditionalTimelineSession()),
            credential: SecretValue("token")
        ))

        do {
            _ = try await client.firstPage(
                repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
                issueOrPullRequestNumber: 42
            )
            XCTFail("An unsolicited 304 has no cached timeline authority.")
        } catch let error as GitHubTimelineClientError {
            XCTAssertEqual(error, .unexpectedNotModified)
        }
    }

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

private actor ConditionalTimelineSession: HTTPSession {
    private var observedIfNoneMatch: String?
    private var observedIfModifiedSince: String?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        observedIfNoneMatch = request.value(forHTTPHeaderField: "If-None-Match")
        observedIfModifiedSince = request.value(forHTTPHeaderField: "If-Modified-Since")
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: nil,
                headerFields: [:]
            )!
        )
    }

    func ifNoneMatch() -> String? {
        observedIfNoneMatch
    }

    func ifModifiedSince() -> String? {
        observedIfModifiedSince
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
