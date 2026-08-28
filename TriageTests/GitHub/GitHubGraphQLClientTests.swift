import XCTest
@testable import Triage

final class GitHubGraphQLClientTests: XCTestCase {
    func testRejectsMutations() {
        XCTAssertThrowsError(try GitHubGraphQLQuery(document: "mutation { nope }", operationName: "Nope"))
    }

    func testDecodesPartialResponse() async throws {
        let client = GitHubGraphQLClient(
            session: GraphQLStubSession(body: Data(#"{"data":{"viewer":{"login":"octocat"}},"errors":[{"message":"partial"}]}"#.utf8)),
            credential: SecretValue("token")
        )
        let response = try await client.execute(
            GitHubGraphQLQuery(document: "query Viewer { viewer { login } }", operationName: "Viewer"),
            variables: EmptyVariables(),
            as: ViewerPayload.self
        )
        XCTAssertEqual(response.data?.viewer.login, "octocat")
        XCTAssertEqual(response.errors.map(\.message), ["partial"])
    }

    func testRejectsMalformedResponseInsteadOfReturningEmptyData() async throws {
        let client = GitHubGraphQLClient(
            session: GraphQLStubSession(body: Data("{".utf8)),
            credential: SecretValue("token")
        )

        do {
            _ = try await client.execute(
                GitHubGraphQLQuery(document: "query Viewer { viewer { login } }", operationName: "Viewer"),
                variables: EmptyVariables(),
                as: ViewerPayload.self
            )
            XCTFail("Expected malformed response failure.")
        } catch let error as GitHubGraphQLError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testClassifiesGraphQLSecondaryLimitUsingResponseHeaders() async throws {
        let client = GitHubGraphQLClient(
            session: GraphQLStubSession(
                body: Data(#"{"message":"slow down"}"#.utf8),
                statusCode: 403,
                headers: ["Retry-After": "60"]
            ),
            credential: SecretValue("token")
        )

        do {
            _ = try await client.execute(
                GitHubGraphQLQuery(document: "query Viewer { viewer { login } }", operationName: "Viewer"),
                variables: EmptyVariables(),
                as: ViewerPayload.self
            )
            XCTFail("Expected rate-limit failure.")
        } catch let error as GitHubGraphQLError {
            XCTAssertEqual(error, .requestFailed(GitHubFailure(
                kind: .secondaryRateLimited,
                statusCode: 403,
                retryAfter: 60
            )))
        }
    }
}

private struct EmptyVariables: Codable, Sendable {}
private struct ViewerPayload: Codable, Sendable { let viewer: Viewer }
private struct Viewer: Codable, Sendable { let login: String }

private actor GraphQLStubSession: HTTPSession {
    let body: Data
    let statusCode: Int
    let headers: [String: String]

    init(
        body: Data,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) {
        self.body = body
        self.statusCode = statusCode
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }
}
