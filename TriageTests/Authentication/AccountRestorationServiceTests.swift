import XCTest
@testable import Triage

final class AccountRestorationServiceTests: XCTestCase {
    func testRestorationKeepsIndependentAccountsWhenOneVaultKeyIsMalformed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let malformedAccountID = AccountID.make()
        let firstAccountID = AccountID.make()
        let secondAccountID = AccountID.make()
        let firstCredentialID = CredentialID(rawValue: "credential-first")!
        let secondCredentialID = CredentialID(rawValue: "credential-second")!
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let registry = try VaultRegistry(rootDirectory: directory)
        let firstVaultKey = try VaultKey.generate()
        let secondVaultKey = try VaultKey.generate()
        let firstVault = try await registry.open(accountID: firstAccountID, vaultKey: firstVaultKey)
        let secondVault = try await registry.open(accountID: secondAccountID, vaultKey: secondVaultKey)
        let firstAccount = account(
            id: firstAccountID,
            credentialID: firstCredentialID,
            authenticationKind: .fineGrainedPersonalAccessToken,
            now: now
        )
        let secondAccount = account(
            id: secondAccountID,
            credentialID: secondCredentialID,
            authenticationKind: .oauth,
            now: now
        )
        try await AccountRepository(vault: firstVault).save(
            firstAccount,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-first")!
        )
        try await AccountRepository(vault: secondVault).save(
            secondAccount,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-second")!
        )
        let notificationSnapshot = AccountCapabilitySnapshot(
            accountID: secondAccountID,
            capabilities: [
                CapabilityAvailability(
                    capability: .notifications,
                    status: .available,
                    checkedAt: now
                )
            ],
            checkedAt: now
        )
        try await AccountRepository(vault: secondVault).save(notificationSnapshot)

        let secrets = InMemorySecretStore(
            accountIDs: [malformedAccountID, firstAccountID, secondAccountID],
            values: [
                .init(kind: .vaultKey, accountID: malformedAccountID, credentialID: nil): Data([0]),
                .init(kind: .vaultKey, accountID: firstAccountID, credentialID: nil): firstVaultKey.data,
                .init(kind: .vaultKey, accountID: secondAccountID, credentialID: nil): secondVaultKey.data,
                .init(
                    kind: .personalAccessToken,
                    accountID: firstAccountID,
                    credentialID: firstCredentialID
                ): Data("first-token".utf8),
                .init(
                    kind: .oauthAccessToken,
                    accountID: secondAccountID,
                    credentialID: secondCredentialID
                ): Data("second-token".utf8)
            ]
        )

        let result = try await AccountRestorationService(
            secretStore: secrets,
            vaultRegistry: registry
        ).restore()

