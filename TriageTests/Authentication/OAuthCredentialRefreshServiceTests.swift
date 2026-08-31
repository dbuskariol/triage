import XCTest
@testable import Triage

final class OAuthCredentialRefreshServiceTests: XCTestCase {
    func testPersonalAccessTokensNeverEnterTheOAuthRefreshPath() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = GitHubAccount(
            id: AccountID(rawValue: "00000000-0000-4000-8000-000000000209")!,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_kgDOExample")!,
            login: "octocat",
            authenticationKind: .fineGrainedPersonalAccessToken,
            credentialID: CredentialID(rawValue: "credential-1")!,
            credentialStatus: .active,
            accessTokenExpiresAt: now.addingTimeInterval(-1),
            refreshTokenExpiresAt: now.addingTimeInterval(-1),
            createdAt: now
        )
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: RejectingSecretStore(),
            vaultRegistry: try VaultRegistry(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            clock: { now },
            broker: RejectingBroker()
        )

        let refreshedAccount = try await service.refreshIfNeeded(account)
        XCTAssertEqual(refreshedAccount, account)
    }

    func testRefreshServiceValidatesBrokerURLEvenWithAnInjectedBroker() throws {
        XCTAssertThrowsError(
            try OAuthCredentialRefreshService(
                brokerURL: URL(string: "http://oauth.triage.example")!,
                secretStore: RejectingSecretStore(),
                vaultRegistry: try VaultRegistry(
                    rootDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                ),
                broker: RejectingBroker()
            )
        ) { error in
            XCTAssertEqual(error as? AuthBrokerClientError, .invalidBaseURL)
        }
    }

    func testRefreshPersistsRotatedTokensAndCredentialState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-original")!
        )
        let secrets = InMemorySecretStore(values: [
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
        let broker = StubBroker(
            result: .success(
                AuthBrokerTokenResponse(
                    accessToken: OAuthAccessToken("access-rotated"),
                    refreshToken: OAuthRefreshToken("refresh-rotated"),
                    tokenType: "bearer",
                    scope: "read:org",
                    expiresIn: 3_600,
                    refreshTokenExpiresIn: 7_200
                )
            )
        )
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: broker
        )

        let refreshed = try await service.refreshIfNeeded(account)

        XCTAssertEqual(refreshed.credentialStatus, .active)
        XCTAssertEqual(refreshed.accessTokenExpiresAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(refreshed.refreshTokenExpiresAt, now.addingTimeInterval(7_200))
        XCTAssertEqual(refreshed.lastValidatedAt, now)
        let accessToken = await secrets.value(
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        XCTAssertEqual(accessToken, Data("access-rotated".utf8))
        let refreshToken = await secrets.value(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        XCTAssertEqual(refreshToken, Data("refresh-rotated".utf8))
        let storedAccounts = try await repository.accounts()
        XCTAssertEqual(storedAccounts, [refreshed])
        let brokerRequests = await broker.requests()
        XCTAssertEqual(brokerRequests, [AuthBrokerRefreshRequest(refreshToken: OAuthRefreshToken("refresh-original"))])
    }

    func testBrokerFailureLeavesCredentialSecretsAndVaultRecordUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-original")!
        )
        let secrets = InMemorySecretStore(values: [
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
        let failure = AuthBrokerClientError.broker(
            AuthBrokerFailure(code: .invalidGrant, recoveryDescription: "Token revoked")
        )
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: StubBroker(result: .failure(failure))
        )

        do {
            _ = try await service.refreshIfNeeded(account)
            XCTFail("Expected broker failure.")
        } catch let error as AuthBrokerClientError {
            XCTAssertEqual(error, failure)
        }

        let writeCount = await secrets.writeCount()
        XCTAssertEqual(writeCount, 0)
        let storedAccounts = try await repository.accounts()
        XCTAssertEqual(storedAccounts, [account])
    }

    func testCancellationFromBrokerLeavesCredentialSecretsAndVaultRecordUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-original")!
        )
        let secrets = InMemorySecretStore(values: [
            .init(kind: .vaultKey, accountID: account.id, credentialID: nil): vaultKey.data,
            .init(
                kind: .oauthRefreshToken,
                accountID: account.id,
                credentialID: account.credentialID
            ): Data("refresh-original".utf8)
        ])
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: CancellingBroker()
        )

        do {
            _ = try await service.refreshIfNeeded(account)
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Cancellation must not mutate the active credential set.
        }

        let writeCount = await secrets.writeCount()
        XCTAssertEqual(writeCount, 0)
        let storedAccounts = try await repository.accounts()
        XCTAssertEqual(storedAccounts, [account])
    }

    func testMalformedRefreshTokenFailsBeforeBrokerRequest() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let broker = StubBroker(
            result: .success(
                AuthBrokerTokenResponse(
                    accessToken: OAuthAccessToken("unused"),
                    refreshToken: nil,
                    tokenType: "bearer",
                    scope: nil,
                    expiresIn: nil,
                    refreshTokenExpiresIn: nil
                )
            )
        )
        let secrets = InMemorySecretStore(values: [
            .init(
                kind: .oauthRefreshToken,
                accountID: account.id,
                credentialID: account.credentialID
            ): Data([0xFF])
        ])
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: try VaultRegistry(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            clock: { now },
            broker: broker
        )

        do {
            _ = try await service.refreshIfNeeded(account)
            XCTFail("Expected malformed refresh-token error.")
        } catch let error as OAuthCredentialRefreshError {
            XCTAssertEqual(error, .refreshTokenEncodingInvalid)
        }

        let brokerRequests = await broker.requests()
        XCTAssertEqual(brokerRequests, [])
        let writeCount = await secrets.writeCount()
        XCTAssertEqual(writeCount, 0)
    }

    func testMissingVaultKeyFailsBeforeBrokerRequest() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let broker = StubBroker(
            result: .success(
                AuthBrokerTokenResponse(
                    accessToken: OAuthAccessToken("unused"),
                    refreshToken: nil,
                    tokenType: "bearer",
                    scope: nil,
                    expiresIn: nil,
                    refreshTokenExpiresIn: nil
                )
            )
        )
        let secrets = InMemorySecretStore(values: [
            .init(
                kind: .oauthRefreshToken,
                accountID: account.id,
                credentialID: account.credentialID
            ): Data("refresh-original".utf8)
        ])
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: try VaultRegistry(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            clock: { now },
            broker: broker
        )

        do {
            _ = try await service.refreshIfNeeded(account)
            XCTFail("Expected missing vault-key error.")
        } catch let error as OAuthCredentialRefreshError {
            XCTAssertEqual(error, .vaultKeyUnavailable)
        }

        let brokerRequests = await broker.requests()
        XCTAssertEqual(brokerRequests, [])
        let writeCount = await secrets.writeCount()
        XCTAssertEqual(writeCount, 0)
    }

    func testAlreadyCancelledRefreshSkipsSecretAndBrokerAccess() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let broker = StubBroker(
            result: .success(
                AuthBrokerTokenResponse(
                    accessToken: OAuthAccessToken("unused"),
                    refreshToken: nil,
                    tokenType: "bearer",
                    scope: nil,
                    expiresIn: nil,
                    refreshTokenExpiresIn: nil
                )
            )
        )
        let secrets = InMemorySecretStore(values: [:])
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: try VaultRegistry(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            clock: { now },
            broker: broker
        )

        let wasCancelled = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await service.refreshIfNeeded(account)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        XCTAssertTrue(wasCancelled)
        let brokerRequests = await broker.requests()
        XCTAssertEqual(brokerRequests, [])
        let writeCount = await secrets.writeCount()
        XCTAssertEqual(writeCount, 0)
    }

    func testCancellationAfterBrokerResponseLeavesPersistedCredentialStateUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-original")!
        )
        let secrets = InMemorySecretStore(values: [
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
        let broker = ControllableBroker()
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: broker
        )
        let refreshTask = Task {
            try await service.refreshIfNeeded(account)
        }

        await broker.waitForRequest()
        refreshTask.cancel()
        await broker.succeed(
            AuthBrokerTokenResponse(
                accessToken: OAuthAccessToken("access-rotated"),
                refreshToken: OAuthRefreshToken("refresh-rotated"),
                tokenType: "bearer",
                scope: nil,
                expiresIn: 3_600,
                refreshTokenExpiresIn: 7_200
            )
        )

        do {
            _ = try await refreshTask.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Cancellation after the broker returns must not rotate local credentials.
        }

        let accessToken = await secrets.value(
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        XCTAssertEqual(accessToken, Data("access-original".utf8))
        let refreshToken = await secrets.value(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        XCTAssertEqual(refreshToken, Data("refresh-original".utf8))
        let storedAccounts = try await repository.accounts()
        XCTAssertEqual(storedAccounts, [account])
    }

    func testCredentialReplacementDuringRefreshCannotPublishOrRewriteRetiredCredential() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let originalRevision = CredentialRevision(rawValue: "credential-revision-original")!
        let replacementRevision = CredentialRevision(rawValue: "credential-revision-replacement")!
        let replacementCredentialID = CredentialID(rawValue: "credential-2")!
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(account, credentialRevision: originalRevision)
        let secrets = InMemorySecretStore(values: [
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
        let broker = ControllableBroker()
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: broker
        )
        let refreshTask = Task { try await service.refreshIfNeeded(account) }

        await broker.waitForRequest()
        let replacement = account.replacingCredential(
            credentialID: replacementCredentialID,
            login: account.login,
            displayName: account.displayName,
            avatarURL: account.avatarURL,
            accessTokenExpiresAt: now.addingTimeInterval(3_600),
            refreshTokenExpiresAt: now.addingTimeInterval(7_200),
            status: .active,
            validatedAt: now
        )
        try await repository.save(replacement, credentialRevision: replacementRevision)
        await broker.succeed(
            AuthBrokerTokenResponse(
                accessToken: OAuthAccessToken("access-retired-credential"),
                refreshToken: OAuthRefreshToken("refresh-retired-credential"),
                tokenType: "bearer",
                scope: nil,
                expiresIn: 3_600,
                refreshTokenExpiresIn: 7_200
            )
        )

        do {
            _ = try await refreshTask.value
            XCTFail("Expected stale account authority.")
        } catch let error as OAuthCredentialRefreshError {
            XCTAssertEqual(error, .staleAccountAuthority)
        }

        let persistedAccounts = try await repository.accounts()
        XCTAssertEqual(persistedAccounts, [replacement])
        let accessToken = await secrets.value(
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        let refreshToken = await secrets.value(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        let writeCount = await secrets.writeCount()
        XCTAssertEqual(accessToken, Data("access-original".utf8))
        XCTAssertEqual(refreshToken, Data("refresh-original".utf8))
        XCTAssertEqual(writeCount, 0)
    }

    func testConcurrentRefreshLoserCannotDeleteWinnerTokens() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-original")!
        )
        let secrets = InMemorySecretStore(
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
            blockFirstOAuthRefreshTokenWrite: true
        )
        let first = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: StubBroker(result: .success(Self.tokenResponse(access: "access-winner", refresh: "refresh-winner")))
        )
        let second = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: StubBroker(result: .success(Self.tokenResponse(access: "access-loser", refresh: "refresh-loser")))
        )

        let firstTask = Task { try await first.refreshIfNeeded(account) }
        await secrets.waitForFirstOAuthRefreshTokenWrite()

        let staleRefreshFinishedBeforeWinner = expectation(description: "stale refresh must wait for active credential mutation")
        staleRefreshFinishedBeforeWinner.isInverted = true
        let secondTask = Task {
            defer { staleRefreshFinishedBeforeWinner.fulfill() }
            return try await second.refreshIfNeeded(account)
        }
        await fulfillment(of: [staleRefreshFinishedBeforeWinner], timeout: 0.05)

        await secrets.releaseFirstOAuthRefreshTokenWrite()
        let refreshed = try await firstTask.value
        do {
            _ = try await secondTask.value
            XCTFail("Expected the queued refresh to observe stale credential authority.")
        } catch let error as OAuthCredentialRefreshError {
            XCTAssertEqual(error, .staleAccountAuthority)
        }

        let persistedAccounts = try await repository.accounts()
        let accessToken = await secrets.value(
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        let refreshToken = await secrets.value(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        XCTAssertEqual(persistedAccounts, [refreshed])
        XCTAssertEqual(accessToken, Data("access-winner".utf8))
        XCTAssertEqual(refreshToken, Data("refresh-winner".utf8))
    }

    func testCancelledQueuedRefreshCannotWriteCredentialsAfterLockHandoff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-original")!
        )
        let secrets = InMemorySecretStore(
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
            blockFirstOAuthRefreshTokenWrite: true
        )
        let first = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: StubBroker(result: .success(Self.tokenResponse(access: "access-winner", refresh: "refresh-winner")))
        )
        let second = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: StubBroker(result: .success(Self.tokenResponse(access: "access-cancelled", refresh: "refresh-cancelled")))
        )

        let firstTask = Task { try await first.refreshIfNeeded(account) }
        await secrets.waitForFirstOAuthRefreshTokenWrite()
        let secondTask = Task { try await second.refreshIfNeeded(account) }
        await Task.yield()
        secondTask.cancel()

        await secrets.releaseFirstOAuthRefreshTokenWrite()
        let refreshed = try await firstTask.value
        do {
            _ = try await secondTask.value
            XCTFail("Expected cancellation while waiting for the credential mutation lock.")
        } catch is CancellationError {
            // Expected: no post-handoff credential mutation is permitted.
        }

        let persistedAccounts = try await repository.accounts()
        let writeCount = await secrets.writeCount()
        let accessToken = await secrets.value(
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        let refreshToken = await secrets.value(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        XCTAssertEqual(persistedAccounts, [refreshed])
        XCTAssertEqual(writeCount, 2)
        XCTAssertEqual(accessToken, Data("access-winner".utf8))
        XCTAssertEqual(refreshToken, Data("refresh-winner".utf8))
    }

    func testAccessTokenWriteFailurePreservesRotatedRefreshToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-original")!
        )
        let secrets = InMemorySecretStore(
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
            failingWritesForKinds: [.oauthAccessToken]
        )
        let service = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: StubBroker(
                result: .success(
                    AuthBrokerTokenResponse(
                        accessToken: OAuthAccessToken("access-rotated"),
                        refreshToken: OAuthRefreshToken("refresh-rotated"),
                        tokenType: "bearer",
                        scope: nil,
                        expiresIn: 3_600,
                        refreshTokenExpiresIn: 7_200
                    )
                )
            )
        )

        do {
            _ = try await service.refreshIfNeeded(account)
            XCTFail("Expected access-token write failure.")
        } catch is URLError {
            // The rotated refresh token remains recoverable after the local write failure.
        }

        let accessToken = await secrets.value(
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        XCTAssertEqual(accessToken, Data("access-original".utf8))
        let refreshToken = await secrets.value(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        XCTAssertEqual(refreshToken, Data("refresh-rotated".utf8))
    }

    func testInterruptedRefreshRecoversUsingThePersistedRotatedRefreshToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: account.id, vaultKey: vaultKey)
        let repository = AccountRepository(vault: vault)
        try await repository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-original")!
        )
        let secrets = InMemorySecretStore(
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
            failingWritesForKinds: [.oauthAccessToken]
        )
        let interrupted = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: StubBroker(
                result: .success(
                    AuthBrokerTokenResponse(
                        accessToken: OAuthAccessToken("access-first"),
                        refreshToken: OAuthRefreshToken("refresh-rotated"),
                        tokenType: "bearer",
                        scope: nil,
                        expiresIn: 3_600,
                        refreshTokenExpiresIn: 7_200
                    )
                )
            )
        )

        do {
            _ = try await interrupted.refreshIfNeeded(account)
            XCTFail("Expected the interrupted refresh to fail.")
        } catch is URLError {
            // The rotated refresh token was committed before the local access
            // token write failed, so recovery must use that replacement.
        }

        await secrets.setFailingWritesForKinds([])
        let recoveryBroker = StubBroker(
            result: .success(
                AuthBrokerTokenResponse(
                    accessToken: OAuthAccessToken("access-recovered"),
                    refreshToken: OAuthRefreshToken("refresh-recovered"),
                    tokenType: "bearer",
                    scope: nil,
                    expiresIn: 3_600,
                    refreshTokenExpiresIn: 7_200
                )
            )
        )
        let recovery = try OAuthCredentialRefreshService(
            brokerURL: URL(string: "https://oauth.triage.example")!,
            secretStore: secrets,
            vaultRegistry: registry,
            clock: { now },
            broker: recoveryBroker
        )

        let refreshed = try await recovery.refreshIfNeeded(account)

        let brokerRequests = await recoveryBroker.requests()
        let accessToken = await secrets.value(
            kind: .oauthAccessToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        let refreshToken = await secrets.value(
            kind: .oauthRefreshToken,
            accountID: account.id,
            credentialID: account.credentialID
        )
        let storedAccounts = try await repository.accounts()
        XCTAssertEqual(
            brokerRequests,
            [AuthBrokerRefreshRequest(refreshToken: OAuthRefreshToken("refresh-rotated"))]
        )
        XCTAssertEqual(accessToken, Data("access-recovered".utf8))
        XCTAssertEqual(refreshToken, Data("refresh-recovered".utf8))
        XCTAssertEqual(storedAccounts, [refreshed])
    }

    private func makeExpiringOAuthAccount(now: Date) -> GitHubAccount {
        GitHubAccount(
            id: AccountID(rawValue: "00000000-0000-4000-8000-000000000210")!,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_kgDOExample")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID(rawValue: "credential-1")!,
            credentialStatus: .expiring,
            accessTokenExpiresAt: now.addingTimeInterval(60),
            refreshTokenExpiresAt: now.addingTimeInterval(3_600),
            createdAt: now
        )
    }

    private static func tokenResponse(access: String, refresh: String) -> AuthBrokerTokenResponse {
        AuthBrokerTokenResponse(
            accessToken: OAuthAccessToken(access),
            refreshToken: OAuthRefreshToken(refresh),
            tokenType: "bearer",
            scope: nil,
            expiresIn: 3_600,
            refreshTokenExpiresIn: 7_200
        )
    }
}

