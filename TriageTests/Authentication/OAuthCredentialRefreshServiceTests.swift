import XCTest
@testable import Triage

final class OAuthCredentialRefreshServiceTests: XCTestCase {
    func testPersonalAccessTokensNeverEnterTheOAuthRefreshPath() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = GitHubAccount(
            id: AccountID(rawValue: "account-1")!,
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

    func testAccessTokenWriteFailurePreservesRotatedRefreshToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = makeExpiringOAuthAccount(now: now)
        let vaultKey = try VaultKey.generate()
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
            vaultRegistry: try VaultRegistry(rootDirectory: directory),
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

    private func makeExpiringOAuthAccount(now: Date) -> GitHubAccount {
        GitHubAccount(
            id: AccountID(rawValue: "account-1")!,
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
    private let failingWritesForKinds: Set<TriageSecretKind>
    private var writes = 0

    init(
        values: [Key: Data],
        failingWritesForKinds: Set<TriageSecretKind> = []
    ) {
        self.values = values
        self.failingWritesForKinds = failingWritesForKinds
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
}
