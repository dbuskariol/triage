import Foundation
import XCTest
@testable import Triage

final class GitHubPullRequestReviewThreadClientTests: XCTestCase {
    func testFullyPaginatesThreadsAndPerThreadComments() async throws {
        let session = ReviewThreadPagingSession(responses: [
            "TriagePullRequestReviewThreads": [
                response(
                    node: """
                    {"id":"PR_1","reviewThreads":{"nodes":[{"id":"T_1","isResolved":false,"isOutdated":false}],"pageInfo":{"hasNextPage":true,"endCursor":"thread-1"}}}
                    """
                ),
                response(
                    node: """
                    {"id":"PR_1","reviewThreads":{"nodes":[{"id":"T_2","isResolved":true,"isOutdated":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}
                    """
                )
            ],
            "TriagePullRequestReviewThreadComments": [
                response(
                    node: """
                    {"id":"T_1","comments":{"nodes":[\(comment(id: "C_1", author: "U_2"))],"pageInfo":{"hasNextPage":true,"endCursor":"comment-1"}}}
                    """
                ),
                response(
                    node: """
                    {"id":"T_1","comments":{"nodes":[\(comment(id: "C_2", author: "U_1"))],"pageInfo":{"hasNextPage":false,"endCursor":null}}}
                    """
                ),
                response(
                    node: """
                    {"id":"T_2","comments":{"nodes":[\(comment(id: "C_3", author: "U_3"))],"pageInfo":{"hasNextPage":false,"endCursor":null}}}
                    """
                )
            ]
        ])
        let client = GitHubPullRequestReviewThreadClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        let inventory = try await client.allReviewThreads(
            pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!,
            observedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(inventory.records.map(\.nodeID.rawValue), ["T_1", "T_2"])
        XCTAssertEqual(inventory.records[0].comments.map(\.nodeID.rawValue), ["C_1", "C_2"])
        XCTAssertEqual(inventory.rawPages.count, 5)
        XCTAssertEqual(inventory.metrics.pageCount, 5)
        XCTAssertTrue(inventory.rawPages.allSatisfy { !$0.payload.isEmpty })
        let commentRequestAfters = await session.commentRequestAfters()
        XCTAssertEqual(commentRequestAfters, [nil, "comment-1", nil])
    }

    func testRejectsRepeatedThreadCursor() async throws {
        let session = ReviewThreadPagingSession(responses: [
            "TriagePullRequestReviewThreads": [
                response(
                    node: """
                    {"id":"PR_1","reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"repeat"}}}
                    """
                ),
                response(
                    node: """
                    {"id":"PR_1","reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"repeat"}}}
                    """
                )
            ]
        ])
        let client = GitHubPullRequestReviewThreadClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.allReviewThreads(pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!)
        } verify: { error in
            let failure = error as? GitHubPullRequestReviewThreadTraversalFailure
            XCTAssertEqual(failure?.reason, .paginationLoop)
            XCTAssertEqual(failure?.rawPages.count, 2)
            XCTAssertEqual(failure?.rawPages.map(\.requestKey), [
                "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=none",
                "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=cmVwZWF0"
            ])
        }
    }

