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

    func testDecodesNumericGraphQLErrorPathComponents() async throws {
        let client = GitHubGraphQLClient(
            session: GraphQLStubSession(
                body: Data(
                    #"{"data":{"viewer":{"login":"octocat"}},"errors":[{"message":"partial","path":["nodes",3,"title"],"type":"FORBIDDEN","extensions":{"code":"FORBIDDEN"}}]}"#.utf8
                )
            ),
            credential: SecretValue("token")
        )

        let response = try await client.execute(
            GitHubGraphQLQuery(document: "query Viewer { viewer { login } }", operationName: "Viewer"),
            variables: EmptyVariables(),
            as: ViewerPayload.self
        )

        XCTAssertEqual(
            response.errors.first?.path,
            [.field("nodes"), .index(3), .field("title")]
        )
        XCTAssertEqual(response.errors.first?.type, "FORBIDDEN")
        XCTAssertEqual(response.errors.first?.extensions?.code, "FORBIDDEN")
    }

    func testProvenanceAPIRetainsPayloadAndErrorsWhenTypedDataCannotDecode() async throws {
        let payload = Data(
            #"{"data":{"viewer":{"login":42}},"errors":[{"message":"ghp_privateGraphQLError","path":["nodes",1],"type":"NOT_FOUND"}]}"#.utf8
        )
        let client = GitHubGraphQLClient(
            session: GraphQLStubSession(
                body: payload,
                headers: [
                    "X-GitHub-Request-Id": "request-1",
                    "X-GitHub-SSO": "partial-results; organizations=2"
                ]
            ),
            credential: SecretValue("token")
        )

        let result = try await client.executePreservingUndecodableResponse(
            GitHubGraphQLQuery(document: "query Viewer { viewer { login } }", operationName: "Viewer"),
            variables: EmptyVariables(),
            as: ViewerPayload.self
        )

        guard case let .undecodable(response) = result else {
            return XCTFail("A typed-data decoding failure must remain available to provenance-aware callers.")
        }
        XCTAssertEqual(response.payload, payload)
        XCTAssertEqual(response.errors.first?.path, [.field("nodes"), .index(1)])
        XCTAssertEqual(response.errors.first?.type, "NOT_FOUND")
        XCTAssertEqual(response.metadata.requestID, "request-1")
        XCTAssertEqual(response.metadata.ssoHeader, .partialResults([2]))
    }

    func testRejectsPartialResponseWhenCompleteDataIsRequired() async throws {
        let client = GitHubGraphQLClient(
            session: GraphQLStubSession(
                body: Data(#"{"data":{"viewer":{"login":"octocat"}},"errors":[{"message":"partial"}]}"#.utf8)
            ),
            credential: SecretValue("token")
        )

        do {
            _ = try await client.executeComplete(
                GitHubGraphQLQuery(document: "query Viewer { viewer { login } }", operationName: "Viewer"),
                variables: EmptyVariables(),
                as: ViewerPayload.self
            )
            XCTFail("Expected partial response rejection.")
        } catch let error as GitHubGraphQLError {
            XCTAssertEqual(error, .partialResponse)
        }
    }

    func testRejectsMissingDataWhenCompleteDataIsRequired() async throws {
        let client = GitHubGraphQLClient(
            session: GraphQLStubSession(body: Data(#"{"data":null}"#.utf8)),
            credential: SecretValue("token")
        )

        do {
            _ = try await client.executeComplete(
                GitHubGraphQLQuery(document: "query Viewer { viewer { login } }", operationName: "Viewer"),
                variables: EmptyVariables(),
                as: ViewerPayload.self
            )
            XCTFail("Expected missing data rejection.")
        } catch let error as GitHubGraphQLError {
            XCTAssertEqual(error, .missingData)
        }
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

    func testDecodesGraphQLISO8601Dates() async throws {
        let client = GitHubGraphQLClient(
            session: GraphQLStubSession(body: Data(#"{"data":{"resetAt":"2026-08-29T00:00:00Z"}}"#.utf8)),
            credential: SecretValue("token")
        )

        let response = try await client.executeComplete(
            GitHubGraphQLQuery(document: "query RateLimit { resetAt }", operationName: "RateLimit"),
            variables: EmptyVariables(),
            as: DatePayload.self
        )

        XCTAssertEqual(response.resetAt, Date(timeIntervalSince1970: 1_787_961_600))
    }

    func testNormalizesBoundedTransportResponseTooLarge() async throws {
        let client = GitHubGraphQLClient(
            session: GraphQLBoundedErrorSession(),
            credential: SecretValue("token")
        )

        do {
            _ = try await client.execute(
                GitHubGraphQLQuery(document: "query Viewer { viewer { login } }", operationName: "Viewer"),
                variables: EmptyVariables(),
                as: ViewerPayload.self
            )
            XCTFail("Expected an oversized response failure.")
        } catch let error as GitHubGraphQLError {
            XCTAssertEqual(error, .responseTooLarge)
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
private struct DatePayload: Codable, Sendable { let resetAt: Date }

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

private actor GraphQLBoundedErrorSession: BoundedHTTPSession {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw GitHubTransportError.responseTooLarge
    }

    func data(
        for request: URLRequest,
        maximumResponseBodyBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        throw GitHubTransportError.responseTooLarge
    }
}
