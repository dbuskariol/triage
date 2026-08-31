import XCTest
@testable import Triage

final class GitHubPullRequestClientTests: XCTestCase {
    func testReviewInventoryPaginatesDeduplicatesAndAggregatesSSOHeaders() async throws {
        let secondPage = URL(string: "https://api.github.com/repos/acme/widget/pulls/42/reviews?per_page=100&page=2")!
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
                    "/repos/acme/widget/pulls/42/reviews?per_page=100&page=2": (
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
        XCTAssertEqual(inventory.pages.count, 2)
        XCTAssertTrue(inventory.pages.allSatisfy { !$0.payload.isEmpty })
        XCTAssertEqual(inventory.ssoHeader, .partialResults(Set([1, 2])))
    }

    func testRejectedCrossRepositoryPaginationRetainsCurrentRawPage() async throws {
        let crossRepositoryPage = URL(
            string: "https://api.github.com/repos/acme/other/pulls/42/reviews?per_page=100&page=2"
        )!
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PullRequestPagingSession(responses: [
                    "/repos/acme/widget/pulls/42/reviews?per_page=100": (
                        Data("[]".utf8),
                        ["Link": "<\(crossRepositoryPage.absoluteString)>; rel=\"next\""]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let result = try await GitHubPullRequestClient(client: client).allReviewsPreservingFailure(
            repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
            number: 42
        )

        guard case let .failure(failure) = result else {
            return XCTFail("Expected cross-repository pagination to fail closed.")
        }
        XCTAssertEqual(failure.rawPages.count, 1)
        XCTAssertEqual(
            failure.rawPages[0].requestKey,
            "GET /repos/acme/widget/pulls/42/reviews?per_page=100"
        )
        guard case .pagination = failure.terminalFailure else {
            return XCTFail("Expected pagination classification.")
        }
    }

    func testMalformed2xxReviewPageRetainsRawPayloadAndValidators() async throws {
        let payload = Data(#"[{"id":"not-a-number"}]"#.utf8)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PullRequestPagingSession(responses: [
                    "/repos/acme/widget/pulls/42/reviews?per_page=100": (
                        payload,
                        ["ETag": "review-etag", "Last-Modified": "Mon, 01 Jan 2024 00:00:00 GMT"]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let result = try await GitHubPullRequestClient(client: client).allReviewsPreservingFailure(
            repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
            number: 42
        )

        guard case let .failure(failure) = result else {
            return XCTFail("Expected malformed 2xx response to fail closed.")
        }
        guard case .malformedResponse = failure.terminalFailure else {
            return XCTFail("Expected malformed response classification.")
        }
        XCTAssertEqual(failure.rawPages.count, 1)
        XCTAssertEqual(failure.rawPages[0].payload, payload)
        XCTAssertEqual(failure.rawPages[0].eTag, "review-etag")
        XCTAssertEqual(failure.rawPages[0].lastModified, "Mon, 01 Jan 2024 00:00:00 GMT")
    }

    func testPaginationRequiresTheImmediateNextPage() async throws {
        let skippedPage = URL(
            string: "https://api.github.com/repos/acme/widget/pulls/42/reviews?per_page=100&page=3"
        )!
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PullRequestPagingSession(responses: [
                    "/repos/acme/widget/pulls/42/reviews?per_page=100": (
                        Data("[]".utf8),
                        ["Link": "<\(skippedPage.absoluteString)>; rel=\"next\""]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let result = try await GitHubPullRequestClient(client: client).allReviewsPreservingFailure(
            repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
            number: 42
        )
        guard case let .failure(failure) = result,
              case .pagination = failure.terminalFailure
        else { return XCTFail("Expected skipped page to fail closed.") }
        XCTAssertEqual(failure.rawPages.count, 1)
    }

    func testPaginationRejectsNonCanonicalHostBeforeFollowingIt() async throws {
        let foreignHostPage = URL(
            string: "https://github.example.invalid/repos/acme/widget/pulls/42/reviews?per_page=100&page=2"
        )!
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PullRequestPagingSession(responses: [
                    "/repos/acme/widget/pulls/42/reviews?per_page=100": (
                        Data("[]".utf8),
                        ["Link": "<\(foreignHostPage.absoluteString)>; rel=\"next\""]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let result = try await GitHubPullRequestClient(client: client).allReviewsPreservingFailure(
            repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
            number: 42
        )
        guard case let .failure(failure) = result,
              case .pagination = failure.terminalFailure
        else { return XCTFail("Expected noncanonical host to fail closed.") }
        XCTAssertEqual(failure.rawPages.count, 1)
    }

    func testRequestedReviewersStopsAtIts256KiBTransportBudget() async throws {
        let payload = Data(
            ("{\"users\":[],\"teams\":[],\"padding\":\""
                + String(repeating: "x", count: 256 * 1_024)
                + "\"}").utf8
        )
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PullRequestPagingSession(responses: [
                    "/repos/acme/widget/pulls/42/requested_reviewers": (payload, [:])
                ])
            ),
            credential: SecretValue("token")
        )

        do {
            _ = try await GitHubPullRequestClient(client: client).requestedReviewers(
                repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
                number: 42
            )
            XCTFail("Expected the transport payload budget to fail closed.")
        } catch {
            XCTAssertEqual(error as? GitHubTransportError, .responseTooLarge)
        }
    }

    func testDirectReviewsRejectsA101ObjectPage() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PullRequestPagingSession(responses: [
                    "/repos/acme/widget/pulls/42/reviews?per_page=100": (reviewPayload(count: 101), [:])
                ])
            ),
            credential: SecretValue("token")
        )

        do {
            _ = try await GitHubPullRequestClient(client: client).reviews(
                repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
                number: 42
            )
            XCTFail("Expected an over-limit review page to fail closed.")
        } catch {
            XCTAssertEqual(error as? GitHubPullRequestClientError, .pageObjectLimitExceeded)
        }
    }

    func testReviewTraversalRejectsA101ObjectPageAndRetainsRawEvidence() async throws {
        let secondPage = URL(
            string: "https://api.github.com/repos/acme/widget/pulls/42/reviews?per_page=100&page=2"
        )!
        let payload = reviewPayload(count: 101)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PullRequestPagingSession(responses: [
                    "/repos/acme/widget/pulls/42/reviews?per_page=100": (
                        reviewPayload(count: 1),
                        ["Link": "<\(secondPage.absoluteString)>; rel=\"next\""]
                    ),
                    "/repos/acme/widget/pulls/42/reviews?per_page=100&page=2": (
                        payload,
                        ["ETag": "review-etag"]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let result = try await GitHubPullRequestClient(client: client).allReviewsPreservingFailure(
            repository: try GitHubRepositoryPath(owner: "acme", repository: "widget"),
            number: 42
        )

        guard case let .failure(failure) = result else {
            return XCTFail("Expected an over-limit review traversal to fail closed.")
        }
        guard case .malformedResponse = failure.terminalFailure else {
            return XCTFail("Expected malformed-response failure classification.")
        }
        XCTAssertEqual(failure.rawPages.count, 2)
        XCTAssertEqual(failure.rawPages[1].payload, payload)
        XCTAssertEqual(failure.rawPages[1].eTag, "review-etag")
    }

    private func reviewPayload(count: Int) -> Data {
        let reviews = (0 ..< count).map { index in
            "{\"id\":\(index + 1),\"node_id\":\"R_\(index + 1)\",\"state\":\"APPROVED\",\"body\":null,\"submitted_at\":\"2025-01-01T00:00:00Z\"}"
        }.joined(separator: ",")
        return Data(("[" + reviews + "]").utf8)
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
