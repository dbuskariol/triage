import XCTest
@testable import Triage

final class GitHubOAuthTests: XCTestCase {
    private let redirectURI = URL(string: "triage://oauth-callback")!

    func testAuthorizationRequestUsesS256PKCEAndRequiredScopes() throws {
        let configuration = try GitHubOAuthConfiguration(
            clientID: "client-id",
            redirectURI: redirectURI
        )
        let session = try OAuthAuthorizationSession.make(configuration: configuration)
        let query = try XCTUnwrap(
            URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
        )

        XCTAssertEqual(session.authorizationURL.scheme, "https")
        XCTAssertEqual(session.authorizationURL.host, "github.com")
        XCTAssertEqual(query.value(named: "client_id"), "client-id")
        XCTAssertEqual(query.value(named: "redirect_uri"), redirectURI.absoluteString)
        XCTAssertEqual(query.value(named: "code_challenge_method"), "S256")
        XCTAssertEqual(query.value(named: "prompt"), "select_account")
        XCTAssertEqual(query.value(named: "scope"), "repo read:org offline_access")
        XCTAssertEqual(query.value(named: "code_challenge")?.count, 43)
    }

    func testCallbackRequiresTheExactStateAndCallbackRoute() throws {
        let configuration = try GitHubOAuthConfiguration(
            clientID: "client-id",
            redirectURI: redirectURI
        )
        let session = try OAuthAuthorizationSession.make(configuration: configuration)
        let success = URL(
            string: "triage://oauth-callback?code=authorization-code&state=\(session.state.rawValue)"
        )!

        XCTAssertEqual(
            try session.authorizationCode(from: success, redirectURI: redirectURI).value.rawValue,
            "authorization-code"
        )
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(string: "triage://oauth-callback?code=code&state=wrong")!,
                redirectURI: redirectURI
            )
        )
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(string: "triage://different?code=code&state=\(session.state.rawValue)")!,
                redirectURI: redirectURI
            )
        )
    }

    func testCallbackRejectsAmbiguousOrMissingAuthorizationParameters() throws {
        let configuration = try GitHubOAuthConfiguration(
            clientID: "client-id",
            redirectURI: redirectURI
        )
        let session = try OAuthAuthorizationSession.make(configuration: configuration)

        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(
                    string: "triage://oauth-callback?code=code&state=\(session.state.rawValue)&state=attacker"
                )!,
                redirectURI: redirectURI
            )
        ) { error in
            XCTAssertEqual(error as? GitHubOAuthError, .invalidState)
        }
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(
                    string: "triage://oauth-callback?code=code&state=\(session.state.rawValue)&state"
                )!,
                redirectURI: redirectURI
            )
        ) { error in
            XCTAssertEqual(error as? GitHubOAuthError, .invalidState)
        }
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(
                    string: "triage://oauth-callback?code=code&code=attacker&state=\(session.state.rawValue)"
                )!,
                redirectURI: redirectURI
            )
        ) { error in
            XCTAssertEqual(error as? GitHubOAuthError, .missingAuthorizationCode)
        }
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(
                    string: "triage://oauth-callback?code=code&code&state=\(session.state.rawValue)"
                )!,
                redirectURI: redirectURI
            )
        ) { error in
            XCTAssertEqual(error as? GitHubOAuthError, .missingAuthorizationCode)
        }
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(string: "triage://oauth-callback?state=\(session.state.rawValue)")!,
                redirectURI: redirectURI
            )
        ) { error in
            XCTAssertEqual(error as? GitHubOAuthError, .missingAuthorizationCode)
        }
    }

    func testConfigurationRejectsASecretlessOrUntrustedAuthorizationEndpoint() {
        XCTAssertThrowsError(
            try GitHubOAuthConfiguration(
                clientID: "",
                redirectURI: redirectURI
            )
        )
        XCTAssertThrowsError(
            try GitHubOAuthConfiguration(
                clientID: "client-id",
                authorizationEndpoint: URL(string: "https://example.com/authorize")!,
                redirectURI: redirectURI
            )
        )
    }

    func testStaleCancellationGenerationCannotFinishNewAuthorization() {
        var generation = OAuthAuthorizationGeneration()
        let cancelledAuthorization = generation.begin()

        XCTAssertTrue(generation.finish(cancelledAuthorization))

        let currentAuthorization = generation.begin()
        XCTAssertFalse(generation.finish(cancelledAuthorization))
        XCTAssertTrue(generation.isCurrent(currentAuthorization))
    }
}

private extension Array where Element == URLQueryItem {
    func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}
