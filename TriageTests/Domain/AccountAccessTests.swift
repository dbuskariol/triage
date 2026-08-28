import XCTest
@testable import Triage

final class AccountAccessTests: XCTestCase {
    func testNotificationsAreTheOnlyAccountScopedCapability() {
        XCTAssertEqual(GitHubCapability.notifications.scope, .account)
        XCTAssertTrue(
            GitHubCapability.allCases
                .filter { $0 != .notifications }
                .allSatisfy { $0.scope == .organization }
        )
    }

    private let date = Date(timeIntervalSinceReferenceDate: 100)

    func testClassicPersonalAccessTokensCannotAuthenticateCopilotDirectly() {
        XCTAssertTrue(AuthenticationKind.oauth.supportsDirectCopilotAuthentication)
        XCTAssertTrue(AuthenticationKind.fineGrainedPersonalAccessToken.supportsDirectCopilotAuthentication)
        XCTAssertFalse(AuthenticationKind.classicPersonalAccessToken.supportsDirectCopilotAuthentication)
    }

    func testAccessReturnsUnknownForAnUnprobedCapability() {
        let access = OrganizationAccess(
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: "github")!,
            state: .available,
            capabilityRevision: CapabilityRevision(rawValue: "revision-1")!,
            capabilities: [
                CapabilityAvailability(
                    capability: .privateRepositories,
                    status: .available,
                    checkedAt: date
                )
            ],
            checkedAt: date
        )

        XCTAssertEqual(access.status(for: .privateRepositories), .available)
        XCTAssertEqual(access.status(for: .discussions), .unknown)
    }

    func testReplacingCredentialExpirationPreservesAccountIdentity() {
        let account = GitHubAccount(
            id: AccountID(rawValue: "account-1")!,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_kgDOExample")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID(rawValue: "credential-1")!,
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
        let validatedAt = date.addingTimeInterval(60)

        let updated = account.replacingCredentialExpiration(
            accessTokenExpiresAt: validatedAt.addingTimeInterval(3_600),
            refreshTokenExpiresAt: validatedAt.addingTimeInterval(7_200),
            status: .expiring,
            validatedAt: validatedAt
        )

        XCTAssertEqual(updated.id, account.id)
        XCTAssertEqual(updated.credentialID, account.credentialID)
        XCTAssertEqual(updated.githubUserID, account.githubUserID)
        XCTAssertEqual(updated.createdAt, account.createdAt)
        XCTAssertEqual(updated.credentialStatus, .expiring)
        XCTAssertEqual(updated.lastValidatedAt, validatedAt)
    }

    func testUnknownAccountAccessEnumValuesAreRejected() {
        assertUnknownCaseRejected(AuthenticationKind.self)
        assertUnknownCaseRejected(CredentialStatus.self)
        assertUnknownCaseRejected(OrganizationAccessState.self)
        assertUnknownCaseRejected(CapabilityStatus.self)
        assertUnknownCaseRejected(GitHubCapability.self)
    }

    private func assertUnknownCaseRejected<T: Decodable>(
        _ type: T.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(T.self, from: Data("\"future-case\"".utf8)),
            file: file,
            line: line
        )
    }
}
