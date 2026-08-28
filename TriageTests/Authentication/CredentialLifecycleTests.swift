import XCTest
@testable import Triage

final class CredentialLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    func testOAuthCredentialsApproachingAccessExpirationAreExpiring() {
        let account = makeAccount(
            accessTokenExpiresAt: now.addingTimeInterval(CredentialLifecycle.expirationWarningInterval)
        )

        XCTAssertEqual(CredentialLifecycle.status(for: account, at: now), .expiring)
    }

    func testExpiredRefreshTokenCannotRemainActive() {
        let account = makeAccount(
            accessTokenExpiresAt: now.addingTimeInterval(60 * 60),
            refreshTokenExpiresAt: now
        )

        XCTAssertEqual(CredentialLifecycle.status(for: account, at: now), .expired)
    }

    func testKnownCredentialFailuresRequireReconnect() {
        XCTAssertEqual(
            CredentialLifecycle.failureStatus(for: AccountCredentialReaderError.missingAccessToken),
            .missing
        )
        XCTAssertEqual(
            CredentialLifecycle.failureStatus(for: OAuthCredentialRefreshError.refreshTokenUnavailable),
            .expired
        )
        XCTAssertEqual(
            CredentialLifecycle.failureStatus(
                for: GitHubFailure(kind: .unauthorized, statusCode: 401)
            ),
            .revoked
        )
    }

    func testTransientBrokerFailuresDoNotRevokeCredentials() {
        let error = AuthBrokerClientError.broker(
            AuthBrokerFailure(code: .temporarilyUnavailable, recoveryDescription: "Try again later.")
        )

        XCTAssertNil(CredentialLifecycle.failureStatus(for: error))
    }

    private func makeAccount(
        accessTokenExpiresAt: Date?,
        refreshTokenExpiresAt: Date? = nil
    ) -> GitHubAccount {
        GitHubAccount(
            id: AccountID(rawValue: "account-1")!,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_kgDOExample")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID(rawValue: "credential-1")!,
            credentialStatus: .active,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            createdAt: now,
            lastValidatedAt: now
        )
    }
}
