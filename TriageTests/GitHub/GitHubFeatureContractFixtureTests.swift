import XCTest
@testable import Triage

final class GitHubFeatureContractFixtureTests: XCTestCase {
    // GITHUB_FEATURE_CONTRACTS.md — Identity and inventory / Repository inventory and private visibility: Link pagination.
    func testRESTPaginationFixtureFollowsVerifiedGitHubLink() async throws {
        let next = "https://api.github.com/orgs/acme/repos?page=2&type=all&per_page=100"
        let session = GitHubFeatureContractFixtures.Session(responses: [
            .init(
                body: Data("[\(GitHubFeatureContractFixtures.repository(id: 1, nodeID: "R_1", name: "one"))]".utf8),
                headers: ["Link": "<\(next)>; rel=\"next\""]
            ),
            .init(body: Data("[\(GitHubFeatureContractFixtures.repository(id: 2, nodeID: "R_2", name: "two"))]".utf8))
        ])

        let inventory = try await repositoryClient(session: session).allRepositories(in: "acme")

        XCTAssertEqual(inventory.values.map(\.nodeID), ["R_1", "R_2"])
        XCTAssertTrue(inventory.values.allSatisfy(\.isPrivate))
        XCTAssertEqual(inventory.pages.count, 2)
        let requestedURLs = await session.requestedURLs()
        XCTAssertEqual(
            requestedURLs.map(\.absoluteString),
            [
                "https://api.github.com/orgs/acme/repos?type=all&per_page=100",
                next
            ]
        )
    }

