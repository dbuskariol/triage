import XCTest
@testable import Triage

final class AccountRestorationServiceTests: XCTestCase {
    func testRestorationKeepsIndependentAccountsWhenOneVaultKeyIsMalformed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let malformedAccountID = AccountID(rawValue: "account-malformed")!
        let firstAccountID = AccountID(rawValue: "account-first")!
        let secondAccountID = AccountID(rawValue: "account-second")!
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

    private func account(
        id: AccountID,
        credentialID: CredentialID,
        authenticationKind: AuthenticationKind,
        now: Date
    ) -> GitHubAccount {
        GitHubAccount(
            id: id,
            githubUserID: id == AccountID(rawValue: "account-first")! ? 1 : 2,
            nodeID: GitHubNodeID(
                rawValue: id == AccountID(rawValue: "account-first")! ? "U_first" : "U_second"
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

    private let knownAccountIDs: [AccountID]
    private var values: [Key: Data]

    init(accountIDs: [AccountID], values: [Key: Data]) {
        knownAccountIDs = accountIDs
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
