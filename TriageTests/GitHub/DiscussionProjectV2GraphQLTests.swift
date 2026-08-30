import Foundation
import XCTest
@testable import Triage

final class DiscussionProjectV2GraphQLTests: XCTestCase {
    func testNamedReadOnlyDocumentsIncludeRateLimit() throws {
        let queries = [
            try GitHubGraphQLQueries.repositoryDiscussions(),
            try GitHubGraphQLQueries.organizationProjectsV2(),
            try GitHubGraphQLQueries.projectV2Items(),
            try GitHubGraphQLQueries.projectV2ItemFieldValues()
        ]
        XCTAssertEqual(
            queries.map(\.operationName),
            ["TriageRepositoryDiscussions", "TriageOrganizationProjectsV2", "TriageProjectV2Items", "TriageProjectV2ItemFieldValues"]
        )
        XCTAssertTrue(queries.allSatisfy { $0.document.contains("rateLimit") && !$0.document.contains("mutation") })
    }

    func testDiscussionClientPaginatesAndRejectsRepeatedCursor() async throws {
        let session = DiscussionProjectSession(responses: [
            discussionResponse(id: "D_1", hasNextPage: true, cursor: "repeat"),
            discussionResponse(id: "D_2", hasNextPage: true, cursor: "repeat")
        ])
        let client = GitHubDiscussionClient(client: GitHubGraphQLClient(session: session, credential: SecretValue("token")))
        do {
            _ = try await client.allDiscussions(repositoryNodeID: GitHubNodeID(rawValue: "R_1")!)
            XCTFail("Expected cursor loop rejection.")
        } catch let error as GitHubDiscussionClientError {
            XCTAssertEqual(error, .paginationLoop)
        }
    }

    func testDiscussionClientRejectsAggregateQueryCostAcrossPages() async throws {
        let session = DiscussionProjectSession(responses: [
            discussionResponse(id: "D_1", hasNextPage: true, cursor: "next", cost: 500),
            discussionResponse(id: "D_2", hasNextPage: false, cursor: nil, cost: 1)
        ])
        let client = GitHubDiscussionClient(client: GitHubGraphQLClient(session: session, credential: SecretValue("token")))
        do {
            _ = try await client.allDiscussions(repositoryNodeID: GitHubNodeID(rawValue: "R_1")!)
            XCTFail("Expected aggregate budget rejection.")
        } catch let error as GitHubDiscussionClientError {
            guard case let .aggregateLimitExceeded(pages) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(pages.count, 2)
        }
    }

    func testDiscussionNormalizerRejectsMalformedDiscussion() {
        let value = GitHubDiscussionPayload.Discussion(
            id: "D_1", number: 0, title: "", body: nil, url: URL(string: "https://github.com/acme/repo/discussions/1")!,
            createdAt: .now, updatedAt: .now, closedAt: nil, isAnswered: false, category: nil, answer: nil,
            comments: .init(totalCount: 0)
        )
        XCTAssertThrowsError(try GitHubDiscussionNormalizer.normalize([value]))
    }

    func testProjectFieldNormalizerRejectsMalformedKnownUnionAndPreservesUnknownContext() throws {
        let malformed = GitHubProjectV2FieldValuePayload.Value(
            typeName: "ProjectV2ItemFieldTextValue", field: nil, text: "value", number: nil, date: nil, name: nil,
            title: nil, users: nil, labels: nil, milestone: nil, repository: nil, pullRequests: nil, issue: nil
        )
        XCTAssertThrowsError(try GitHubProjectV2Normalizer.fields([malformed]))

        let unsupported = GitHubProjectV2FieldValuePayload.Value(
            typeName: "FutureProjectField", field: nil, text: nil, number: nil, date: nil, name: nil, title: nil,
            users: nil, labels: nil, milestone: nil, repository: nil, pullRequests: nil, issue: nil
        )
        let normalized = try GitHubProjectV2Normalizer.fields([unsupported])
        XCTAssertEqual(normalized.first?.valueKind, "FutureProjectField")
        XCTAssertEqual(normalized.first?.context, "unsupported union")
        XCTAssertFalse(normalized.first!.isAuthoritative)
    }

    func testProjectDateFieldsUseStrictUTCDates() throws {
        let valid = projectDateField("2026-08-30")
        let validNormalized = try GitHubProjectV2Normalizer.fields([valid])
        XCTAssertTrue(validNormalized[0].isAuthoritative)
        XCTAssertEqual(
            validNormalized[0].dateValue,
            Date(timeIntervalSince1970: 1_788_048_000)
        )

        let invalid = projectDateField("2026-08-30T00:00:00Z")
        let invalidNormalized = try GitHubProjectV2Normalizer.fields([invalid])
        XCTAssertFalse(invalidNormalized[0].isAuthoritative)
        XCTAssertNil(invalidNormalized[0].dateValue)
        XCTAssertEqual(invalidNormalized[0].context, "invalid UTC date-only scalar")
    }
}

private func discussionResponse(id: String, hasNextPage: Bool, cursor: String?, cost: Int = 1) -> Data {
    Data("""
    {"data":{"node":{"id":"R_1","discussions":{"nodes":[{"id":"\(id)","number":1,"title":"Title","body":null,"url":"https://github.com/acme/repo/discussions/1","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","closedAt":null,"isAnswered":false,"category":null,"answer":null,"comments":{"totalCount":0}}],"pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(cursor.map { "\"\($0)\"" } ?? "null")}}},"rateLimit":{"cost":\(cost),"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private func projectDateField(_ date: String) -> GitHubProjectV2FieldValuePayload.Value {
    .init(
        typeName: "ProjectV2ItemFieldDateValue",
        field: .init(id: "F_1", name: "Due date", dataType: "DATE"),
        text: nil, number: nil, date: date, name: nil, title: nil, users: nil, labels: nil,
        milestone: nil, repository: nil, pullRequests: nil, issue: nil
    )
}

private actor DiscussionProjectSession: HTTPSession {
    private var responses: [Data]
    init(responses: [Data]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        return (responses.removeFirst(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
