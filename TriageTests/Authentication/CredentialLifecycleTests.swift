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

    func testPersonalAccessTokensWarnAWeekAheadAndExpireAtTheirDeadline() {
        func status(_ offset: TimeInterval?) -> CredentialStatus {
            CredentialLifecycle.status(
                authenticationKind: .classicPersonalAccessToken,
                accessTokenExpiresAt: offset.map { now.addingTimeInterval($0) },
                refreshTokenExpiresAt: nil,
                at: now
            )
        }
        XCTAssertEqual(status(nil), .active)
        XCTAssertEqual(status(8 * 24 * 3_600), .active)
        XCTAssertEqual(status(6 * 24 * 3_600), .expiring)
        XCTAssertEqual(status(0), .expired)
        XCTAssertEqual(status(-1), .expired)
    }

    func testAcceptedResponseRecordsAPersonalAccessTokenExpiration() throws {
        let account = makeAccount(accessTokenExpiresAt: nil, kind: .fineGrainedPersonalAccessToken)
        let expiresAt = now.addingTimeInterval(3 * 24 * 3_600)
        let updated = try XCTUnwrap(
            CredentialLifecycle.account(account, observing: .accepted(expiresAt: expiresAt), at: now)
        )
        XCTAssertEqual(updated.accessTokenExpiresAt, expiresAt)
        XCTAssertEqual(updated.credentialStatus, .expiring)
        XCTAssertNil(CredentialLifecycle.account(updated, observing: .accepted(expiresAt: expiresAt), at: now))
    }

    func testRejectionIsExpiredPastTheDeadlineAndRevokedBeforeIt() throws {
        let expired = makeAccount(accessTokenExpiresAt: now.addingTimeInterval(-60), kind: .classicPersonalAccessToken)
        XCTAssertEqual(CredentialLifecycle.account(expired, observing: .rejected, at: now)?.credentialStatus, .expired)
        let revoked = makeAccount(accessTokenExpiresAt: nil, kind: .classicPersonalAccessToken)
        XCTAssertEqual(CredentialLifecycle.account(revoked, observing: .rejected, at: now)?.credentialStatus, .revoked)
    }

    func testAcceptanceClearsAnEarlierRejection() throws {
        let account = makeAccount(accessTokenExpiresAt: nil, kind: .classicPersonalAccessToken)
            .replacingCredentialStatus(.revoked)
        let updated = try XCTUnwrap(CredentialLifecycle.account(account, observing: .accepted(expiresAt: nil), at: now))
        XCTAssertEqual(updated.credentialStatus, .active)
    }

    func testOAuthKeepsTheExpirationFromItsTokenExchange() {
        let expiresAt = now.addingTimeInterval(60 * 60)
        let account = makeAccount(accessTokenExpiresAt: expiresAt)
        XCTAssertNil(CredentialLifecycle.account(account, observing: .accepted(expiresAt: now), at: now))
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
        refreshTokenExpiresAt: Date? = nil,
        kind: AuthenticationKind = .oauth
    ) -> GitHubAccount {
        GitHubAccount(
            id: AccountID(rawValue: "account-1")!,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_kgDOExample")!,
            login: "octocat",
            authenticationKind: kind,
            credentialID: CredentialID(rawValue: "credential-1")!,
            credentialStatus: .active,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            createdAt: now,
            lastValidatedAt: now
        )
    }
}
