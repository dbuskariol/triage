import Foundation
import XCTest
@testable import Triage

final class GitHubPullRequestStatusCheckClientTests: XCTestCase {
    private static let headCommitSHA = String(repeating: "a", count: 64)

    func testPaginatesExactPullRequestRollupAndPreservesRequiredFailure() async throws {
        let query = try GitHubGraphQLQueries.pullRequestStatusChecks()
        XCTAssertTrue(
            query.document.contains("headRefOid"),
            "The rollup response must expose the selected pull request head for revision fencing."
        )
        let session = StatusCheckSession(responses: [
            payload(nodes: """
                {"__typename":"CheckRun","id":"CHECK_1","name":"build","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-08-31T00:00:00Z","isRequired":true}
                """, hasNextPage: true, cursor: "next", headCommitSHA: Self.headCommitSHA),
            payload(nodes: """
                {"__typename":"StatusContext","id":"STATUS_1","context":"legacy","state":"SUCCESS","updatedAt":"2026-08-31T00:01:00Z","isRequired":false}
                """, hasNextPage: false, cursor: nil, headCommitSHA: Self.headCommitSHA)
        ])
        let client = GitHubPullRequestStatusCheckClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        let inventory = try await client.allStatusChecks(
            pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!,
            expectedHeadCommitSHA: Self.headCommitSHA
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
            _ = try await client.allStatusChecks(
                pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!,
                expectedHeadCommitSHA: Self.headCommitSHA
            )
            XCTFail("Partial status-check coverage must fail closed.")
        } catch let error as GitHubPullRequestStatusCheckClientError {
            XCTAssertEqual(error, .partialResponse)
        }
    }

    func testRejectsDirectHeadCommitMismatch() async throws {
        let session = StatusCheckSession(responses: [
            payload(
                nodes: "",
                hasNextPage: false,
                cursor: nil,
                headCommitSHA: String(repeating: "b", count: 64)
            )
        ])
        let client = GitHubPullRequestStatusCheckClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        do {
            _ = try await client.allStatusChecks(
                pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!,
                expectedHeadCommitSHA: Self.headCommitSHA
            )
            XCTFail("A rollup from another head commit must not become current status-check authority.")
        } catch let error as GitHubPullRequestStatusCheckClientError {
            XCTAssertEqual(error, .headCommitMismatch)
        }
    }

    func testRejectsHeadCommitRotationBetweenPages() async throws {
        let session = StatusCheckSession(responses: [
            payload(
                nodes: "",
                hasNextPage: true,
                cursor: "next",
                headCommitSHA: Self.headCommitSHA
            ),
            payload(
                nodes: "",
                hasNextPage: false,
                cursor: nil,
                headCommitSHA: String(repeating: "b", count: 64)
            )
        ])
        let client = GitHubPullRequestStatusCheckClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        do {
            _ = try await client.allStatusChecks(
                pullRequestNodeID: GitHubNodeID(rawValue: "PR_1")!,
                expectedHeadCommitSHA: Self.headCommitSHA
            )
            XCTFail("A head commit change between cursor pages must fail closed.")
        } catch let error as GitHubPullRequestStatusCheckClientError {
            XCTAssertEqual(error, .headCommitMismatch)
        }
        let observedAfters = await session.afters()
        XCTAssertEqual(observedAfters, [nil, "next"])
    }

    private func payload(
        nodes: String,
        hasNextPage: Bool,
        cursor: String?,
        headCommitSHA: String
    ) -> Data {
        Data("""
        {"data":{"node":{"id":"PR_1","mergeable":"MERGEABLE","headRefOid":"\(headCommitSHA)","statusCheckRollup":{"contexts":{"nodes":[\(nodes)],"pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(cursor.map { "\"\($0)\"" } ?? "null")}}}},"rateLimit":{"cost":1,"remaining":499,"resetAt":"2026-08-31T00:00:00Z"}}}
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
