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
            _ = try await client.allDiscussions(
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                githubOrganizationID: 1
            )
            XCTFail("Expected cursor loop rejection.")
        } catch let error as GitHubDiscussionClientError {
            guard case let .paginationLoop(pages) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(pages.count, 2)
        }
    }

    func testDiscussionClientRejectsAggregateQueryCostAcrossPages() async throws {
        let session = DiscussionProjectSession(responses: [
            discussionResponse(id: "D_1", hasNextPage: true, cursor: "next", cost: 500),
            discussionResponse(id: "D_2", hasNextPage: false, cursor: nil, cost: 1)
        ])
        let client = GitHubDiscussionClient(client: GitHubGraphQLClient(session: session, credential: SecretValue("token")))
        do {
            _ = try await client.allDiscussions(
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                githubOrganizationID: 1
            )
            XCTFail("Expected aggregate budget rejection.")
        } catch let error as GitHubDiscussionClientError {
            guard case let .aggregateLimitExceeded(pages) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(pages.count, 2)
        }
    }

    func testDiscussionClientPreservesScopedPartialResultsWithoutNormalizingThem() async throws {
        let header = "partial-results; organizations=1"
        let session = DiscussionProjectSession(
            responses: [discussionResponse(id: "D_1", hasNextPage: false, cursor: nil)],
            headers: [["X-GitHub-SSO": header]]
        )
        let client = GitHubDiscussionClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        do {
            _ = try await client.allDiscussions(
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                githubOrganizationID: 1
            )
            XCTFail("Expected scoped partial-result rejection.")
        } catch let error as GitHubDiscussionClientError {
            guard case let .ssoResponse(pages, parsedHeader) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(parsedHeader, GitHubSSOHeader(value: header))
            XCTAssertEqual(pages.count, 1)
        }
    }

    func testDiscussionClientIgnoresPartialResultsForAnotherOrganization() async throws {
        let session = DiscussionProjectSession(
            responses: [discussionResponse(id: "D_1", hasNextPage: false, cursor: nil)],
            headers: [["X-GitHub-SSO": "partial-results; organizations=2"]]
        )
        let client = GitHubDiscussionClient(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        let inventory = try await client.allDiscussions(
            repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
            githubOrganizationID: 1
        )

        XCTAssertEqual(inventory.discussions.map(\.nodeID.rawValue), ["D_1"])
    }

    func testDiscussionNormalizerRejectsMalformedDiscussion() {
        let value = GitHubDiscussionPayload.Discussion(
            id: "D_1", number: 0, title: "", body: nil, url: URL(string: "https://github.com/acme/repo/discussions/1")!,
            createdAt: .now, updatedAt: .now, closedAt: nil, isAnswered: false, category: nil, answer: nil,
            comments: .init(totalCount: 0)
        )
        XCTAssertThrowsError(try GitHubDiscussionNormalizer.normalize([value]))

        let inconsistentAnswer = GitHubDiscussionPayload.Discussion(
            id: "D_2", number: 2, title: "Answered", body: nil,
            url: URL(string: "https://github.com/acme/repo/discussions/2")!,
            createdAt: .now, updatedAt: .now, closedAt: nil, isAnswered: true,
            category: nil, answer: nil, comments: .init(totalCount: 0)
        )
        XCTAssertThrowsError(try GitHubDiscussionNormalizer.normalize([inconsistentAnswer]))
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

    func testProjectClientsEncodeTheExactDeclaredVariableNames() async throws {
        let session = DiscussionProjectSession(responses: [
            projectInventoryResponse(),
            projectItemsResponse(),
            projectFieldValuesResponse()
        ])
        let client = GitHubProjectV2Client(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        let projects = try await client.allProjects(
            organizationNodeID: GitHubNodeID(rawValue: "O_1")!,
            githubOrganizationID: 1
        )
        XCTAssertEqual(projects.projects.map(\.nodeID.rawValue), ["P_1"])
        let items = try await client.allItems(
            projectNodeID: GitHubNodeID(rawValue: "P_1")!,
            githubOrganizationID: 1
        )
        XCTAssertEqual(items.items.map(\.nodeID.rawValue), ["PVTI_1"])

        let bodies = await session.requestBodies()
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(try variableKeys(in: bodies[0]), ["organizationID"])
        XCTAssertEqual(try variableKeys(in: bodies[1]), ["projectID"])
        XCTAssertEqual(try variableKeys(in: bodies[2]), ["itemID"])
        XCTAssertFalse(bodies.contains { String(decoding: $0, as: UTF8.self).contains("\"nodeID\"") })
    }

    func testProjectClientPreservesScopedPartialResultsWithoutNormalizingThem() async throws {
        let header = "partial-results; organizations=1"
        let session = DiscussionProjectSession(
            responses: [projectInventoryResponse()],
            headers: [["X-GitHub-SSO": header]]
        )
        let client = GitHubProjectV2Client(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        do {
            _ = try await client.allProjects(
                organizationNodeID: GitHubNodeID(rawValue: "O_1")!,
                githubOrganizationID: 1
            )
            XCTFail("Expected scoped partial-result rejection.")
        } catch let error as GitHubProjectV2ClientError {
            guard case let .ssoResponse(pages, parsedHeader) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(parsedHeader, GitHubSSOHeader(value: header))
            XCTAssertEqual(pages.count, 1)
        }
    }

    func testProjectMissingRequestedNodeCarriesItsRawPage() async throws {
        let session = DiscussionProjectSession(responses: [
            Data("""
            {"data":{"node":null,"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
            """.utf8)
        ])
        let client = GitHubProjectV2Client(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        do {
            _ = try await client.allProjects(
                organizationNodeID: GitHubNodeID(rawValue: "O_missing")!,
                githubOrganizationID: 1
            )
            XCTFail("Expected a missing-node failure.")
        } catch let error as GitHubProjectV2ClientError {
            guard case let .missingRequestedNode(pages) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(pages.count, 1)
            XCTAssertTrue(pages[0].endpoint.contains("TriageOrganizationProjectsV2"))
            XCTAssertFalse(pages[0].payload.isEmpty)
        }
    }

    func testProjectUndecodableResponseCarriesItsRawPage() async throws {
        let malformed = Data("{".utf8)
        let session = DiscussionProjectSession(responses: [malformed])
        let client = GitHubProjectV2Client(
            client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        )

        do {
            _ = try await client.allProjects(
                organizationNodeID: GitHubNodeID(rawValue: "O_1")!,
                githubOrganizationID: 1
            )
            XCTFail("Expected an undecodable-response failure.")
        } catch let error as GitHubProjectV2ClientError {
            guard case let .undecodableResponse(pages) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(pages.count, 1)
            XCTAssertTrue(pages[0].endpoint.contains("TriageOrganizationProjectsV2"))
            XCTAssertEqual(pages[0].payload, malformed)
        }
    }
}

private func variableKeys(in body: Data) throws -> Set<String> {
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    return Set(try XCTUnwrap(json["variables"] as? [String: Any]).keys)
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

private func projectInventoryResponse() -> Data {
    Data("""
    {"data":{"node":{"id":"O_1","projectsV2":{"nodes":[{"id":"P_1","number":1,"title":"Roadmap","shortDescription":null,"closed":false,"url":"https://github.com/orgs/acme/projects/1","updatedAt":"2026-01-01T00:00:00Z"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private func projectItemsResponse() -> Data {
    Data("""
    {"data":{"node":{"id":"P_1","items":{"nodes":[{"id":"PVTI_1","type":"ISSUE","updatedAt":"2026-01-01T00:00:00Z","content":{"__typename":"Issue","id":"I_1"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":4998,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private func projectFieldValuesResponse() -> Data {
    Data("""
    {"data":{"node":{"id":"PVTI_1","fieldValues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":4997,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private actor DiscussionProjectSession: HTTPSession {
    private var responses: [Data]
    private var headers: [[String: String]]
    private var bodies = [Data]()
    init(responses: [Data], headers: [[String: String]] = []) {
        self.responses = responses
        self.headers = headers
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        bodies.append(try XCTUnwrap(request.httpBody))
        let responseHeaders = headers.isEmpty ? nil : headers.removeFirst()
        return (
            responses.removeFirst(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: responseHeaders
            )!
        )
    }

    func requestBodies() -> [Data] { bodies }
}