    func testRejectsAggregateQueryCostAcrossThreadAndCommentPages() async throws {
        let session = ReviewThreadPagingSession(responses: [
            "TriagePullRequestReviewThreads": [
                response(
                    node: """
                    {"id":"PR_1","reviewThreads":{"nodes":[{"id":"T_1","isResolved":false,"isOutdated":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}
                    """,
                    cost: 500
                )
            ],
            "TriagePullRequestReviewThreadComments": [
                response(
                    node: """
                    {"id":"T_1","comments":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}
                    """,
                    cost: 1
                )
            ]
        ])
        let client = GitHubPullRequestReviewThreadClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.allReviewThreads(pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!)
        } verify: { error in
            let failure = error as? GitHubPullRequestReviewThreadTraversalFailure
            XCTAssertEqual(failure?.reason, .queryCostExceeded)
            XCTAssertEqual(failure?.rawPages.count, 2)
        }
    }

    func testRejectsAggregateResponseBytesAcrossThreadAndCommentPages() async throws {
        let session = ReviewThreadPagingSession(responses: [
            "TriagePullRequestReviewThreads": [
                response(
                    node: """
                    {"id":"PR_1","reviewThreads":{"nodes":[{"id":"T_1","isResolved":false,"isOutdated":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}
                    """,
                    paddingBytes: 2 * 1_024 * 1_024
                )
            ],
            "TriagePullRequestReviewThreadComments": [
                response(
                    node: """
                    {"id":"T_1","comments":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}
                    """,
                    paddingBytes: 2 * 1_024 * 1_024
                )
            ]
        ])
        let client = GitHubPullRequestReviewThreadClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.allReviewThreads(pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!)
        } verify: { error in
            let failure = error as? GitHubPullRequestReviewThreadTraversalFailure
            XCTAssertEqual(failure?.reason, .responseByteBudgetExceeded)
            XCTAssertEqual(failure?.rawPages.count, 2)
        }
    }

    func testCancellationAfterResponseDecodeDoesNotReturnInventory() async throws {
        let session = SuspendedReviewThreadPagingSession()
        let client = GitHubPullRequestReviewThreadClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )
        let task = Task {
            try await client.allReviewThreads(pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!)
        }

        await session.waitForRequest()
        task.cancel()
        await session.resume(
            with: response(
                node: """
                {"id":"PR_1","reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}
                """
            )
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await task.value
        } verify: { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testNormalizerRejectsDuplicateComments() throws {
        let payload = GitHubPullRequestReviewThreadPayload.Thread(
            id: "T_1",
            isResolved: false,
            isOutdated: false,
            comments: .init(
                nodes: [
                    commentPayload(id: "C_1"),
                    commentPayload(id: "C_1")
                ],
                pageInfo: .init(hasNextPage: false, endCursor: nil)
            )
        )

        XCTAssertThrowsError(
            try GitHubPullRequestReviewThreadNormalizer.normalize([payload], observedAt: .now)
        ) { error in
            XCTAssertEqual(
                error as? GitHubPullRequestReviewThreadNormalizationError,
                .duplicateCommentID
            )
        }
    }

    func testReviewThreadDocumentsIncludeRateLimit() throws {
        let threads = try GitHubGraphQLQueries.pullRequestReviewThreads().document
        XCTAssertTrue(threads.contains("rateLimit"))
        XCTAssertFalse(threads.contains("comments("))
        XCTAssertTrue(try GitHubGraphQLQueries.pullRequestReviewThreadComments().document.contains("rateLimit"))
    }

    private func commentPayload(id: String) -> GitHubPullRequestReviewThreadPayload.Comment {
        .init(
            id: id,
            body: "Please update",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            url: URL(string: "https://github.com/acme/widget/pull/1#discussion_r1")!,
            author: .init(id: "U_2", login: "reviewer", avatarUrl: nil)
        )
    }
}

private func comment(id: String, author: String) -> String {
    """
    {"id":"\(id)","body":"Please update","createdAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-02T00:00:00Z","url":"https://github.com/acme/widget/pull/1#discussion_r1","author":{"id":"\(author)","login":"reviewer","avatarUrl":null}}
    """
}

private func response(node: String, cost: Int = 1, paddingBytes: Int = 0) -> Data {
    let padding = String(repeating: "x", count: paddingBytes)
    return Data(
        """
        {"data":{"node":\(node),"rateLimit":{"cost":\(cost),"remaining":4999,"resetAt":"2026-01-01T00:00:00Z"},"padding":"\(padding)"}}
        """.utf8
    )
}

private actor ReviewThreadPagingSession: HTTPSession {
    private var responses: [String: [Data]]
    private var recordedCommentRequestAfters = [String?]()

    init(responses: [String: [Data]]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let requestBody = try XCTUnwrap(request.httpBody)
        let operation = try JSONDecoder().decode(Operation.self, from: requestBody)
        if operation.operationName == "TriagePullRequestReviewThreadComments" {
            recordedCommentRequestAfters.append(operation.variables.after)
        }
        guard var pages = responses[operation.operationName], !pages.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let response = pages.removeFirst()
        responses[operation.operationName] = pages
        return (
            response,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    private struct Operation: Decodable {
        let operationName: String
        let variables: Variables
    }

    private struct Variables: Decodable {
        let after: String?
    }

    func commentRequestAfters() -> [String?] {
        recordedCommentRequestAfters
    }
}

private actor SuspendedReviewThreadPagingSession: HTTPSession {
    private var responseContinuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var requestWaiters = [CheckedContinuation<Void, Never>]()
    private var responseURL: URL?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        responseURL = request.url
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
            let waiters = requestWaiters
            requestWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitForRequest() async {
        guard responseContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resume(with payload: Data) {
        guard let responseContinuation, let responseURL else { return }
        self.responseContinuation = nil
        responseContinuation.resume(
            returning: (
                payload,
                HTTPURLResponse(
                    url: responseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
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
