import XCTest
@testable import Triage

final class AccountCredentialReplacementTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 1_000)

    func testReplacementPreservesProfileAndVaultIdentityForMatchingUser() throws {
        let account = makeAccount()
        let user = GitHubUserDTO(
            id: account.githubUserID,
            nodeID: account.nodeID.rawValue,
            login: "renamed-octocat",
            name: "The Octocat",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1")
        )

        let updated = try CredentialReplacement.updatedAccount(
            account,
            authenticatedUser: user,
            credentialID: CredentialID(rawValue: "credential-2")!,
            accessTokenExpiresAt: date.addingTimeInterval(3_600),
            refreshTokenExpiresAt: date.addingTimeInterval(7_200),
            at: date
        )

        XCTAssertEqual(updated.id, account.id)
        XCTAssertEqual(updated.credentialID, CredentialID(rawValue: "credential-2")!)
        XCTAssertEqual(updated.githubUserID, account.githubUserID)
        XCTAssertEqual(updated.nodeID, account.nodeID)
        XCTAssertEqual(updated.login, "renamed-octocat")
        XCTAssertEqual(updated.credentialStatus, .active)
        XCTAssertEqual(updated.lastValidatedAt, date)
    }

    func testReplacementRejectsCredentialForDifferentImmutableUser() {
        XCTAssertThrowsError(
            try CredentialReplacement.updatedAccount(
                makeAccount(),
                authenticatedUser: GitHubUserDTO(
                    id: 2,
                    nodeID: "U_kgDOBogus",
                    login: "someone-else",
                    name: nil,
                    avatarURL: nil
                ),
                credentialID: CredentialID(rawValue: "credential-2")!,
                accessTokenExpiresAt: nil,
                refreshTokenExpiresAt: nil,
                at: date
            )
        ) { error in
            XCTAssertEqual(error as? AccountCredentialReplacementError, .immutableIdentityMismatch)
        }
    }

    func testReplacementRejectsMalformedNodeIdentity() {
        XCTAssertThrowsError(
            try CredentialReplacement.updatedAccount(
                makeAccount(),
                authenticatedUser: GitHubUserDTO(
                    id: 1,
                    nodeID: "",
                    login: "octocat",
                    name: nil,
                    avatarURL: nil
                ),
                credentialID: CredentialID(rawValue: "credential-2")!,
                accessTokenExpiresAt: nil,
                refreshTokenExpiresAt: nil,
                at: date
            )
        ) { error in
            XCTAssertEqual(error as? AccountCredentialReplacementError, .invalidGitHubIdentity)
        }
    }

    private func makeAccount() -> GitHubAccount {
        GitHubAccount(
            id: AccountID(rawValue: "account-1")!,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_kgDOExample")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID(rawValue: "credential-1")!,
            credentialStatus: .expired,
            createdAt: date
        )
    }
}
