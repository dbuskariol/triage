import XCTest
@testable import Triage

final class GitHubIdentityClientTests: XCTestCase {
    func testAuthenticatedUserRejectsRevokedAndMalformedIdentityWithoutYieldingAProfile() async throws {
        let revokedSession = IdentityFixtureSession(responses: [
            "/user": .init(statusCode: 401, body: Data(#"{"message":"Bad credentials"}"#.utf8))
        ])
        let revokedClient = try identityClient(session: revokedSession)

        do {
            _ = try await GitHubIdentityClient(client: revokedClient).authenticatedUser()
            XCTFail("A revoked credential must not yield a replacement profile.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.kind, .unauthorized)
        }
        let revokedPaths = await revokedSession.requestedPaths()
        XCTAssertEqual(revokedPaths, ["/user"])

        let malformedSession = IdentityFixtureSession(responses: [
            "/user": .init(statusCode: 200, body: Data(#"{"id":"not-a-number"}"#.utf8))
        ])
        let malformedClient = try identityClient(session: malformedSession)

        do {
            _ = try await GitHubIdentityClient(client: malformedClient).authenticatedUser()
            XCTFail("An invalid identity payload must not yield a profile to overwrite local state.")
        } catch let error as GitHubRESTClientError {
            XCTAssertEqual(error, .invalidJSON)
        }
        let malformedPaths = await malformedSession.requestedPaths()
        XCTAssertEqual(malformedPaths, ["/user"])
    }

    func testAuthenticatedUserEnforces256KiBBeforeDecode() async throws {
        let boundarySession = IdentityFixtureSession(responses: [
            "/user": .init(statusCode: 200, body: authenticatedUserPayload(totalBytes: 256 * 1_024))
        ])
        let boundary = try await GitHubIdentityClient(client: try identityClient(session: boundarySession))
            .authenticatedUser()
        XCTAssertEqual(boundary.payload.count, 256 * 1_024)

        let overflowSession = IdentityFixtureSession(responses: [
            "/user": .init(statusCode: 200, body: authenticatedUserPayload(totalBytes: 256 * 1_024 + 1))
        ])
        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: try self.identityClient(session: overflowSession))
                .authenticatedUser()
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .authenticatedUserResponseTooLarge)
        }
    }

    func testEmptyOrganizationPageIsASuccessfulInventoryRatherThanNegativeEvidence() async throws {
        let session = IdentityFixtureSession(responses: [
            "/user/orgs?per_page=100": .init(statusCode: 200, body: Data("[]".utf8))
        ])
        let client = try identityClient(session: session)

        let page = try await GitHubIdentityClient(client: client).organizations()

        XCTAssertTrue(page.values.isEmpty)
        XCTAssertNil(page.nextPageURL)
        XCTAssertNil(page.ssoHeader)
        let requestedPaths = await session.requestedPaths()
        XCTAssertEqual(requestedPaths, ["/user/orgs?per_page=100"])
    }

    func testOrganizationInventoryRejectsMoreThanOneHundredObjectsBeforeItCanPublish() async throws {
        let organizations = (1...101).map {
            "{\"id\":\($0),\"node_id\":\"O_\($0)\",\"login\":\"organization-\($0)\"}"
        }
        let session = IdentityFixtureSession(responses: [
            "/user/orgs?per_page=100": .init(
                statusCode: 200,
                body: Data("[\(organizations.joined(separator: ","))]".utf8)
            )
        ])

        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: try self.identityClient(session: session))
                .allOrganizations()
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .pageObjectLimitExceeded)
        }
    }

    func testSelectedOrganizationSSOAndApprovalFailuresRemainScopedToThatOrganization() async throws {
        let ssoSession = IdentityFixtureSession(responses: [
            "/orgs/acme": .init(
                statusCode: 403,
                body: Data(#"{"message":"SSO required"}"#.utf8),
                headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"]
            ),
            "/orgs/other": .init(
                statusCode: 200,
                body: Data(#"{"id":2,"node_id":"O_2","login":"other"}"#.utf8)
            )
        ])
        let ssoClient = try identityClient(session: ssoSession)
        let identity = GitHubIdentityClient(client: ssoClient)

        do {
            _ = try await identity.organization(named: "acme")
            XCTFail("SSO must block only the selected organization request.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.kind, .forbidden)
            XCTAssertEqual(
                failure.ssoHeader,
                .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso")!)
            )
        }
        let other = try await identity.organization(named: "other")
        XCTAssertEqual(other.value.login, "other")
        let ssoPaths = await ssoSession.requestedPaths()
        XCTAssertEqual(ssoPaths, ["/orgs/acme", "/orgs/other"])

        let approvalSession = IdentityFixtureSession(responses: [
            "/orgs/acme": .init(
                statusCode: 403,
                body: Data(#"{"message":"Personal access token pending approval"}"#.utf8)
            )
        ])
        let approvalClient = try identityClient(session: approvalSession)

        do {
            _ = try await GitHubIdentityClient(client: approvalClient).organization(named: "acme")
            XCTFail("Organization approval must remain an explicit access failure.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.accessRestriction, .organizationApprovalRequired)
        }
        let approvalPaths = await approvalSession.requestedPaths()
        XCTAssertEqual(approvalPaths, ["/orgs/acme"])
    }

    func testConditionalIdentityEndpointsPreserve304EvidenceAndExactETagAuthority() async throws {
        let validators = try GitHubHTTPValidators(eTag: "\"identity-v1\"", lastModified: nil)

        let userSession = IdentityFixtureSession(responses: [
            "/user": .init(statusCode: 304, body: Data())
        ])
        let userResult = try await GitHubIdentityClient(client: try identityClient(session: userSession))
            .fetchAuthenticatedUser(validators: validators)
        guard case .notModified = userResult else {
            return XCTFail("A conditional /user 304 must remain evidence, never a profile.")
        }
        let userETag = await userSession.requestedHeader(named: "If-None-Match")
        XCTAssertEqual(userETag, "\"identity-v1\"")

        let organizationsSession = IdentityFixtureSession(responses: [
            "/user/orgs?per_page=100": .init(statusCode: 304, body: Data())
        ])
        let organizationsResult = try await GitHubIdentityClient(client: try identityClient(session: organizationsSession))
            .fetchAllOrganizations(validators: validators)
        guard case .notModified = organizationsResult else {
            return XCTFail("A conditional /user/orgs 304 must not become an empty inventory.")
        }
        let organizationsETag = await organizationsSession.requestedHeader(named: "If-None-Match")
        XCTAssertEqual(organizationsETag, "\"identity-v1\"")

        let organizationSession = IdentityFixtureSession(responses: [
            "/orgs/acme": .init(statusCode: 304, body: Data())
        ])
        let organizationResult = try await GitHubIdentityClient(client: try identityClient(session: organizationSession))
            .fetchOrganization(named: "acme", validators: validators)
        guard case .notModified = organizationResult else {
            return XCTFail("A conditional selected-organization 304 must remain scoped evidence.")
        }
        let organizationETag = await organizationSession.requestedHeader(named: "If-None-Match")
        XCTAssertEqual(organizationETag, "\"identity-v1\"")
    }

    func testConditionalOrganization304PreservesScopedSSOEvidenceForReplayOwner() async throws {
        let validators = try GitHubHTTPValidators(eTag: "\"org-v1\"", lastModified: nil)
        let session = IdentityFixtureSession(responses: [
            "/orgs/acme": .init(
                statusCode: 304,
                body: Data(),
                headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"]
            )
        ])
        let result = try await GitHubIdentityClient(client: try identityClient(session: session))
            .fetchOrganization(named: "acme", validators: validators)
        guard case let .notModified(ssoHeader) = result else {
            return XCTFail("A 304 SSO header must remain scoped transport evidence.")
        }
        XCTAssertEqual(
            ssoHeader,
            .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso")!)
        )
    }

    func testOrganizationInventoryPaginatesAndAggregatesSSOHeaders() async throws {
        let secondPage = URL(string: "https://api.github.com/user/orgs?page=2&per_page=100")!
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/user/orgs?per_page=100": (
                        Data(#"[{"id":1,"node_id":"O_1","login":"first"}]"#.utf8),
                        [
                            "Link": "<\(secondPage.absoluteString)>; rel=\"next\"",
                            "X-GitHub-SSO": "partial-results; organizations=1"
                        ]
                    ),
                    "/user/orgs?page=2&per_page=100": (
                        Data(#"[{"id":2,"node_id":"O_2","login":"second"}]"#.utf8),
                        ["X-GitHub-SSO": "partial-results; organizations=2"]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let inventory = try await GitHubIdentityClient(client: client).allOrganizations()

        XCTAssertEqual(inventory.organizations.map(\.id), [1, 2])
        XCTAssertEqual(inventory.organizations.map(\.login), ["first", "second"])
        XCTAssertEqual(inventory.pages.count, 2)
        XCTAssertEqual(inventory.ssoHeader, .partialResults(Set([1, 2])))
    }

    func testOrganizationInventoryAcceptsExactAggregateResponseBudgetAcrossPages() async throws {
        let secondPage = URL(string: "https://api.github.com/user/orgs?page=2&per_page=100")!
        let firstPayload = organizationPayload(
            id: 1,
            nodeID: "O_BUDGET_1",
            login: "first",
            totalBytes: 512 * 1_024
        )
        let secondPayload = organizationPayload(
            id: 2,
            nodeID: "O_BUDGET_2",
            login: "second",
            totalBytes: 512 * 1_024
        )
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/user/orgs?per_page=100": (
                        firstPayload,
                        ["Link": "<\(secondPage.absoluteString)>; rel=\"next\""]
                    ),
                    "/user/orgs?page=2&per_page=100": (secondPayload, [:])
                ])
            ),
            credential: SecretValue("token")
        )

        let inventory = try await GitHubIdentityClient(client: client).allOrganizations()

        XCTAssertEqual(inventory.organizations.map(\.id), [1, 2])
        XCTAssertEqual(inventory.pages.map { $0.page.payload.count }, [512 * 1_024, 512 * 1_024])
    }

    func testOrganizationInventoryRejectsPageThatExceedsAggregateResponseBudget() async throws {
        let secondPage = URL(string: "https://api.github.com/user/orgs?page=2&per_page=100")!
        let firstPayload = organizationPayload(
            id: 1,
            nodeID: "O_BUDGET_1",
            login: "first",
            totalBytes: 512 * 1_024
        )
        let secondPayload = organizationPayload(
            id: 2,
            nodeID: "O_BUDGET_2",
            login: "second",
            totalBytes: 512 * 1_024 + 1
        )
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/user/orgs?per_page=100": (
                        firstPayload,
                        ["Link": "<\(secondPage.absoluteString)>; rel=\"next\""]
                    ),
                    "/user/orgs?page=2&per_page=100": (secondPayload, [:])
                ])
            ),
            credential: SecretValue("token")
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: client).allOrganizations()
        } verify: { error in
            XCTAssertEqual(
                error as? GitHubIdentityClientError,
                .organizationInventoryResponseTooLarge
            )
        }
    }

    func testSelectedOrganizationEnforcesEndpointSpecificResponseBudget() async throws {
        let boundarySession = IdentityFixtureSession(responses: [
            "/orgs/acme": .init(
                statusCode: 200,
                body: organizationPayload(
                    id: 1,
                    nodeID: "O_SELECTED",
                    login: "acme",
                    totalBytes: 256 * 1_024,
                    asArray: false
                )
            )
        ])
        let boundary = try await GitHubIdentityClient(client: try identityClient(session: boundarySession))
            .organization(named: "acme")
        XCTAssertEqual(boundary.value.login, "acme")
        XCTAssertEqual(boundary.payload.count, 256 * 1_024)

        let overflowSession = IdentityFixtureSession(responses: [
            "/orgs/acme": .init(
                statusCode: 200,
                body: organizationPayload(
                    id: 1,
                    nodeID: "O_SELECTED",
                    login: "acme",
                    totalBytes: 256 * 1_024 + 1,
                    asArray: false
                )
            )
        ])

        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: try self.identityClient(session: overflowSession))
                .organization(named: "acme")
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .organizationResponseTooLarge)
        }
    }

    func testOrganizationInventoryRejectsDuplicateOrMalformedPaginationBeforeCompleteReceiptCanExist() async throws {
        let secondPage = URL(string: "https://api.github.com/user/orgs?page=2&per_page=100")!
        let duplicateClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/user/orgs?per_page=100": (
                        Data(#"[{"id":1,"node_id":"O_1","login":"first"}]"#.utf8),
                        ["Link": "<\(secondPage.absoluteString)>; rel=\"next\""]
                    ),
                    "/user/orgs?page=2&per_page=100": (
                        Data(#"[{"id":1,"node_id":"O_1","login":"first"}]"#.utf8), [:]
                    )
                ])
            ),
            credential: SecretValue("token")
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: duplicateClient).allOrganizations()
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .duplicateOrganization)
        }

        let malformedClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/user/orgs?per_page=100": (
                        Data(#"[]"#.utf8),
                        ["Link": "this is not a GitHub Link header"]
                    )
                ])
            ),
            credential: SecretValue("token")
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: malformedClient).allOrganizations()
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .invalidPaginationLink)
        }
    }

    func testOrganizationInventoryRejectsPaginationLoops() async throws {
        let loopURL = URL(string: "https://api.github.com/user/orgs?page=2&per_page=100")!
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/user/orgs?per_page=100": (
                        Data(#"[{"id":1,"node_id":"O_1","login":"first"}]"#.utf8),
                        ["Link": "<\(loopURL.absoluteString)>; rel=\"next\""]
                    ),
                    "/user/orgs?page=2&per_page=100": (
                        Data(#"[{"id":2,"node_id":"O_2","login":"second"}]"#.utf8),
                        ["Link": "<\(loopURL.absoluteString)>; rel=\"next\""]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: client).allOrganizations()
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .invalidPaginationLink)
        }
    }

    func testRepositoryInventoryRetainsSSOHeadersAcrossPages() async throws {
        let secondPage = URL(string: "https://api.github.com/orgs/acme/repos?type=all&page=2&per_page=100")!
        let repository = """
        {"id":1,"node_id":"R_1","name":"one","private":true,"archived":false,"has_discussions":true,
        "html_url":"https://github.com/acme/one","updated_at":"2025-01-01T00:00:00Z",
        "owner":{"login":"acme"}}
        """
        let secondRepository = """
        {"id":2,"node_id":"R_2","name":"two","private":true,"archived":false,"has_discussions":true,
        "html_url":"https://github.com/acme/two","updated_at":"2025-01-01T00:00:00Z",
        "owner":{"login":"acme"}}
        """
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/orgs/acme/repos?type=all&per_page=100": (
                        Data("[\(repository)]".utf8),
                        [
                            "Link": "<\(secondPage.absoluteString)>; rel=\"next\"",
                            "X-GitHub-SSO": "partial-results; organizations=1"
                        ]
                    ),
                    "/orgs/acme/repos?type=all&page=2&per_page=100": (
                        Data("[\(secondRepository)]".utf8),
                        ["X-GitHub-SSO": "partial-results; organizations=2"]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let inventory = try await GitHubIdentityClient(client: client).allRepositories(in: "acme")

        XCTAssertEqual(inventory.repositories.map(\.nodeID), ["R_1", "R_2"])
        XCTAssertTrue(inventory.repositories.allSatisfy { $0.hasDiscussions == true })
        XCTAssertEqual(inventory.ssoHeader, .partialResults(Set([1, 2])))
    }

    func testRepositoryInventoryAcceptsAnOmittedDiscussionsField() async throws {
        let repository = """
        [{"id":1,"node_id":"R_1","name":"one","private":true,"archived":false,
        "html_url":"https://github.com/acme/one","updated_at":"2025-01-01T00:00:00Z",
        "owner":{"login":"acme"}}]
        """
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PagingSession(responses: [
                    "/orgs/acme/repos?type=all&per_page=100": (Data(repository.utf8), [:])
                ])
            ),
            credential: SecretValue("token")
        )

        let inventory = try await GitHubIdentityClient(client: client).allRepositories(in: "acme")

        XCTAssertEqual(inventory.repositories.map(\.hasDiscussions), [nil])
    }

    func testRepositoryInventoryUsesOnlyTheExactGitHubAuthorityPathAndPageQuery() async throws {
        let secondPage = "https://api.github.com/orgs/acme/repos?type=all&page=2&per_page=100"
        let firstRepository = repository(id: 1, nodeID: "R_1", name: "one")
        let secondRepository = repository(id: 2, nodeID: "R_2", name: "two")
        let session = IdentityFixtureSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": .init(
                statusCode: 200,
                body: Data("[\(firstRepository)]".utf8),
                headers: ["Link": "<\(secondPage)>; rel=\"next\""]
            ),
            "/orgs/acme/repos?type=all&page=2&per_page=100": .init(
                statusCode: 200,
                body: Data("[\(secondRepository)]".utf8)
            )
        ])

        let inventory = try await GitHubIdentityClient(client: try identityClient(session: session))
            .allRepositories(in: "acme")

        XCTAssertEqual(inventory.repositories.map(\.id), [1, 2])
        let requestedPaths = await session.requestedPaths()
        XCTAssertEqual(requestedPaths, [
            "/orgs/acme/repos?type=all&per_page=100",
            "/orgs/acme/repos?type=all&page=2&per_page=100"
        ])
    }

    func testRepositoryInventoryRejectsHostilePaginationWithoutFollowingIt() async throws {
        let hostileLinks = [
            "https://api.github.com/orgs/acme/repos?page=2&per_page=100",
            "https://api.github.com/orgs/acme/repos?type=all&page=3&per_page=100",
            "https://api.github.com/orgs/other/repos?type=all&page=2&per_page=100",
            "https://github.com/orgs/acme/repos?type=all&page=2&per_page=100"
        ]

        for link in hostileLinks {
            let session = IdentityFixtureSession(responses: [
                "/orgs/acme/repos?type=all&per_page=100": .init(
                    statusCode: 200,
                    body: Data("[]".utf8),
                    headers: ["Link": "<\(link)>; rel=\"next\""]
                )
            ])

            await XCTAssertThrowsErrorAsync {
                _ = try await GitHubIdentityClient(client: try self.identityClient(session: session))
                    .allRepositories(in: "acme")
            } verify: { error in
                XCTAssertEqual(error as? GitHubIdentityClientError, .invalidPaginationLink)
            }
            let requestedPaths = await session.requestedPaths()
            XCTAssertEqual(requestedPaths, ["/orgs/acme/repos?type=all&per_page=100"])
        }
    }

    func testRepositoryInventoryRejectsOversizedPagesAndAggregatePayloadsBeforePublication() async throws {
        let oversizedSession = IdentityFixtureSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": .init(
                statusCode: 200,
                body: paddedEmptyJSONPage(totalBytes: 2 * 1_024 * 1_024 + 1)
            )
        ])
        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: try self.identityClient(session: oversizedSession))
                .allRepositories(in: "acme")
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .repositoryInventoryResponseTooLarge)
        }

        let secondPage = "https://api.github.com/orgs/acme/repos?type=all&page=2&per_page=100"
        let thirdPage = "https://api.github.com/orgs/acme/repos?type=all&page=3&per_page=100"
        let aggregateSession = IdentityFixtureSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": .init(
                statusCode: 200,
                body: paddedEmptyJSONPage(totalBytes: 2 * 1_024 * 1_024),
                headers: ["Link": "<\(secondPage)>; rel=\"next\""]
            ),
            "/orgs/acme/repos?type=all&page=2&per_page=100": .init(
                statusCode: 200,
                body: paddedEmptyJSONPage(totalBytes: 2 * 1_024 * 1_024),
                headers: ["Link": "<\(thirdPage)>; rel=\"next\""]
            ),
            "/orgs/acme/repos?type=all&page=3&per_page=100": .init(statusCode: 200, body: Data("[]".utf8))
        ])
        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: try self.identityClient(session: aggregateSession))
                .allRepositories(in: "acme")
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .repositoryInventoryResponseTooLarge)
        }
    }

    func testRepositoryInventoryRejectsOversizedDuplicateAndMalformedPages() async throws {
        let repositories = (1...101).map {
            repository(id: UInt64($0), nodeID: "R_\($0)", name: "repository-\($0)")
        }
        let objectLimitSession = IdentityFixtureSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": .init(
                statusCode: 200,
                body: Data("[\(repositories.joined(separator: ","))]".utf8)
            )
        ])
        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: try self.identityClient(session: objectLimitSession))
                .allRepositories(in: "acme")
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .pageObjectLimitExceeded)
        }

        let duplicate = repository(id: 1, nodeID: "R_1", name: "one")
        let duplicateSession = IdentityFixtureSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": .init(
                statusCode: 200,
                body: Data("[\(duplicate),\(duplicate)]".utf8)
            )
        ])
        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: try self.identityClient(session: duplicateSession))
                .allRepositories(in: "acme")
        } verify: { error in
            XCTAssertEqual(error as? GitHubIdentityClientError, .duplicateRepository)
        }

        let nullSession = IdentityFixtureSession(responses: [
            "/orgs/acme/repos?type=all&per_page=100": .init(statusCode: 200, body: Data("[null]".utf8))
        ])
        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubIdentityClient(client: try self.identityClient(session: nullSession))
                .allRepositories(in: "acme")
        } verify: { error in
            XCTAssertEqual(error as? GitHubRESTClientError, .invalidJSON)
        }
    }

    func testRepositoryInventoryPropagatesCancellationRatherThanPublishingTheFirstPage() async throws {
        let secondPage = "https://api.github.com/orgs/acme/repos?type=all&page=2&per_page=100"
        let session = CancellingRepositoryInventorySession(nextPageURL: secondPage)
        let client = GitHubIdentityClient(client: GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token")
        ))

        do {
            _ = try await client.allRepositories(in: "acme")
            XCTFail("A cancelled repository traversal must not publish its first page.")
        } catch is CancellationError {
            // Expected.
        }
        let requestCount = await session.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    private func identityClient(session: IdentityFixtureSession) throws -> GitHubRESTClient {
        GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token")
        )
    }

    private func organizationPayload(
        id: UInt64,
        nodeID: String,
        login: String,
        totalBytes: Int,
        asArray: Bool = true
    ) -> Data {
        let prefix = asArray
            ? "[{\"id\":\(id),\"node_id\":\"\(nodeID)\",\"login\":\"\(login)\",\"padding\":\""
            : "{\"id\":\(id),\"node_id\":\"\(nodeID)\",\"login\":\"\(login)\",\"padding\":\""
        let suffix = asArray ? "\"}]" : "\"}"
        let paddingLength = totalBytes - Data((prefix + suffix).utf8).count
        precondition(paddingLength >= 0)
        let payload = Data((prefix + String(repeating: "x", count: paddingLength) + suffix).utf8)
        precondition(payload.count == totalBytes)
        return payload
    }

    private func authenticatedUserPayload(totalBytes: Int) -> Data {
        let prefix = #"{"id":1,"node_id":"U_1","login":"octocat","padding":""#
        let suffix = #""}"#
        let paddingLength = totalBytes - Data((prefix + suffix).utf8).count
        precondition(paddingLength >= 0)
        let payload = Data((prefix + String(repeating: "x", count: paddingLength) + suffix).utf8)
        precondition(payload.count == totalBytes)
        return payload
    }

    private func repository(id: UInt64, nodeID: String, name: String) -> String {
        """
        {"id":\(id),"node_id":"\(nodeID)","name":"\(name)","private":true,"archived":false,
        "has_discussions":true,"html_url":"https://github.com/acme/\(name)",
        "updated_at":"2025-01-01T00:00:00Z","owner":{"login":"acme"}}
        """
    }

    private func paddedEmptyJSONPage(totalBytes: Int) -> Data {
        precondition(totalBytes >= 2)
        let payload = Data(("[]" + String(repeating: " ", count: totalBytes - 2)).utf8)
        precondition(payload.count == totalBytes)
        return payload
    }
}

