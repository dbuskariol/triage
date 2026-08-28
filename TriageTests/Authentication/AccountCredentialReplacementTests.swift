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

    func testServicePersistsReplacementAndRetiresPreviousOAuthCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = date
        let account = makeAccount()
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-original")!
        )
        let secrets = ReplacementSecretStore(values: [
            .init(kind: .vaultKey, accountID: account.id, credentialID: nil): vaultKey.data,
            .init(
                kind: .oauthAccessToken,
                accountID: account.id,
                credentialID: account.credentialID
            ): Data("access-original".utf8),
            .init(
                kind: .oauthRefreshToken,
                accountID: account.id,
                credentialID: account.credentialID
            ): Data("refresh-original".utf8)
        ])
        let user = GitHubUserDTO(
            id: account.githubUserID,
            nodeID: account.nodeID.rawValue,
            login: "renamed-octocat",
            name: "The Octocat",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1")
        )
        let service = AccountCredentialReplacementService(
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            loadAuthenticatedUser: { _ in user }
        )

        let result = try await service.replace(
            oauthTokenResponse: AuthBrokerTokenResponse(
                accessToken: OAuthAccessToken("access-replacement"),
                refreshToken: OAuthRefreshToken("refresh-replacement"),
                tokenType: "bearer",
                scope: "read:org",
                expiresIn: 3_600,
                refreshTokenExpiresIn: 7_200
            ),
            for: account
        )

        XCTAssertNotEqual(result.account.credentialID, account.credentialID)
        XCTAssertEqual(result.account.login, "renamed-octocat")
        XCTAssertEqual(result.account.credentialStatus, .active)
        XCTAssertFalse(result.retiredCredentialCleanupFailed)
        XCTAssertEqual(try await repository.accounts(), [result.account])
        XCTAssertEqual(
            await secrets.value(
                kind: .oauthAccessToken,
                accountID: account.id,
                credentialID: result.account.credentialID
            ),
            Data("access-replacement".utf8)
        )
        XCTAssertEqual(
            await secrets.value(
                kind: .oauthRefreshToken,
                accountID: account.id,
                credentialID: result.account.credentialID
            ),
            Data("refresh-replacement".utf8)
        )
        XCTAssertNil(
            await secrets.value(
                kind: .oauthAccessToken,
                accountID: account.id,
                credentialID: account.credentialID
            )
        )
        XCTAssertNil(
            await secrets.value(
                kind: .oauthRefreshToken,
                accountID: account.id,
                credentialID: account.credentialID
            )
        )
    }

    func testServiceRejectsMismatchedIdentityBeforeMutatingCredentialsOrVault() async throws {
        let now = date
        let account = makeAccount()
        let secrets = ReplacementSecretStore(values: [:])
        let service = AccountCredentialReplacementService(
            secretStore: secrets,
            vaultRegistry: try VaultRegistry(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            clock: { now },
            loadAuthenticatedUser: { _ in
                GitHubUserDTO(
                    id: account.githubUserID + 1,
                    nodeID: account.nodeID.rawValue,
                    login: "different-user",
                    name: nil,
                    avatarURL: nil
                )
            }
        )

        do {
            _ = try await service.replace(
                oauthTokenResponse: AuthBrokerTokenResponse(
                    accessToken: OAuthAccessToken("unused"),
                    refreshToken: OAuthRefreshToken("unused"),
                    tokenType: "bearer",
                    scope: nil,
                    expiresIn: nil,
                    refreshTokenExpiresIn: nil
                ),
                for: account
            )
            XCTFail("Expected immutable identity mismatch.")
        } catch let error as AccountCredentialReplacementError {
            XCTAssertEqual(error, .immutableIdentityMismatch)
        }

        XCTAssertEqual(await secrets.writeCount(), 0)
        XCTAssertEqual(await secrets.removeCount(), 0)
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

private actor ReplacementSecretStore: SecretStore {
    struct Key: Hashable, Sendable {
        let kind: TriageSecretKind
        let accountID: AccountID
        let credentialID: CredentialID?
    }

    private var values: [Key: Data]
    private var writes = 0
    private var removals = 0

    init(values: [Key: Data]) {
        self.values = values
    }

    func read(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws -> Data? {
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)]
    }

    func write(
        _ value: Data,
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)] = value
        writes += 1
    }

    func remove(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)] = nil
        removals += 1
    }

    func accountIDs() async throws -> [AccountID] {
        []
    }

    func value(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) -> Data? {
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)]
    }

    func writeCount() -> Int {
        writes
    }

    func removeCount() -> Int {
        removals
    }
}
