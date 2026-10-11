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
            authenticationKind: .oauth,
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
                authenticationKind: .oauth,
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
                authenticationKind: .oauth,
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
            loadAuthenticatedUser: { _ in AuthenticatedGitHubCredential(user: user, expiresAt: nil) }
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
        let storedAccounts = try await repository.accounts()
        XCTAssertEqual(storedAccounts, [result.account])
        let replacementAccessToken = await secrets.value(
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: result.account.credentialID
        )
        XCTAssertEqual(replacementAccessToken, Data("access-replacement".utf8))
        let replacementRefreshToken = await secrets.value(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: result.account.credentialID
        )
        XCTAssertEqual(replacementRefreshToken, Data("refresh-replacement".utf8))
        let retiredAccessToken = await secrets.value(
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        XCTAssertNil(retiredAccessToken)
        let retiredRefreshToken = await secrets.value(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        XCTAssertNil(retiredRefreshToken)
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
                AuthenticatedGitHubCredential(user: GitHubUserDTO(
                    id: account.githubUserID + 1,
                    nodeID: account.nodeID.rawValue,
                    login: "different-user",
                    name: nil,
                    avatarURL: nil
                ), expiresAt: nil)
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

        let writeCount = await secrets.writeCount()
        XCTAssertEqual(writeCount, 0)
        let removeCount = await secrets.removeCount()
        XCTAssertEqual(removeCount, 0)
    }

    func testPersonalAccessTokenReplacementSwitchesKindAndRecordsExpiration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date
        let account = GitHubAccount(
            id: AccountID(rawValue: "00000000-0000-4000-8000-000000000207")!,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_kgDOExample")!,
            login: "octocat",
            authenticationKind: .classicPersonalAccessToken,
            credentialID: CredentialID(rawValue: "classic-credential")!,
            credentialStatus: .revoked,
            createdAt: date
        )
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let repository = AccountRepository(vault: try await registry.open(accountID: account.id, vaultKey: vaultKey))
        try await repository.save(account, credentialRevision: CredentialRevision(rawValue: "revision-original")!)
        let secrets = ReplacementSecretStore(values: [
            .init(kind: .vaultKey, accountID: account.id, credentialID: nil): vaultKey.data,
            .init(kind: .personalAccessToken, accountID: account.id, credentialID: account.credentialID):
                Data("ghp_original".utf8),
        ])
        let expiresAt = now.addingTimeInterval(30 * 24 * 3_600)
        let service = AccountCredentialReplacementService(
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            loadAuthenticatedUser: { _ in
                AuthenticatedGitHubCredential(user: GitHubUserDTO(
                    id: account.githubUserID,
                    nodeID: account.nodeID.rawValue,
                    login: account.login,
                    name: nil,
                    avatarURL: nil
                ), expiresAt: expiresAt)
            }
        )

        let result = try await service.replace(
            personalAccessToken: try PersonalAccessToken(rawValue: "github_pat_abcdefghijklmnopqrstuvwxyz"),
            for: account
        )

        XCTAssertEqual(result.account.authenticationKind, .fineGrainedPersonalAccessToken)
        XCTAssertEqual(result.account.accessTokenExpiresAt, expiresAt)
        XCTAssertEqual(result.account.credentialStatus, .active)
        let storedAccounts = try await repository.accounts()
        XCTAssertEqual(storedAccounts, [result.account])
        let replacement = await secrets.value(
            kind: .personalAccessToken, accountID: account.id, credentialID: result.account.credentialID
        )
        XCTAssertEqual(replacement, Data("github_pat_abcdefghijklmnopqrstuvwxyz".utf8))
        let retired = await secrets.value(
            kind: .personalAccessToken, accountID: account.id, credentialID: account.credentialID
        )
        XCTAssertNil(retired)
    }

    func testCancellationAfterStagingAccessCredentialRemovesEveryReplacementSecret() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = makeAccount()
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-original")!
        )
        let secrets = ReplacementSecretStore(
            values: [
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
            ],
            blockFirstWrite: true
        )
        let service = AccountCredentialReplacementService(
            secretStore: secrets,
            vaultRegistry: registry,
            loadAuthenticatedUser: { _ in
                AuthenticatedGitHubCredential(user: GitHubUserDTO(
                    id: account.githubUserID,
                    nodeID: account.nodeID.rawValue,
                    login: account.login,
                    name: account.displayName,
                    avatarURL: account.avatarURL
                ), expiresAt: nil)
            }
        )

        let replacementTask = Task {
            try await service.replace(
                oauthTokenResponse: AuthBrokerTokenResponse(
                    accessToken: OAuthAccessToken("access-replacement"),
                    refreshToken: OAuthRefreshToken("refresh-replacement"),
                    tokenType: "bearer",
                    scope: nil,
                    expiresIn: 3_600,
                    refreshTokenExpiresIn: 7_200
                ),
                for: account
            )
        }
        await secrets.waitForFirstWrite()
        replacementTask.cancel()
        await secrets.releaseFirstWrite()

        do {
            _ = try await replacementTask.value
            XCTFail("Expected cancellation after the staged access credential write.")
        } catch is CancellationError {
            // Expected: cancellation runs staged-credential cleanup before return.
        }

        let storedAccounts = try await repository.accounts()
        let hasStagedAccessToken = await secrets.hasCredential(
            kind: .oauthAccessToken,
            accountID: account.id,
            otherThan: account.credentialID
        )
        let hasStagedRefreshToken = await secrets.hasCredential(
            kind: .oauthRefreshToken,
            accountID: account.id,
            otherThan: account.credentialID
        )
        XCTAssertEqual(storedAccounts, [account])
        XCTAssertFalse(hasStagedAccessToken)
        XCTAssertFalse(hasStagedRefreshToken)
    }

    private func makeAccount() -> GitHubAccount {
        GitHubAccount(
            id: AccountID(rawValue: "00000000-0000-4000-8000-000000000208")!,
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
    private let blockFirstWrite: Bool
    private var firstWriteStarted = false
    private var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWriteRelease: CheckedContinuation<Void, Never>?

    init(values: [Key: Data], blockFirstWrite: Bool = false) {
        self.values = values
        self.blockFirstWrite = blockFirstWrite
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
        if blockFirstWrite, !firstWriteStarted {
            firstWriteStarted = true
            let waiters = firstWriteWaiters
            firstWriteWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                firstWriteRelease = continuation
            }
        }
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

    func hasCredential(
        kind: TriageSecretKind,
        accountID: AccountID,
        otherThan credentialID: CredentialID
    ) -> Bool {
        values.keys.contains {
            $0.kind == kind && $0.accountID == accountID && $0.credentialID != credentialID
        }
    }

    func waitForFirstWrite() async {
        guard !firstWriteStarted else { return }
        await withCheckedContinuation { continuation in
            firstWriteWaiters.append(continuation)
        }
    }

    func releaseFirstWrite() {
        firstWriteRelease?.resume()
        firstWriteRelease = nil
    }
}
