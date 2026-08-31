import Foundation
import XCTest
@testable import Triage

final class GitHubDiscussionCommentClientTests: XCTestCase {
    func testDocumentsAreReadOnlyAndUseIndependentCursors() throws {
        let comments = try GitHubDiscussionCommentQueryDocuments.discussionComments()
        let replies = try GitHubDiscussionCommentQueryDocuments.discussionCommentReplies()
        XCTAssertEqual(comments.operationName, "TriageDiscussionComments")
        XCTAssertEqual(replies.operationName, "TriageDiscussionCommentReplies")
        XCTAssertTrue([comments, replies].allSatisfy { $0.document.contains("rateLimit") && !$0.document.contains("mutation") })
        XCTAssertFalse(comments.document.contains("replies(first:"))
    }

    func testClientFetchesRepliesOutsideTheCommentConnectionAndUsesDeclaredVariables() async throws {
        let session = DiscussionCommentSession(responses: [
            commentsResponse(hasNextPage: false, cursor: nil),
            repliesResponse(hasNextPage: false, cursor: nil)
        ])
        let client = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: session, credential: SecretValue("token")))
        let result = try await client.allCommentsAndReplies(discussionNodeID: GitHubNodeID(rawValue: "D_1")!, githubOrganizationID: 1, validateScope: {})
        XCTAssertEqual(result.comments.map(\.nodeID.rawValue), ["DC_1"])
        XCTAssertEqual(result.replies.map(\.nodeID.rawValue), ["DR_1"])
        XCTAssertEqual(result.rawPages.map(\.source), [.comments, .replies])
        let bodies = await session.bodies()
        XCTAssertEqual(bodies.count, 2)
        guard bodies.count == 2 else { return }
        let commentVariableKeys = try variableKeys(bodies[0])
        let replyVariableKeys = try variableKeys(bodies[1])
        XCTAssertEqual(commentVariableKeys, ["discussionID"])
        XCTAssertEqual(replyVariableKeys, ["commentID"])
    }

    func testReplyCursorLoopRetainsEveryRawPageForFailureProvenance() async throws {
        let session = DiscussionCommentSession(responses: [
            commentsResponse(hasNextPage: false, cursor: nil),
            repliesResponse(hasNextPage: true, cursor: "again"),
            repliesResponse(hasNextPage: true, cursor: "again")
        ])
        let client = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: session, credential: SecretValue("token")))
        do {
            _ = try await client.allCommentsAndReplies(discussionNodeID: GitHubNodeID(rawValue: "D_1")!, githubOrganizationID: 1, validateScope: {})
            XCTFail("Expected nested reply cursor loop rejection.")
        } catch let error as GitHubDiscussionCommentClientError {
            guard case let .paginationLoop(source, pages) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(source, .replies); XCTAssertEqual(pages.count, 3)
            XCTAssertEqual(pages.last?.requestKey, "graphql:TriageDiscussionCommentReplies/discussion=D_1/comment=DC_1/after=YWdhaW4=")
        }
    }

    func testPartialMalformedNullAndSSOCommentResponsesFailClosedWithRawProvenance() async throws {
        let cases: [(Data, [String: String], String)] = [
            (Data(#"{"data":{"node":{"id":"D_1","comments":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":1,"resetAt":"2026-01-02T00:00:00Z"}},"errors":[{"message":"forbidden"}]}"#.utf8), [:], "partial"),
            (Data(#"{"data":{"node":{"id":"D_1","comments":{"nodes":[null],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":1,"resetAt":"2026-01-02T00:00:00Z"}}}"#.utf8), [:], "null"),
            (Data(#"{"data": "#.utf8), [:], "malformed"),
            (commentsResponse(hasNextPage: false, cursor: nil), ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"], "sso")
        ]
        for (body, headers, expected) in cases {
            let session = DiscussionCommentSession(responses: [.init(body: body, headers: headers)])
            let client = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: session, credential: SecretValue("token")))
            do {
                _ = try await client.allCommentsAndReplies(discussionNodeID: GitHubNodeID(rawValue: "D_1")!, githubOrganizationID: 1, validateScope: {})
                XCTFail("Expected \(expected) response to remain non-authoritative")
            } catch let error as GitHubDiscussionCommentClientError {
                switch expected {
                case "partial": guard case let .partialResponse(_, pages) = error else { return XCTFail("Unexpected \(error)") }; XCTAssertEqual(pages.count, 1)
                case "null": guard case let .incompleteConnection(_, pages) = error else { return XCTFail("Unexpected \(error)") }; XCTAssertEqual(pages.count, 1)
                case "malformed": guard case let .undecodableResponse(_, pages) = error else { return XCTFail("Unexpected \(error)") }; XCTAssertEqual(pages.count, 1)
                default: guard case let .ssoResponse(_, pages, _) = error else { return XCTFail("Unexpected \(error)") }; XCTAssertEqual(pages.count, 1)
                }
            }
        }
    }

    func testCostAggregateBudgetPageCapAndCancellationAllAbortPublication() async throws {
        let expensive = DiscussionCommentSession(responses: [.init(body: commentsResponse(hasNextPage: false, cursor: nil, cost: 501))])
        let expensiveClient = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: expensive, credential: SecretValue("token")))
        await assertDiscussionFailure(expensiveClient, expected: "cost")

        let oversizedAggregate = DiscussionCommentSession(responses: [
            .init(body: paddedCommentsResponse(hasNextPage: true, cursor: "next")),
            .init(body: paddedCommentsResponse(hasNextPage: false, cursor: nil))
        ])
        let oversizedClient = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: oversizedAggregate, credential: SecretValue("token")))
        await assertDiscussionFailure(oversizedClient, expected: "aggregate")

        let capped = DiscussionCommentSession(responses: (1 ... 101).map { index in
            .init(body: commentsResponse(hasNextPage: true, cursor: "cursor-\(index)"))
        })
        let cappedClient = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: capped, credential: SecretValue("token")))
        await assertDiscussionFailure(cappedClient, expected: "cap")

        let cancelled = DiscussionCommentSession(responses: [.init(body: commentsResponse(hasNextPage: false, cursor: nil))])
        let cancelledClient = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: cancelled, credential: SecretValue("token")))
        do {
            _ = try await cancelledClient.allCommentsAndReplies(discussionNodeID: GitHubNodeID(rawValue: "D_1")!, githubOrganizationID: 1, validateScope: { throw CancellationError() })
            XCTFail("Expected cancellation to abort comment hydration.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelledRequestCount = await cancelled.requestCount()
        XCTAssertEqual(cancelledRequestCount, 0)
    }

    func testFirstPageApprovalFailureRetainsBoundedRawEvidence() async throws {
        let session = DiscussionCommentSession(responses: [
            .init(
                body: Data(#"{"message":"Personal access token pending approval"}"#.utf8),
                statusCode: 403
            )
        ])
        let client = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: session, credential: SecretValue("token")))

        do {
            _ = try await client.allCommentsAndReplies(
                discussionNodeID: GitHubNodeID(rawValue: "D_1")!,
                githubOrganizationID: 1,
                validateScope: {}
            )
            XCTFail("Expected approval failure")
        } catch let error as GitHubDiscussionCommentClientError {
            guard case let .requestFailed(.comments, pages, .requestFailed(failure)) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(failure.kind, .forbidden)
            XCTAssertEqual(failure.accessRestriction, .organizationApprovalRequired)
            XCTAssertEqual(pages.count, 1)
            XCTAssertEqual(pages[0].payload, Data(#"{"message":"Personal access token pending approval"}"#.utf8))
        }
    }

    func testFirstPageSSOFailureRetainsRawEvidenceAndStaysScoped() async throws {
        let body = Data(#"{"message":"SSO required"}"#.utf8)
        let session = DiscussionCommentSession(responses: [
            .init(
                body: body,
                headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"],
                statusCode: 403
            )
        ])
        let client = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: session, credential: SecretValue("token")))

        do {
            _ = try await client.allCommentsAndReplies(
                discussionNodeID: GitHubNodeID(rawValue: "D_1")!,
                githubOrganizationID: 1,
                validateScope: {}
            )
            XCTFail("Expected scoped SSO failure")
        } catch let error as GitHubDiscussionCommentClientError {
            guard case let .ssoResponse(.comments, pages, header) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(header, .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso")!))
            XCTAssertEqual(pages.map(\.payload), [body])
        }
    }

    func testLaterRootRateLimitFailureRetainsPriorAndFailingRawPages() async throws {
        let rateLimited = Data(#"{"message":"API rate limit exceeded"}"#.utf8)
        let session = DiscussionCommentSession(responses: [
            .init(body: commentsResponse(hasNextPage: true, cursor: "next")),
            .init(body: rateLimited, headers: ["Retry-After": "30"], statusCode: 429)
        ])
        let client = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: session, credential: SecretValue("token")))

        do {
            _ = try await client.allCommentsAndReplies(
                discussionNodeID: GitHubNodeID(rawValue: "D_1")!,
                githubOrganizationID: 1,
                validateScope: {}
            )
            XCTFail("Expected rate-limit failure")
        } catch let error as GitHubDiscussionCommentClientError {
            guard case let .requestFailed(.comments, pages, .requestFailed(failure)) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(failure.kind, .rateLimited)
            XCTAssertEqual(failure.retryAfter, 30)
            XCTAssertEqual(pages.count, 2)
            XCTAssertEqual(pages.last?.payload, rateLimited)
            XCTAssertEqual(pages.last?.requestKey, "graphql:TriageDiscussionComments/discussion=D_1/after=bmV4dA==")
        }
    }

    func testOverfullAndDuplicateCommentOrReplyPagesAreNonAuthoritative() async throws {
        let overfullComments = DiscussionCommentSession(responses: [.init(body: overfullCommentsResponse())])
        let overfullCommentClient = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: overfullComments, credential: SecretValue("token")))
        await assertIncompleteConnection(overfullCommentClient, expected: .comments)

        let duplicateComments = DiscussionCommentSession(responses: [
            .init(body: commentsResponse(hasNextPage: true, cursor: "next")),
            .init(body: commentsResponse(hasNextPage: false, cursor: nil))
        ])
        let duplicateCommentClient = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: duplicateComments, credential: SecretValue("token")))
        await assertNormalizationFailure(duplicateCommentClient, expected: .comments)

        let overfullReplies = DiscussionCommentSession(responses: [
            .init(body: commentsResponse(hasNextPage: false, cursor: nil)),
            .init(body: overfullRepliesResponse())
        ])
        let overfullReplyClient = try GitHubDiscussionCommentClient(client: GitHubGraphQLClient(session: overfullReplies, credential: SecretValue("token")))
        await assertIncompleteConnection(overfullReplyClient, expected: .replies)
    }

    private func assertDiscussionFailure(_ client: GitHubDiscussionCommentClient, expected: String) async {
        do {
            _ = try await client.allCommentsAndReplies(discussionNodeID: GitHubNodeID(rawValue: "D_1")!, githubOrganizationID: 1, validateScope: {})
            XCTFail("Expected \(expected) failure")
        } catch let error as GitHubDiscussionCommentClientError {
            if expected == "cost" { guard case .queryCostExceeded = error else { return XCTFail("Unexpected \(error)") } }
            else if expected == "aggregate" { guard case .aggregateLimitExceeded = error else { return XCTFail("Unexpected \(error)") } }
            else { guard case .paginationLimitExceeded = error else { return XCTFail("Unexpected \(error)") } }
        } catch { XCTFail("Unexpected \(error)") }
    }

    private func assertIncompleteConnection(_ client: GitHubDiscussionCommentClient, expected: GitHubDiscussionCommentSource) async {
        do {
            _ = try await client.allCommentsAndReplies(discussionNodeID: GitHubNodeID(rawValue: "D_1")!, githubOrganizationID: 1, validateScope: {})
            XCTFail("Expected incomplete connection")
        } catch let error as GitHubDiscussionCommentClientError {
            guard case let .incompleteConnection(source, pages) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(source, expected)
            XCTAssertFalse(pages.isEmpty)
        } catch { XCTFail("Unexpected \(error)") }
    }

    private func assertNormalizationFailure(_ client: GitHubDiscussionCommentClient, expected: GitHubDiscussionCommentSource) async {
        do {
            _ = try await client.allCommentsAndReplies(discussionNodeID: GitHubNodeID(rawValue: "D_1")!, githubOrganizationID: 1, validateScope: {})
            XCTFail("Expected normalization failure")
        } catch let error as GitHubDiscussionCommentClientError {
            guard case let .normalizationFailed(source, pages) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(source, expected)
            XCTAssertEqual(pages.count, 2)
        } catch { XCTFail("Unexpected \(error)") }
    }
}

