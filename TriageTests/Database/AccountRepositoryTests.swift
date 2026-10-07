import XCTest
@testable import Triage

final class AccountRepositoryTests: XCTestCase {
    func testAccountAndOrganizationUpsertsPreserveAccountScopedAccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "github")!
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let repository = AccountRepository(vault: vault)
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjE=")!,
            login: "github"
        )
        let access = OrganizationAccess(
            accountID: accountID,
            organizationID: organizationID,
            state: .available,
            capabilityRevision: CapabilityRevision(rawValue: "cap-1")!,
            capabilities: [
                CapabilityAvailability(
                    capability: .privateRepositories,
                    status: .available,
                    checkedAt: date,
                    detail: "private repositories confirmed"
                )
            ],
            checkedAt: date
        )

        try await repository.save(account, credentialRevision: CredentialRevision(rawValue: "cred-1")!)
        try await repository.save(organization, access: access, selectedAt: date)

        let counts = try await vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM accounts")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account_organizations")!
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        let restoredAccesses = try await repository.organizationAccesses(for: accountID)
        XCTAssertEqual(restoredAccesses[organizationID], access)


    }

    func testAccountCapabilitiesArePersistedSeparatelyFromOrganizationAccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let repository = AccountRepository(vault: vault)
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
        let snapshot = AccountCapabilitySnapshot(
            accountID: accountID,
            capabilities: [
                CapabilityAvailability(
                    capability: .notifications,
                    status: .available,
                    checkedAt: date
                )
            ],
            checkedAt: date
        )

        try await repository.save(account, credentialRevision: CredentialRevision(rawValue: "cred-1")!)
        try await repository.save(snapshot)

        let restoredSnapshot = try await repository.accountCapabilities(for: accountID)
        XCTAssertEqual(restoredSnapshot, snapshot)
        let count = try await vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account_capabilities")!
        }
        XCTAssertEqual(count, 1)
    }

    func testAccountScopedOperationsRejectAnotherVaultAccount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vaultAccountID = AccountID.make()
        let foreignAccountID = AccountID.make()
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: vaultAccountID,
            vaultKey: try VaultKey.generate()
        )
        let repository = AccountRepository(vault: vault)
        let foreignAccount = GitHubAccount(
            id: foreignAccountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: .now,
            lastValidatedAt: .now
        )

        do {
            try await repository.save(
                foreignAccount,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!
            )
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? AccountRepositoryError, .accountScopeMismatch)
        }
        let accounts = try await repository.accounts()
        XCTAssertTrue(accounts.isEmpty)
    }







    private func metadataFixture() async throws -> (
        directory: URL,
        vault: AccountVault,
        accounts: AccountRepository,
        account: GitHubAccount,
        organization: GitHubOrganization,
        scope: SynchronizationScope
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountID = AccountID.make()
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let accounts = AccountRepository(vault: vault)
        let account = testAccount(accountID: accountID)
        let organization = testOrganization(id: "O_metadata", githubID: 42, login: "metadata")
        let access = OrganizationAccess(
            accountID: accountID,
            organizationID: organization.id,
            state: .available,
            capabilityRevision: CapabilityRevision(rawValue: "capability-current")!,
            capabilities: [],
            checkedAt: .now
        )
        try await accounts.save(account, credentialRevision: CredentialRevision(rawValue: "credential-current")!)
        try await accounts.save(organization, access: access)
        let scope = try await accounts.synchronizationScope(for: accountID, organizationID: organization.id)
        return (directory, vault, accounts, account, organization, scope)
    }

    private func testAccount(accountID: AccountID) -> GitHubAccount {
        GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_test")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: .now,
            lastValidatedAt: .now
        )
    }

    private func testOrganization(id: String, githubID: UInt64, login: String) -> GitHubOrganization {
        GitHubOrganization(
            id: OrganizationID(rawValue: id)!,
            githubOrganizationID: githubID,
            nodeID: GitHubNodeID(rawValue: id)!,
            login: login
        )
    }

    private func metadataResponse(for organization: GitHubOrganization) -> GitHubResponse<GitHubOrganizationDTO> {
        let payload = Data("{\"id\":\(organization.githubOrganizationID),\"node_id\":\"\(organization.nodeID.rawValue)\",\"login\":\"\(organization.login)\"}".utf8)
        return GitHubResponse(
            value: GitHubOrganizationDTO(
                id: organization.githubOrganizationID,
                nodeID: organization.nodeID.rawValue,
                login: organization.login,
                avatarURL: nil
            ),
            payload: payload,
            etag: "\"metadata\"",
            lastModified: nil,
            ssoHeader: nil
        )
    }
}
