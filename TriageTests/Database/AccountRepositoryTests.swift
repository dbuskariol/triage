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

        XCTAssertEqual(try await repository.accountCapabilities(for: accountID), snapshot)
        let count = try await vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account_capabilities")!
        }
        XCTAssertEqual(count, 1)
    }
}
