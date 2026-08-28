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

        let remoteRepository = GitHubRepositoryDTO(
            id: 3,
            nodeID: "MDEwOlJlcG9zaXRvcnkz",
            name: "triage",
            isPrivate: true,
            isArchived: false,
            hasDiscussions: true,
            htmlURL: URL(string: "https://github.com/github/triage")!,
            updatedAt: date,
            owner: .init(login: "github")
        )
        _ = try await repository.save(
            repository: remoteRepository,
            organizationID: organizationID,
            accountID: accountID
        )
        let updatedRepository = GitHubRepositoryDTO(
            id: remoteRepository.id,
            nodeID: remoteRepository.nodeID,
            name: remoteRepository.name,
            isPrivate: remoteRepository.isPrivate,
            isArchived: remoteRepository.isArchived,
            hasDiscussions: false,
            htmlURL: remoteRepository.htmlURL,
            updatedAt: remoteRepository.updatedAt.addingTimeInterval(1),
            owner: remoteRepository.owner
        )
        let summary = try await repository.save(
            repository: updatedRepository,
            organizationID: organizationID,
            accountID: accountID
        )
        XCTAssertFalse(summary.hasDiscussions)
        let repositoryWithOmittedDiscussions = GitHubRepositoryDTO(
            id: updatedRepository.id,
            nodeID: updatedRepository.nodeID,
            name: updatedRepository.name,
            isPrivate: updatedRepository.isPrivate,
            isArchived: updatedRepository.isArchived,
            hasDiscussions: nil,
            htmlURL: updatedRepository.htmlURL,
            updatedAt: updatedRepository.updatedAt.addingTimeInterval(1),
            owner: updatedRepository.owner
        )
        let preservedSummary = try await repository.save(
            repository: repositoryWithOmittedDiscussions,
            organizationID: organizationID,
            accountID: accountID
        )
        XCTAssertFalse(preservedSummary.hasDiscussions)
        let persistedHasDiscussions = try await vault.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT has_discussions FROM repositories WHERE id = ?",
                arguments: [summary.id.rawValue]
            )
        }
        XCTAssertEqual(persistedHasDiscussions, false)
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
        XCTAssertTrue(try await repository.accounts().isEmpty)
    }
}
