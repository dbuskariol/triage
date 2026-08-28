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
}

private struct EmptyVariables: Codable, Sendable {}
private struct ViewerPayload: Codable, Sendable { let viewer: Viewer }
private struct Viewer: Codable, Sendable { let login: String }

private actor GraphQLStubSession: HTTPSession {
    let body: Data
    init(body: Data) { self.body = body }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
