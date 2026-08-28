import XCTest
@testable import Triage

final class GitHubCapabilityProbeTests: XCTestCase {
    func testProbeRejectsAnOrganizationWhoseImmutableIdentityChanged() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: SequencedProbeSession(responses: [
                    response(#"{"id":2,"node_id":"O_2","login":"acme"}"#)
                ])
            ),
            credential: SecretValue("token")
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await GitHubCapabilityProbe(
                identityClient: GitHubIdentityClient(client: client)
            ).probe(organization: organization())
        } verify: { error in
            XCTAssertEqual(error as? GitHubCapabilityProbeError, .organizationIdentityMismatch)
        }
    }

    func testProbeIgnoresPartialSSOHeaderForADifferentOrganization() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: SequencedProbeSession(responses: [
                    response(
                        #"{"id":1,"node_id":"O_1","login":"acme"}"#,
                        headers: ["X-GitHub-SSO": "partial-results; organizations=2"]
                    ),
                    response("[]")
                ])
            ),
            credential: SecretValue("token")
        )

        let result = try await GitHubCapabilityProbe(
            identityClient: GitHubIdentityClient(client: client)
        ).probe(organization: organization())

        XCTAssertEqual(result.accessState, .available)
        XCTAssertNil(result.ssoHeader)
    }

    func testProbeCombinesPartialSSOHeadersBeforeScopingTheSelectedOrganization() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: SequencedProbeSession(responses: [
                    response(
                        #"{"id":1,"node_id":"O_1","login":"acme"}"#,
                        headers: ["X-GitHub-SSO": "partial-results; organizations=2"]
                    ),
                    response(
                        "[]",
                        headers: ["X-GitHub-SSO": "partial-results; organizations=1"]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let result = try await GitHubCapabilityProbe(
            identityClient: GitHubIdentityClient(client: client)
        ).probe(organization: organization())

        XCTAssertEqual(result.accessState, .partialSSOAuthorization)
        XCTAssertEqual(result.ssoHeader, .partialResults(Set([1])))
    }

    func testProbeRecordsIndependentAvailableAndUnavailableCapabilities() async throws {
        let repository = """
        [{"id":1,"node_id":"R_1","name":"one","private":true,"archived":false,
        "html_url":"https://github.com/acme/one","updated_at":"2025-01-01T00:00:00Z",
        "owner":{"login":"acme"}}]
        """
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: SequencedProbeSession(responses: [
                    response(#"{"id":1,"node_id":"O_1","login":"acme"}"#),
                    response(repository),
                    response("[{}]"),
                    response(#"{"total_count":0,"incomplete_results":false,"items":[]}"#),
                    response(#"[{"number":1}]"#),
                    response("[]"),
                    response(#"{"users":[],"teams":[]}"#),
                    response("[]")
                ])
            ),
            credential: SecretValue("token")
        )

        let result = try await GitHubCapabilityProbe(
            identityClient: GitHubIdentityClient(client: client),
            restClient: client
        ).probe(organization: organization(), accountLogin: "octocat")

        XCTAssertEqual(result.accessState, .available)
        XCTAssertEqual(result.capabilities.status(for: .privateRepositories), .available)
        XCTAssertEqual(result.capabilities.status(for: .visibleTeams), .available)
        XCTAssertEqual(result.capabilities.status(for: .issueAndPullRequestSearch), .available)
        XCTAssertEqual(result.capabilities.status(for: .pullRequestReviews), .available)
        XCTAssertEqual(result.capabilities.status(for: .issueTimeline), .available)
        XCTAssertFalse(result.capabilities.contains { $0.capability == .notifications })
        XCTAssertEqual(result.capabilities.status(for: .pullRequestReviewThreads), .unavailable)
        XCTAssertEqual(result.capabilities.status(for: .discussions), .unavailable)
        XCTAssertEqual(result.capabilities.status(for: .projects), .unavailable)
        XCTAssertEqual(result.capabilities.status(for: .projectFields), .unavailable)
        XCTAssertEqual(result.capabilities.status(for: .copilot), .unavailable)
        XCTAssertEqual(result.capabilities.status(for: .copilotModels), .unavailable)
    }

    func testProbeRecordsAccountScopedNotificationCapabilityIndependently() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: SequencedProbeSession(responses: [
                    response("[]")
                ])
            ),
            credential: SecretValue("token")
        )

        let capabilities = try await GitHubCapabilityProbe(
            identityClient: GitHubIdentityClient(client: client),
            restClient: client
        ).probeAccountCapabilities()

        XCTAssertEqual(capabilities.status(for: .notifications), .available)
    }

    func testProbeRecordsAccountScopedNotificationSSORequirement() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: SequencedProbeSession(responses: [
                    response(
                        "[]",
                        headers: ["X-GitHub-SSO": "partial-results; organizations=1"]
                    )
                ])
            ),
            credential: SecretValue("token")
        )

        let capabilities = try await GitHubCapabilityProbe(
            identityClient: GitHubIdentityClient(client: client),
            restClient: client
        ).probeAccountCapabilities()

        XCTAssertEqual(capabilities.status(for: .notifications), .requiresSSO)
    }

    func testProbeMakesExplicitOrganizationPolicyBlockUnavailable() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: RestrictedProbeSession(
                    body: #"{"message":"Blocked due to organization policy"}"#
                )
            ),
            credential: SecretValue("token")
        )

        let result = try await GitHubCapabilityProbe(
            identityClient: GitHubIdentityClient(client: client)
        ).probe(organization: organization())

        XCTAssertEqual(result.accessState, .organizationPolicyBlocked)
        XCTAssertTrue(result.capabilities.allSatisfy { $0.status == .unavailable })
    }

    func testProbeMakesExplicitOAuthApprovalRequirementVisibleInCoverage() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: RestrictedProbeSession(
                    body: #"{"message":"This organization has enabled OAuth App access restrictions."}"#
                )
            ),
            credential: SecretValue("token")
        )

        let result = try await GitHubCapabilityProbe(
            identityClient: GitHubIdentityClient(client: client)
        ).probe(organization: organization())

        XCTAssertEqual(result.accessState, .oauthApplicationApprovalRequired)
        XCTAssertEqual(result.capabilities.status(for: .privateRepositories), .requiresApproval)
    }

    private func organization() -> GitHubOrganization {
        GitHubOrganization(
            id: OrganizationID(rawValue: "O_1")!,
            githubOrganizationID: 1,
            nodeID: GitHubNodeID(rawValue: "O_1")!,
            login: "acme"
        )
    }

    private func response(
        _ body: String,
        headers: [String: String] = [:]
    ) -> (Data, [String: String]) {
        (Data(body.utf8), headers)
    }
}

private extension Array where Element == CapabilityAvailability {
    func status(for capability: GitHubCapability) -> CapabilityStatus? {
        first(where: { $0.capability == capability })?.status
    }
}

private actor SequencedProbeSession: HTTPSession {
    private var responses: [(Data, [String: String])]

    init(responses: [(Data, [String: String])]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !responses.isEmpty, let url = request.url else {
            throw URLError(.resourceUnavailable)
        }
        let response = responses.removeFirst()
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

private actor RestrictedProbeSession: HTTPSession {
    private let body: Data

    init(body: String) {
        self.body = Data(body.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.resourceUnavailable)
        }
        return (
            body,
            HTTPURLResponse(
                url: url,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
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