    // GITHUB_FEATURE_CONTRACTS.md — Shared transport rules: REST pagination remains on the authenticated GitHub API authority.
    func testMalformedRESTPaginationLinkFailsBeforeFollowingIt() async throws {
        let session = GitHubFeatureContractFixtures.Session(responses: [
            .init(
                body: Data("[\(GitHubFeatureContractFixtures.repository(id: 1, nodeID: "R_1"))]".utf8),
                headers: ["Link": "<https://example.invalid/orgs/acme/repos?page=2&type=all&per_page=100>; rel=\"next\""]
            )
        ])

        do {
            _ = try await repositoryClient(session: session).allRepositories(in: "acme")
            XCTFail("A cross-host Link header must not be followed.")
        } catch let error as GitHubRepositoryTeamClientError {
            XCTAssertEqual(error, .invalidPaginationLink)
        }
        let requestCount = await session.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    // GITHUB_FEATURE_CONTRACTS.md — Identity and inventory / Repository inventory: an incomplete or invalid inventory never becomes authoritative.
    func testDuplicateRepositoryIdentifiersCannotProduceAuthoritativeInventory() async throws {
        let session = GitHubFeatureContractFixtures.Session(responses: [
            .init(body: Data("[\(GitHubFeatureContractFixtures.repository(id: 1, nodeID: "R_1")),\(GitHubFeatureContractFixtures.repository(id: 1, nodeID: "R_2"))]".utf8))
        ])

        do {
            _ = try await repositoryClient(session: session).allRepositories(in: "acme")
            XCTFail("Duplicate inventory IDs must fail closed.")
        } catch let error as GitHubRepositoryTeamClientError {
            XCTAssertEqual(error, .duplicateRepository)
        }
    }

    // GITHUB_FEATURE_CONTRACTS.md — Shared transport rules / REST budget: no more than 100 objects per page.
    func testRESTObjectBudgetFixtureRejectsAnOversizedPageBeforeInventoryPublication() async throws {
        let session = GitHubFeatureContractFixtures.Session(responses: [
            .init(body: GitHubFeatureContractFixtures.repositoryPage(count: 101))
        ])

        do {
            _ = try await repositoryClient(session: session).allRepositories(in: "acme")
            XCTFail("A REST response beyond the 100-object contract limit must fail closed.")
        } catch let error as GitHubRepositoryTeamClientError {
            XCTAssertEqual(error, .pageObjectLimitExceeded)
        }
    }

    // GITHUB_FEATURE_CONTRACTS.md — Shared transport rules: 304 is unchanged evidence, never an empty result.
    func testConditional304RemainsEvidenceRatherThanAnEmptyInventory() async throws {
        let session = GitHubFeatureContractFixtures.Session(responses: [
            .init(statusCode: 304, body: Data(), headers: ["X-GitHub-SSO": "partial-results; organizations=7"])
        ])
        let result = try await repositoryClient(session: session).fetchRepositories(
            in: "acme",
            validators: try GitHubHTTPValidators(eTag: "\"inventory-v1\"", lastModified: nil)
        )

        guard case let .notModified(ssoHeader) = result else {
            return XCTFail("A 304 must never decode as a successful empty inventory.")
        }
        XCTAssertEqual(ssoHeader, .partialResults([7]))
    }

    // GITHUB_FEATURE_CONTRACTS.md — Shared transport rules and Search 304 reuse: unsolicited/cross-authority 304 responses fail closed.
    func testUnsolicitedTimeline304FailsClosedAndConditionalIdentitiesAreScopeQualified() async throws {
        let session = GitHubFeatureContractFixtures.Session(responses: [.init(statusCode: 304, body: Data())])
        let timeline = GitHubTimelineClient(client: try restClient(session: session))
        do {
            _ = try await timeline.timeline(
                repository: try GitHubRepositoryPath(owner: "acme", repository: "repo"),
                issueOrPullRequestNumber: 1
            )
            XCTFail("An unsolicited timeline 304 has no replay authority.")
        } catch let error as GitHubTimelineClientError {
            XCTAssertEqual(error, .unexpectedNotModified)
        }

        let query = try GitHubIssueSearchQuery(
            organizationLogin: "acme",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )
        let original = try GitHubIssueSearchRequestIdentity(
            query: query,
            page: 1,
            scope: fixtureScope(credentialRevision: "credential-v1"),
            streamID: SyncStreamID(rawValue: "role-discovery")!
        )
        let rotatedCredential = try GitHubIssueSearchRequestIdentity(
            query: query,
            page: 1,
            scope: fixtureScope(credentialRevision: "credential-v2"),
            streamID: SyncStreamID(rawValue: "role-discovery")!
        )
        XCTAssertNotEqual(original.requestKey, rotatedCredential.requestKey)
        XCTAssertEqual(original.endpoint, rotatedCredential.endpoint)
    }

    // GITHUB_FEATURE_CONTRACTS.md — Shared transport rules: malformed payload failure records incomplete coverage, not an empty page.
    func testUndecodableRESTFixturePreservesRawEvidenceInsteadOfEmptyPage() async throws {
        let client = try restClient(session: GitHubFeatureContractFixtures.Session(responses: [
            .init(body: GitHubFeatureContractFixtures.malformedJSON, headers: ["ETag": "fixture-malformed"])
        ]))

        let result = try await client.getPagePreservingUndecodablePayload(
            GitHubRepositoryDTO.self,
            request: GitHubRESTRequest(path: "/orgs/acme/repos")
        )

        guard case let .undecodable(page) = result else {
            return XCTFail("Malformed payloads must remain non-authoritative.")
        }
        XCTAssertEqual(page.payload, GitHubFeatureContractFixtures.malformedJSON)
        XCTAssertEqual(page.etag, "fixture-malformed")
    }

    // GITHUB_FEATURE_CONTRACTS.md — Shared transport rules: partial GraphQL data/errors and malformed payloads are non-authoritative.
    func testGraphQLPartialAndMalformedFixturesAreDistinctAndNonAuthoritative() async throws {
        let partialClient = GitHubGraphQLClient(
            session: GitHubFeatureContractFixtures.Session(responses: [.init(body: GitHubFeatureContractFixtures.partialGraphQL)]),
            credential: SecretValue("fixture-token")
        )
        let query = try GitHubGraphQLQueries.viewer()

        do {
            _ = try await partialClient.executeComplete(query, variables: FixtureVariables(), as: FixtureViewerPayload.self)
            XCTFail("Partial GraphQL data must not become authoritative.")
        } catch let error as GitHubGraphQLError {
            XCTAssertEqual(error, .partialResponse)
        }

        let malformedClient = GitHubGraphQLClient(
            session: GitHubFeatureContractFixtures.Session(responses: [.init(body: GitHubFeatureContractFixtures.malformedJSON)]),
            credential: SecretValue("fixture-token")
        )
        let malformed = try await malformedClient.executePreservingUndecodableResponse(
            query,
            variables: FixtureVariables(),
            as: FixtureViewerPayload.self
        )
        guard case let .undecodable(response) = malformed else {
            return XCTFail("Malformed GraphQL must remain distinguishable from partial data.")
        }
        XCTAssertEqual(response.payload, GitHubFeatureContractFixtures.malformedJSON)
    }

    // GITHUB_FEATURE_CONTRACTS.md — Context features / Discussions: cursor per repository; a wrong requested node or loop fails closed.
    func testGraphQLCursorLoopAndCrossOrganizationNodeBothFailClosed() async throws {
        let cursorSession = GitHubFeatureContractFixtures.Session(responses: [
            .init(body: GitHubFeatureContractFixtures.discussionPage(hasNextPage: true, endCursor: "repeat")),
            .init(body: GitHubFeatureContractFixtures.discussionPage(discussionNodeID: "D_2", discussionNumber: 2, hasNextPage: true, endCursor: "repeat"))
        ])
        let cursorClient = GitHubDiscussionClient(client: GitHubGraphQLClient(session: cursorSession, credential: SecretValue("fixture-token")))

        do {
            _ = try await cursorClient.allDiscussions(
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                githubOrganizationID: 7,
                validateScope: {}
            )
            XCTFail("A repeated cursor must not produce a complete discussion collection.")
        } catch let error as GitHubDiscussionClientError {
            guard case let .paginationLoop(rawPages) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(rawPages.count, 2)
        }

        let crossOrganizationSession = GitHubFeatureContractFixtures.Session(responses: [
            .init(body: GitHubFeatureContractFixtures.discussionPage(repositoryNodeID: "R_other", hasNextPage: false, endCursor: nil))
        ])
        let crossOrganizationClient = GitHubDiscussionClient(client: GitHubGraphQLClient(session: crossOrganizationSession, credential: SecretValue("fixture-token")))
        do {
            _ = try await crossOrganizationClient.allDiscussions(
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                githubOrganizationID: 7,
                validateScope: {}
            )
            XCTFail("A node returned for another requested identity must not be normalized.")
        } catch let error as GitHubDiscussionClientError {
            guard case let .missingRequestedRepository(rawPages) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(rawPages.count, 1)
        }
    }

    // GITHUB_FEATURE_CONTRACTS.md — Shared transport rules / GraphQL budget; Work discovery / issue and PR discovery incomplete-result handling.
    func testGraphQLConnectionCostBudgetAndIncompleteSearchFixturesRemainIncomplete() async throws {
        let costlySession = GitHubFeatureContractFixtures.Session(responses: [
            .init(body: GitHubFeatureContractFixtures.discussionPage(hasNextPage: false, endCursor: nil, cost: 501))
        ])
        let costlyClient = GitHubDiscussionClient(
            client: GitHubGraphQLClient(session: costlySession, credential: SecretValue("fixture-token"))
        )
        do {
            _ = try await costlyClient.allDiscussions(
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                githubOrganizationID: 7,
                validateScope: {}
            )
            XCTFail("A GraphQL page over the 500-point budget must not be normalized.")
        } catch let error as GitHubDiscussionClientError {
            guard case let .queryCostExceeded(rawPages) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(rawPages.count, 1)
        }

        let search = GitHubIssueSearchClient(client: try restClient(session: GitHubFeatureContractFixtures.Session(responses: [
            .init(body: GitHubFeatureContractFixtures.incompleteSearch)
        ])))
        let page = try await search.search(
            try GitHubIssueSearchQuery(
                organizationLogin: "acme",
                userLogin: "octocat",
                state: .open,
                relationship: .involves
            )
        )
        XCTAssertTrue(page.incompleteResults)
        XCTAssertEqual(page.totalCount, 1_001)
        XCTAssertTrue(page.items.isEmpty)
    }

    // GITHUB_FEATURE_CONTRACTS.md — Search 304 reuse and Timeline 304 reuse: cancellation/stale authority leaves prior state unchanged.
    func testStaleScopeCancellationAfterResponsePreventsCollectionPublication() async throws {
        let session = GitHubFeatureContractFixtures.Session(responses: [
            .init(body: GitHubFeatureContractFixtures.discussionPage(hasNextPage: false, endCursor: nil))
        ])
        let scope = GitHubFeatureContractFixtures.ScopeThatExpiresAfterNetworkResponse()
        let client = GitHubDiscussionClient(client: GitHubGraphQLClient(session: session, credential: SecretValue("fixture-token")))

        do {
            _ = try await client.allDiscussions(
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                githubOrganizationID: 7,
                validateScope: { try await scope.validate() }
            )
            XCTFail("A stale synchronization scope must cancel the traversal.")
        } catch is CancellationError {
            let requestCount = await session.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    // GITHUB_FEATURE_CONTRACTS.md — Shared transport rules: cancellation cannot publish decoded GraphQL state.
    func testExplicitTaskCancellationAfterNetworkStartAbortsGraphQLPublication() async throws {
        let session = GitHubFeatureContractFixtures.SuspendedSession()
        let client = GitHubGraphQLClient(session: session, credential: SecretValue("fixture-token"))
        let query = try GitHubGraphQLQueries.viewer()
        let task = Task {
            try await client.execute(
                query,
                variables: FixtureVariables(),
                as: FixtureViewerPayload.self
            )
        }
        await session.waitForRequest()
        task.cancel()
        await session.resume(body: GitHubFeatureContractFixtures.partialGraphQL)

        do {
            _ = try await task.value
            XCTFail("Cancellation after the response starts must prevent publication.")
        } catch is CancellationError {
            // Expected: GitHubGraphQLClient checks cancellation before decoding.
        }
    }

    // GITHUB_FEATURE_CONTRACTS.md — Shared transport rules and contract change rule 4: access errors are scoped evidence.
    func testRateLimitSSOApprovalAndRevokedCredentialFixturesStayScoped() async throws {
        let rateLimited = GitHubFailureClassifier.classify(
            GitHubRESTResponse(statusCode: 429, url: URL(string: "https://api.github.com/search/issues")!, headers: ["Retry-After": "60"], body: Data())
        )
        XCTAssertEqual(rateLimited?.kind, .rateLimited)
        XCTAssertEqual(rateLimited?.retryAfter, 60)

        let secondaryLimited = GitHubFailureClassifier.classify(
            GitHubRESTResponse(statusCode: 403, url: URL(string: "https://api.github.com/search/issues")!, headers: ["Retry-After": "30"], body: Data())
        )
        XCTAssertEqual(secondaryLimited?.kind, .secondaryRateLimited)
        XCTAssertEqual(secondaryLimited?.retryAfter, 30)

        let sso = GitHubFailureClassifier.classify(
            GitHubRESTResponse(statusCode: 403, url: URL(string: "https://api.github.com/orgs/acme")!, headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"], body: Data())
        )
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(statusCode: 403, ssoHeader: sso?.ssoHeader, accessRestriction: sso?.accessRestriction),
            .ssoAuthorizationRequired
        )
        let partial = GitHubSSOHeader(value: "partial-results; organizations=7")
        XCTAssertEqual(partial?.scoped(to: 7), .partialResults([7]))
        XCTAssertNil(partial?.scoped(to: 8))

        let approval = GitHubFailureClassifier.classify(
            GitHubRESTResponse(statusCode: 403, url: URL(string: "https://api.github.com/orgs/acme")!, headers: [:], body: Data(#"{"message":"Personal access token pending approval"}"#.utf8))
        )
        XCTAssertEqual(approval?.accessRestriction, .organizationApprovalRequired)
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(statusCode: 403, ssoHeader: nil, accessRestriction: approval?.accessRestriction),
            .organizationApprovalRequired
        )

        let revoked = GitHubFailure(kind: .unauthorized, statusCode: 401)
        XCTAssertEqual(CredentialLifecycle.failureStatus(for: revoked), .revoked)

        let inaccessible = GitHubFailureClassifier.classify(
            GitHubRESTResponse(statusCode: 404, url: URL(string: "https://api.github.com/repos/acme/private")!, headers: [:], body: Data())
        )
        XCTAssertEqual(inaccessible?.kind, .notFound)
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(statusCode: 404, ssoHeader: nil, accessRestriction: nil),
            .inaccessible
        )
    }

    // GITHUB_FEATURE_CONTRACTS.md — Repository inventory empty authority; Shared transport failure behavior; contract change rule 3 redacted diagnostics.
    func testEmptyInventoryAndUnavailableResponseAreNotEquivalentAndErrorsAreRedacted() async throws {
        let emptySession = GitHubFeatureContractFixtures.Session(responses: [.init(body: Data("[]".utf8))])
        let empty = try await repositoryClient(session: emptySession).allRepositories(in: "acme")
        XCTAssertTrue(empty.values.isEmpty)

        let secret = "ghp_fixture_secret_must_not_escape"
        let unavailableClient = try restClient(session: GitHubFeatureContractFixtures.Session(responses: [
            .init(statusCode: 403, body: Data(#"{"message":"\#(secret)"}"#.utf8))
        ]))
        do {
            _ = try await unavailableClient.get(GitHubRepositoryDTO.self, request: GitHubRESTRequest(path: "/orgs/acme/repos"))
            XCTFail("Unavailable access must not look like an empty inventory.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.kind, .forbidden)
            XCTAssertFalse(String(describing: failure).contains(secret))
        }
    }

    private func restClient(
        session: GitHubFeatureContractFixtures.Session
    ) throws -> GitHubRESTClient {
        GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("fixture-token")
        )
    }

    private func repositoryClient(
        session: GitHubFeatureContractFixtures.Session
    ) throws -> GitHubRepositoryTeamClient {
        GitHubRepositoryTeamClient(client: try restClient(session: session))
    }

    private func fixtureScope(credentialRevision: String) -> SynchronizationScope {
        SynchronizationScope(
            accountID: AccountID(rawValue: "fixture-account")!,
            organizationID: OrganizationID(rawValue: "fixture-organization")!,
            credentialRevision: CredentialRevision(rawValue: credentialRevision)!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-v1")!
        )
    }
}

private struct FixtureVariables: Codable, Sendable {}
private struct FixtureViewerPayload: Codable, Sendable { let viewer: FixtureViewer }
private struct FixtureViewer: Codable, Sendable { let login: String }
