import Foundation
import GRDB
import XCTest
@testable import Triage

final class NotificationPreferenceRepositoryTests: XCTestCase {
    func testConsentIsEncryptedVaultStateAndAccountScoped() async throws {
        let fixture = try await NotificationPreferenceFixture()
        defer { fixture.remove() }
        let repository = NotificationPreferenceRepository(vault: fixture.vault)

        let initialConsent = try await repository.isEnabled(
            accountID: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertFalse(initialConsent)
        try await repository.setEnabled(
            true,
            accountID: fixture.account.id,
            organizationID: fixture.organization.id,
            at: fixture.date
        )
        let persistedConsent = try await repository.isEnabled(
            accountID: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertTrue(persistedConsent)

        let rawValue = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT is_enabled FROM notification_preferences")
        }
        XCTAssertEqual(rawValue, 1)

        let foreignVault = try await fixture.makeForeignVault()
        defer { foreignVault.remove() }
        let foreignRepository = NotificationPreferenceRepository(vault: foreignVault.vault)
        let foreignConsent = try await foreignRepository.isEnabled(
            accountID: foreignVault.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertFalse(foreignConsent)
    }

    func testRejectsOrganizationOutsideAccount() async throws {
        let fixture = try await NotificationPreferenceFixture()
        defer { fixture.remove() }
        let repository = NotificationPreferenceRepository(vault: fixture.vault)

        do {
            try await repository.setEnabled(
                true,
                accountID: fixture.account.id,
                organizationID: OrganizationID(rawValue: "unlinked")!
            )
            XCTFail("Expected account-organization membership validation to fail")
        } catch {
            XCTAssertEqual(error as? NotificationPreferenceRepositoryError, .organizationOutsideAccount)
        }
    }
}

private final class NotificationPreferenceFixture: @unchecked Sendable {
    let root: URL
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let date = Date(timeIntervalSinceReferenceDate: 1_000)

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".triage-notification-preferences-\(UUID().uuidString)", isDirectory: true)
        let accountID = AccountID.make()
        account = .init(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_notification")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
        organization = .init(
            id: OrganizationID(rawValue: "O_notification")!,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_notification")!,
            login: "acme"
        )
        vault = try await VaultRegistry(rootDirectory: root).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(account, credentialRevision: CredentialRevision(rawValue: "credential")!)
        try await accounts.save(
            organization,
            access: .init(
                accountID: accountID,
                organizationID: organization.id,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability")!,
                capabilities: [],
                checkedAt: date
            )
        )
    }

    func makeForeignVault() async throws -> NotificationPreferenceFixture {
        try await NotificationPreferenceFixture()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
