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