private actor IdentityFixtureSession: HTTPSession {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    private let responses: [String: Response]
    private var paths = [String]()
    private var requests = [URLRequest]()

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let path = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard let response = responses[path] else { throw URLError(.resourceUnavailable) }
        paths.append(path)
        requests.append(request)
        return (
            response.body,
            HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
            )!
        )
    }

    func requestedPaths() -> [String] {
        paths
    }

    func requestedHeader(named name: String) -> String? {
        requests.last?.value(forHTTPHeaderField: name)
    }
}

private actor PagingSession: HTTPSession {
    private let responses: [String: (Data, [String: String])]

    init(responses: [String: (Data, [String: String])]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let pathAndQuery = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard let response = responses[pathAndQuery] else {
            throw URLError(.resourceUnavailable)
        }
        return (
            response.0,
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: response.1
            )!
        )
    }
}

private actor CancellingRepositoryInventorySession: HTTPSession {
    private let nextPageURL: String
    private var requests = 0

    init(nextPageURL: String) {
        self.nextPageURL = nextPageURL
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        if requests == 1 {
            return (
                Data("[]".utf8),
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Link": "<\(nextPageURL)>; rel=\"next\""]
                )!
            )
        }
        throw CancellationError()
    }

    func requestCount() -> Int {
        requests
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        verify(error)
    }
}