private actor DiscussionCommentSession: HTTPSession {
    struct Response: Sendable {
        let body: Data
        let headers: [String: String]
        let statusCode: Int
        init(body: Data, headers: [String: String] = [:], statusCode: Int = 200) {
            self.body = body
            self.headers = headers
            self.statusCode = statusCode
        }
    }
    private var responses: [Response]; private var requests = [Data]()
    init(responses: [Data]) { self.responses = responses.map { .init(body: $0) } }
    init(responses: [Response]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request.httpBody ?? Data())
        let response = responses.removeFirst()
        return (response.body, HTTPURLResponse(url: URL(string: "https://api.github.com/graphql")!, statusCode: response.statusCode, httpVersion: nil, headerFields: response.headers)!)
    }
    func bodies() -> [Data] { requests }
    func requestCount() -> Int { requests.count }
}

private func variableKeys(_ data: Data) throws -> Set<String> {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return Set(try XCTUnwrap(object["variables"] as? [String: Any]).keys)
}

private func commentsResponse(hasNextPage: Bool, cursor: String?, cost: Int = 1) -> Data {
    Data("""
    {"data":{"node":{"id":"D_1","comments":{"nodes":[{"id":"DC_1","body":"A comment","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","url":"https://github.com/acme/repo/discussions/1#discussioncomment-1","author":{"id":"U_1","login":"octo","avatarUrl":null},"replies":{"totalCount":1}}],"pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(cursor.map { "\"\($0)\"" } ?? "null")}}},"rateLimit":{"cost":\(cost),"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private func repliesResponse(hasNextPage: Bool, cursor: String?) -> Data {
    Data("""
    {"data":{"node":{"id":"DC_1","replies":{"nodes":[{"id":"DR_1","body":"A reply","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","url":"https://github.com/acme/repo/discussions/1#discussioncomment-2","author":{"id":"U_2","login":"reply","avatarUrl":null}}],"pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(cursor.map { "\"\($0)\"" } ?? "null")}}},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private func overfullCommentsResponse() -> Data {
    let node = #"{"id":"DC_1","body":"A comment","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","url":"https://github.com/acme/repo/discussions/1#discussioncomment-1","author":null,"replies":{"totalCount":0}}"#
    return Data("""
    {"data":{"node":{"id":"D_1","comments":{"nodes":[\(Array(repeating: node, count: 51).joined(separator: ","))],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private func overfullRepliesResponse() -> Data {
    let node = #"{"id":"DR_1","body":"A reply","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","url":"https://github.com/acme/repo/discussions/1#discussioncomment-2","author":null}"#
    return Data("""
    {"data":{"node":{"id":"DC_1","replies":{"nodes":[\(Array(repeating: node, count: 51).joined(separator: ","))],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private func paddedCommentsResponse(hasNextPage: Bool, cursor: String?) -> Data {
    let response = String(decoding: commentsResponse(hasNextPage: hasNextPage, cursor: cursor), as: UTF8.self)
    let padding = String(repeating: "x", count: 2_100_000)
    return Data((String(response.dropLast()) + ",\"padding\":\"\(padding)\"}").utf8)
}
