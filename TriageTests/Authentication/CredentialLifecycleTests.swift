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
            CredentialLifecycle.failureStatus(for: OAuthCredentialRefreshError.vaultKeyUnavailable),
            .missing
        )
        XCTAssertNil(
            CredentialLifecycle.failureStatus(for: OAuthCredentialRefreshError.staleAccountAuthority)
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

    func testRestorationMarksMissingCredentialBeforeSync() {
        XCTAssertEqual(
            CredentialLifecycle.restoredStatus(
                for: makeAccount(accessTokenExpiresAt: now.addingTimeInterval(60 * 60)),
                hasAccessToken: false,
                at: now
            ),
            .missing
        )
    }

    func testRestorationPreservesExplicitRevocation() {
        let revokedAccount = makeAccount(
            accessTokenExpiresAt: now.addingTimeInterval(60 * 60)
        ).replacingCredentialStatus(.revoked)

        XCTAssertEqual(
            CredentialLifecycle.restoredStatus(for: revokedAccount, hasAccessToken: true, at: now),
            .revoked
        )
    }

    func testRestorationSurfacesTokenExpiration() {
        XCTAssertEqual(
            CredentialLifecycle.restoredStatus(
                for: makeAccount(accessTokenExpiresAt: now.addingTimeInterval(60)),
                hasAccessToken: true,
                at: now
            ),
            .expiring
        )
    }

    func testNonOAuthCredentialsRemainActiveRegardlessOfExpirationMetadata() {
        XCTAssertEqual(
            CredentialLifecycle.status(
                authenticationKind: .classicPersonalAccessToken,
                accessTokenExpiresAt: now.addingTimeInterval(-1),
                refreshTokenExpiresAt: now.addingTimeInterval(-1),
                at: now
            ),
            .active
        )
    }

    func testPermanentAndTransientBrokerFailuresHaveDistinctCredentialEffects() {
        XCTAssertEqual(
            CredentialLifecycle.failureStatus(
                for: AuthBrokerClientError.broker(
                    AuthBrokerFailure(code: .authorizationDenied, recoveryDescription: "Denied")
                )
            ),
            .revoked
        )
        XCTAssertNil(
            CredentialLifecycle.failureStatus(
                for: AuthBrokerClientError.broker(
                    AuthBrokerFailure(code: .invalidClient, recoveryDescription: "Retry later")
                )
            )
        )
    }

    func testRestorationPreservesCapabilityLimitedStatus() {
        let account = makeAccount(accessTokenExpiresAt: now.addingTimeInterval(60 * 60))
            .replacingCredentialStatus(.capabilityLimited)

        XCTAssertEqual(
            CredentialLifecycle.restoredStatus(for: account, hasAccessToken: true, at: now),
            .capabilityLimited
        )
        XCTAssertNil(CredentialLifecycle.reconnectMessage(for: .capabilityLimited))
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
