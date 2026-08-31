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
}

private actor DiscussionCommentSession: HTTPSession {
    private var responses: [Data]; private var requests = [Data]()
    init(responses: [Data]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request.httpBody ?? Data())
        let body = responses.removeFirst()
        return (body, HTTPURLResponse(url: URL(string: "https://api.github.com/graphql")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func bodies() -> [Data] { requests }
}

private func variableKeys(_ data: Data) throws -> Set<String> {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return Set(try XCTUnwrap(object["variables"] as? [String: Any]).keys)
}

private func commentsResponse(hasNextPage: Bool, cursor: String?) -> Data {
    Data("""
    {"data":{"node":{"id":"D_1","comments":{"nodes":[{"id":"DC_1","body":"A comment","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","url":"https://github.com/acme/repo/discussions/1#discussioncomment-1","author":{"id":"U_1","login":"octo","avatarUrl":null},"replies":{"totalCount":1}}],"pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(cursor.map { "\"\($0)\"" } ?? "null")}}},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private func repliesResponse(hasNextPage: Bool, cursor: String?) -> Data {
    Data("""
    {"data":{"node":{"id":"DC_1","replies":{"nodes":[{"id":"DR_1","body":"A reply","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","url":"https://github.com/acme/repo/discussions/1#discussioncomment-2","author":{"id":"U_2","login":"reply","avatarUrl":null}}],"pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(cursor.map { "\"\($0)\"" } ?? "null")}}},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}