        XCTAssertEqual(result.accounts, [firstAccount, secondAccount])
        XCTAssertEqual(result.organizationsByAccount[firstAccountID], [])
        XCTAssertEqual(result.organizationsByAccount[secondAccountID], [])
        XCTAssertEqual(result.accountCapabilitiesByAccount[secondAccountID], notificationSnapshot)
        XCTAssertEqual(result.unavailableAccountIDs, [malformedAccountID])
    }

    func testAccessTokenReadFailureDoesNotMasqueradeAsUnavailableVaultKey() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let credentialID = CredentialID(rawValue: "credential-token-read-failure")!
        let vaultKey = try VaultKey.generate()
        let registry = try VaultRegistry(rootDirectory: directory)
        let vault = try await registry.open(accountID: accountID, vaultKey: vaultKey)
        let account = account(
            id: accountID,
            credentialID: credentialID,
            authenticationKind: .oauth,
            now: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-revision-token-read-failure")!
        )

        let tokenKey = InMemorySecretStore.Key(
            kind: .oauthAccessToken,
            accountID: accountID,
            credentialID: credentialID
        )
        let secrets = InMemorySecretStore(
            accountIDs: [accountID],
            values: [
                .init(kind: .vaultKey, accountID: accountID, credentialID: nil): vaultKey.data
            ],
            failingReadKey: tokenKey
        )

        do {
            _ = try await AccountRestorationService(
                secretStore: secrets,
                vaultRegistry: registry
            ).restore()
            XCTFail("A token-read failure must remain retryable, not become a keyless-vault account.")
        } catch let error as InMemorySecretStore.Failure {
            XCTAssertEqual(error, .configuredReadFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testVaultKeyReadFailureDoesNotExposeDestructiveUnavailableKeyRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let vaultKeyKey = InMemorySecretStore.Key(
            kind: .vaultKey,
            accountID: accountID,
            credentialID: nil
        )
        let secrets = InMemorySecretStore(
            accountIDs: [accountID],
            values: [:],
            failingReadKey: vaultKeyKey
        )

        do {
            _ = try await AccountRestorationService(
                secretStore: secrets,
                vaultRegistry: try VaultRegistry(rootDirectory: directory)
            ).restore()
            XCTFail("A vault-key read failure must remain retryable, not become a keyless-vault account.")
        } catch let error as InMemorySecretStore.Failure {
            XCTAssertEqual(error, .configuredReadFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnsafeAccountIDWithAKeyRemainsANonDestructiveRestorationFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unsafeAccountID = try XCTUnwrap(AccountID(rawValue: "../outside"))
        let secrets = InMemorySecretStore(
            accountIDs: [unsafeAccountID],
            values: [
                .init(kind: .vaultKey, accountID: unsafeAccountID, credentialID: nil): try VaultKey.generate().data
            ]
        )

        do {
            _ = try await AccountRestorationService(
                secretStore: secrets,
                vaultRegistry: try VaultRegistry(rootDirectory: directory)
            ).restore()
            XCTFail("Unsafe account identifiers must not be classified as removable unavailable vaults.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .unsafeAccountIDPath)
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Vaults", isDirectory: true).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.deletingLastPathComponent().appendingPathComponent("outside").path
        ))
    }

    func testUnsafeAccountIDWithMissingOrMalformedKeyIsNeverClassifiedAsRemovableUnavailableData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingKeyID = try XCTUnwrap(AccountID(rawValue: "../missing-key"))
        let malformedKeyID = try XCTUnwrap(AccountID(rawValue: "../malformed-key"))
        let secrets = InMemorySecretStore(
            accountIDs: [missingKeyID, malformedKeyID],
            values: [
                .init(kind: .vaultKey, accountID: malformedKeyID, credentialID: nil): Data([0])
            ]
        )

        do {
            _ = try await AccountRestorationService(
                secretStore: secrets,
                vaultRegistry: try VaultRegistry(rootDirectory: directory)
            ).restore()
            XCTFail("Unsafe identifiers must not be offered as unavailable-key recovery candidates.")
        } catch let error as VaultError {
            XCTAssertEqual(error, .unsafeAccountIDPath)
        }
    }

    func testVaultIntegrityMigrationAndSQLCipherFailuresBecomeRepairIssuesNeverUnavailableAccounts() throws {
        let accountID = AccountID.make()
        let expected: [(VaultError, AccountVaultRecoveryIssue.Kind)] = [
            (.invalidIntegrityCheck, .databaseCorruption),
            (.invalidMigrationBackup, .migrationFailure),
            (.unsupportedDestructiveMigration("test-only-migration"), .migrationFailure),
            (.sqlCipherUnavailable, .sqlCipherUnavailable)
        ]

        for (error, kind) in expected {
            XCTAssertEqual(AccountRestorationService.recoveryIssueKind(for: error), kind)
            let snapshot = try AccountSessionSnapshot(
                accounts: [],
                organizationsByAccount: [:],
                organizationAccessesByAccount: [:],
                accountCapabilitiesByAccount: [:],
                vaultRecoveryIssues: [
                    AccountVaultRecoveryIssue(
                        accountID: accountID,
                        kind: kind,
                        verifiedBackupMigrationIDs: []
                    )
                ]
            )
            XCTAssertTrue(snapshot.unavailableAccountIDs.isEmpty)
            XCTAssertEqual(snapshot.vaultRecoveryIssues.map(\.accountID), [accountID])
        }

        XCTAssertNil(AccountRestorationService.recoveryIssueKind(for: .accountBeingRemoved))
        XCTAssertNil(AccountRestorationService.recoveryIssueKind(for: .missingApplicationSupportDirectory))
    }

    private func account(
        id: AccountID,
        credentialID: CredentialID,
        authenticationKind: AuthenticationKind,
        now: Date
    ) -> GitHubAccount {
        GitHubAccount(
            id: id,
            githubUserID: authenticationKind == .fineGrainedPersonalAccessToken ? 1 : 2,
            nodeID: GitHubNodeID(
                rawValue: authenticationKind == .fineGrainedPersonalAccessToken ? "U_first" : "U_second"
            )!,
            login: id.rawValue,
            authenticationKind: authenticationKind,
            credentialID: credentialID,
            credentialStatus: .active,
            createdAt: now,
            lastValidatedAt: now
        )
    }
}

private actor InMemorySecretStore: SecretStore {
    struct Key: Hashable, Sendable {
        let kind: TriageSecretKind
        let accountID: AccountID
        let credentialID: CredentialID?
    }

    enum Failure: Error, Equatable, Sendable {
        case configuredReadFailure
    }

    private let knownAccountIDs: [AccountID]
    private var values: [Key: Data]
    private let failingReadKey: Key?

    init(
        accountIDs: [AccountID],
        values: [Key: Data],
        failingReadKey: Key? = nil
    ) {
        knownAccountIDs = accountIDs
        self.values = values
        self.failingReadKey = failingReadKey
    }

    func read(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws -> Data? {
        let key = Key(kind: kind, accountID: accountID, credentialID: credentialID)
        if key == failingReadKey {
            throw Failure.configuredReadFailure
        }
        return values[key]
    }

    func write(
        _ value: Data,
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)] = value
    }

    func remove(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws {
        values[Key(kind: kind, accountID: accountID, credentialID: credentialID)] = nil
    }

    func accountIDs() async throws -> [AccountID] {
        knownAccountIDs
    }
}
