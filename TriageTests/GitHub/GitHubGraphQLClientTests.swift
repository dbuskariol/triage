import XCTest
@testable import Triage

final class GitHubGraphQLClientTests: XCTestCase {
    func testRejectsMutations() {
        XCTAssertThrowsError(try GitHubGraphQLQuery(document: "mutation { nope }", operationName: "Nope"))
    }

    func testRegisteredQueryInventoryCoversEveryProductionOperation() throws {
        let queries = try GitHubGraphQLQueries.registeredQueries()
        XCTAssertEqual(
            queries.map(\.operationName),
            [
                "TriageViewer",
                "TriageHydrateNodes",
                "TriagePullRequestReviewThreads",
                "TriagePullRequestReviewThreadComments",
                "TriageRepositoryDiscussions",
                "TriageDiscussionComments",
                "TriageDiscussionCommentReplies",
                "TriageOrganizationProjectsV2",
                "TriageProjectV2Items",
                "TriageProjectV2ItemFieldValues"
            ]
        )
        XCTAssertNoThrow(try GitHubGraphQLQueries.validateProductionRegistry(queries))
        XCTAssertTrue(queries.allSatisfy { query in
            query.document.hasPrefix("query ")
                && !query.document.localizedCaseInsensitiveContains("mutation")
                && !query.document.localizedCaseInsensitiveContains("subscription")
                && query.document.range(
                    of: #"\brateLimit\s*\{\s*cost\s+remaining\s+resetAt\s*\}"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
        })
    }

    func testEveryConnectionUsesAtMostFiftyNodesAndIndependentConnectionsExposeCursors() throws {
        let documents = Dictionary(
            uniqueKeysWithValues: try GitHubGraphQLQueries.registeredQueries().map {
                ($0.operationName, $0.document)
            }
        )
        let limitExpression = try NSRegularExpression(pattern: #"\bfirst\s*:\s*([0-9]+)\b"#)
        for (operation, document) in documents {
            let range = NSRange(document.startIndex..., in: document)
            for match in limitExpression.matches(in: document, range: range) {
                let valueRange = try XCTUnwrap(Range(match.range(at: 1), in: document))
                XCTAssertLessThanOrEqual(
                    try XCTUnwrap(Int(document[valueRange])),
                    50,
                    "\(operation) requests an unsupported connection page size."
                )
            }
        }

        let independentlyPaginatedConnections = [
            ("TriagePullRequestReviewThreads", "reviewThreads(first: 50, after: $after)"),
            ("TriagePullRequestReviewThreadComments", "comments(first: 50, after: $after)"),
            ("TriageRepositoryDiscussions", "discussions(first: 50, after: $after,"),
            ("TriageDiscussionComments", "comments(first: 50, after: $after)"),
            ("TriageDiscussionCommentReplies", "replies(first: 50, after: $after)"),
            ("TriageOrganizationProjectsV2", "projectsV2(first: 50, after: $after)"),
            ("TriageProjectV2Items", "items(first: 50, after: $after)"),
            ("TriageProjectV2ItemFieldValues", "fieldValues(first: 50, after: $after)")
        ]
        for (operation, connection) in independentlyPaginatedConnections {
            let document = try XCTUnwrap(documents[operation])
            XCTAssertTrue(document.contains(connection), "\(operation) must cursor-paginate \(connection).")
            XCTAssertTrue(
                document.contains("pageInfo { hasNextPage endCursor }"),
                "\(operation) must expose cursor continuation metadata."
            )
        }
    }

    func testRegistryValidationRejectsMismatchedOperationAndMissingRateLimit() throws {
        let registered = try GitHubGraphQLQueries.registeredQueries()
        var mismatchedName = registered
        mismatchedName[0] = try GitHubGraphQLQuery(
            document: "query TriageViewerTypo { rateLimit { cost remaining resetAt } }",
            operationName: "TriageViewer"
        )
        XCTAssertThrowsError(try GitHubGraphQLQueries.validateProductionRegistry(mismatchedName)) {
            XCTAssertEqual($0 as? GitHubGraphQLError, .invalidQuery)
        }

        var missingRateLimit = registered
        missingRateLimit[0] = try GitHubGraphQLQuery(
            document: "query TriageViewer { viewer { id login name avatarUrl } }",
            operationName: "TriageViewer"
        )
        XCTAssertThrowsError(try GitHubGraphQLQueries.validateProductionRegistry(missingRateLimit)) {
            XCTAssertEqual($0 as? GitHubGraphQLError, .invalidQuery)
        }
    }

    func testRejectsAnUnregisteredDocumentBeforeContactingTransport() async throws {
        let session = GraphQLStubSession(body: Data(#"{"data":{"viewer":{"login":"octocat"}}}"#.utf8))
        let client = GitHubGraphQLClient(session: session, credential: SecretValue("token"))
        let documentMismatch = try GitHubGraphQLQuery(
            document: "query TriageViewer { viewer { login } }",
            operationName: "TriageViewer"
        )
        let viewer = try GitHubGraphQLQueries.viewer()
        let operationMismatch = try GitHubGraphQLQuery(
            document: viewer.document,
            operationName: "TriageViewerTypo"
        )

        for unregistered in [documentMismatch, operationMismatch] {
            do {
                _ = try await client.execute(unregistered, variables: EmptyVariables(), as: ViewerPayload.self)
                XCTFail("Expected the committed-query boundary to reject a mismatch.")
            } catch let error as GitHubGraphQLError {
                XCTAssertEqual(error, .unregisteredQuery)
            }
        }
        let requestCount = await session.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testDecodesPartialResponse() async throws {
        let client = GitHubGraphQLClient(
            session: GraphQLStubSession(body: Data(#"{"data":{"viewer":{"login":"octocat"}},"errors":[{"message":"partial"}]}"#.utf8)),
            credential: SecretValue("token")
        )
        let response = try await client.execute(
            try GitHubGraphQLQueries.viewer(),
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
            try GitHubGraphQLQueries.viewer(),
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
            try GitHubGraphQLQueries.viewer(),
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
                try GitHubGraphQLQueries.viewer(),
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
                try GitHubGraphQLQueries.viewer(),
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
                try GitHubGraphQLQueries.viewer(),
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
            session: GraphQLStubSession(body: Data(#"{"data":{"rateLimit":{"resetAt":"2026-08-29T00:00:00Z"}}}"#.utf8)),
            credential: SecretValue("token")
        )

        let response = try await client.executeComplete(
            try GitHubGraphQLQueries.viewer(),
            variables: EmptyVariables(),
            as: RateLimitDatePayload.self
        )

        XCTAssertEqual(response.rateLimit.resetAt, Date(timeIntervalSince1970: 1_787_961_600))
    }

    func testNormalizesBoundedTransportResponseTooLarge() async throws {
        let client = GitHubGraphQLClient(
            session: GraphQLBoundedErrorSession(),
            credential: SecretValue("token")
        )

        do {
            _ = try await client.execute(
                try GitHubGraphQLQueries.viewer(),
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
                try GitHubGraphQLQueries.viewer(),
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
private struct RateLimitDatePayload: Codable, Sendable { let rateLimit: RateLimit }
private struct RateLimit: Codable, Sendable { let resetAt: Date }

private actor GraphQLStubSession: HTTPSession {
    let body: Data
    let statusCode: Int
    let headers: [String: String]
    private var requests = 0

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
        requests += 1
        return (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }

    func requestCount() -> Int { requests }
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
