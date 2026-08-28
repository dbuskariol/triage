import XCTest
@testable import Triage

final class AuthBrokerProtocolTests: XCTestCase {
    func testExchangeRequestRoundTripsWithoutLeakingSecretInDescription() throws {
        let verifier = try XCTUnwrap(
            OAuthCodeVerifier(rawValue: String(repeating: "a", count: 43))
        )
        let request = AuthBrokerExchangeRequest(
            authorizationCode: OAuthAuthorizationCode("secret-code"),
            codeVerifier: verifier,
            redirectURI: try XCTUnwrap(URL(string: "triage://oauth-callback"))
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(AuthBrokerExchangeRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertFalse(String(describing: request.authorizationCode).contains("secret-code"))
        XCTAssertFalse(String(describing: request.codeVerifier).contains(String(repeating: "a", count: 43)))
    }

    func testTokenResponsePreservesOAuthExpirationMetadata() {
        let response = AuthBrokerTokenResponse(
            accessToken: OAuthAccessToken("access"),
            refreshToken: OAuthRefreshToken("refresh"),
            tokenType: "bearer",
            scope: "repo read:org",
            expiresIn: 28_800,
            refreshTokenExpiresIn: 15_552_000
        )

        XCTAssertEqual(response.version, AuthBrokerProtocol.version)
        XCTAssertEqual(response.expiresIn, 28_800)
        XCTAssertEqual(response.refreshTokenExpiresIn, 15_552_000)
    }
}
