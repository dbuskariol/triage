import Foundation
import XCTest
@testable import Triage

final class GitHubPullRequestStatusCheckClientTests: XCTestCase {
    func testPaginatesExactPullRequestRollupAndPreservesRequiredFailure() async throws {
        let session = StatusCheckSession(responses: [
            payload(nodes: """
                {"__typename":"CheckRun","id":"CHECK_1","name":"build","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-08-31T00:00:00Z","isRequired":true}
                """, hasNextPage: true, cursor: "next"),
            payload(nodes: """
                {"__typename":"StatusContext","id":"STATUS_1","context":"legacy","state":"SUCCESS","updatedAt":"2026-08-31T00:01:00Z","isRequired":false}
                """, hasNextPage: false, cursor: nil)
        ])
        let client = GitHubPullRequestStatusCheckClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        let inventory = try await client.allStatusChecks(
            pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!
        )
        XCTAssertEqual(inventory.mergeableState, "MERGEABLE")
        XCTAssertEqual(inventory.checks.map(\.state), [.failure, .success])
        XCTAssertEqual(inventory.checks.map(\.isRequired), [true, false])
        XCTAssertEqual(inventory.rawPages.count, 2)
        let observedAfters = await session.afters()
        XCTAssertEqual(observedAfters, [nil, "next"])
    }

    func testRejectsPartialResponseRatherThanTreatingItAsAnEmptyRollup() async throws {
        let session = StatusCheckSession(responses: [
            Data(#"{"data":{"node":{"id":"PR_1","mergeable":"MERGEABLE","statusCheckRollup":{"contexts":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}},"rateLimit":{"cost":1,"remaining":499,"resetAt":"2026-08-31T00:00:00Z"}},"errors":[{"message":"forbidden"}]}"#.utf8)
        ])
        let client = GitHubPullRequestStatusCheckClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )
        do {
            _ = try await client.allStatusChecks(pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!)
            XCTFail("Partial status-check coverage must fail closed.")
        } catch let error as GitHubPullRequestStatusCheckClientError {
            XCTAssertEqual(error, .partialResponse)
        }
    }

    private func payload(nodes: String, hasNextPage: Bool, cursor: String?) -> Data {
        Data("""
        {"data":{"node":{"id":"PR_1","mergeable":"MERGEABLE","statusCheckRollup":{"contexts":{"nodes":[\(nodes)],"pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(cursor.map { "\\\"\($0)\\\"" } ?? "null")}}}},"rateLimit":{"cost":1,"remaining":499,"resetAt":"2026-08-31T00:00:00Z"}}}
        """.utf8)
    }
}

private actor StatusCheckSession: HTTPSession {
    private var responses: [Data]
    private var observedAfters = [String?]()

    init(responses: [Data]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try XCTUnwrap(request.httpBody)
        let requestText = String(decoding: body, as: UTF8.self)
        observedAfters.append(requestText.contains(#""after":"next""#) ? "next" : nil)
        let response = responses.removeFirst()
        return (
            response,
            HTTPURLResponse(url: URL(string: "https://api.github.com/graphql")!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        )
    }

    func afters() -> [String?] { observedAfters }
}