private actor RejectingSecretStore: SecretStore {
    func read(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws -> Data? {
        XCTFail("PAT refresh must not access secrets.")
        throw URLError(.badServerResponse)
    }

    func write(
        _ value: Data,
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        XCTFail("PAT refresh must not write secrets.")
        throw URLError(.badServerResponse)
    }

    func remove(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        XCTFail("PAT refresh must not remove secrets.")
        throw URLError(.badServerResponse)
    }

    func accountIDs() async throws -> [AccountID] {
        XCTFail("PAT refresh must not enumerate accounts.")
        throw URLError(.badServerResponse)
    }
}

private actor RejectingBroker: OAuthTokenRefreshing {
    func refresh(
        _ request: AuthBrokerRefreshRequest
    ) async throws -> AuthBrokerTokenResponse {
        XCTFail("PAT refresh must not contact the OAuth broker.")
        throw URLError(.badServerResponse)
    }
}

private actor StubBroker: OAuthTokenRefreshing {
    private let result: Result<AuthBrokerTokenResponse, AuthBrokerClientError>
    private var receivedRequests: [AuthBrokerRefreshRequest] = []

    init(result: Result<AuthBrokerTokenResponse, AuthBrokerClientError>) {
        self.result = result
    }

    func refresh(_ request: AuthBrokerRefreshRequest) async throws -> AuthBrokerTokenResponse {
        receivedRequests.append(request)
        return try result.get()
    }

    func requests() -> [AuthBrokerRefreshRequest] {
        receivedRequests
    }
}

private actor CancellingBroker: OAuthTokenRefreshing {
    func refresh(_ request: AuthBrokerRefreshRequest) async throws -> AuthBrokerTokenResponse {
        throw CancellationError()
    }
}

private actor ControllableBroker: OAuthTokenRefreshing {
    private var hasReceivedRequest = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<AuthBrokerTokenResponse, Never>?
    private var pendingResponse: AuthBrokerTokenResponse?

    func refresh(_ request: AuthBrokerRefreshRequest) async throws -> AuthBrokerTokenResponse {
        hasReceivedRequest = true
        let waiters = requestWaiters
        requestWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        if let pendingResponse {
            self.pendingResponse = nil
            return pendingResponse
        }
        return await withCheckedContinuation { continuation in
            responseContinuation = continuation
        }
    }

    func waitForRequest() async {
        guard !hasReceivedRequest else {
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func succeed(_ response: AuthBrokerTokenResponse) {
        if let responseContinuation {
            self.responseContinuation = nil
            responseContinuation.resume(returning: response)
        } else {
            pendingResponse = response
        }
    }
}

private actor InMemorySecretStore: SecretStore {
    struct Key: Hashable, Sendable {
        let kind: TriageSecretKind
        let accountID: AccountID
        let credentialID: CredentialID?
    }

    private var values: [Key: Data]
    private var failingWritesForKinds: Set<TriageSecretKind>
    private let blockFirstOAuthRefreshTokenWrite: Bool
    private var firstOAuthRefreshTokenWriteStarted = false
    private var firstOAuthRefreshTokenWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstOAuthRefreshTokenWriteRelease: CheckedContinuation<Void, Never>?
    private var writes = 0

    init(
        values: [Key: Data],
        failingWritesForKinds: Set<TriageSecretKind> = [],
        blockFirstOAuthRefreshTokenWrite: Bool = false
    ) {
        self.values = values
        self.failingWritesForKinds = failingWritesForKinds
        self.blockFirstOAuthRefreshTokenWrite = blockFirstOAuthRefreshTokenWrite
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
        guard !failingWritesForKinds.contains(kind) else {
            throw URLError(.cannotWriteToFile)
        }
        if blockFirstOAuthRefreshTokenWrite,
           kind == .oauthRefreshToken,
           !firstOAuthRefreshTokenWriteStarted {
            firstOAuthRefreshTokenWriteStarted = true
            let waiters = firstOAuthRefreshTokenWriteWaiters
            firstOAuthRefreshTokenWriteWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                firstOAuthRefreshTokenWriteRelease = continuation
            }
        }
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)] = value
        writes += 1
    }

    func remove(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)] = nil
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

    func setFailingWritesForKinds(_ kinds: Set<TriageSecretKind>) {
        failingWritesForKinds = kinds
    }

    func waitForFirstOAuthRefreshTokenWrite() async {
        guard !firstOAuthRefreshTokenWriteStarted else { return }
        await withCheckedContinuation { continuation in
            firstOAuthRefreshTokenWriteWaiters.append(continuation)
        }
    }

    func releaseFirstOAuthRefreshTokenWrite() {
        firstOAuthRefreshTokenWriteRelease?.resume()
        firstOAuthRefreshTokenWriteRelease = nil
    }
}
