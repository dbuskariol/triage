import Foundation
import GRDB
import XCTest
@testable import Triage

final class InventoryRepositoryTests: XCTestCase {
    func testRepositoryReplacementHandlesRenameAndOnlyDeletesAfterReplacement() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let original = fixture.repository(id: 1, nodeID: "R_1", name: "old-name")

        try await repository.replace(
            [original],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        let renamed = fixture.repository(id: 1, nodeID: "R_1", name: "new-name")
        let summaries = try await repository.replace(
            [renamed],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date.addingTimeInterval(1)
        )

        XCTAssertEqual(summaries.map(\.name), ["new-name"])
        let persisted = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM repositories")
        }
        XCTAssertEqual(persisted, ["new-name"])
    }

    func testTeamReplacementStoresExplicitCurrentAccountMembershipState() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = TeamInventoryRepository(vault: fixture.vault)
        let team = GitHubTeamDTO(
            id: 1,
            nodeID: "T_1",
            name: "Triage",
            slug: "triage",
            privacy: "closed"
        )

        let summaries = try await repository.replace(
            teams: [team],
            memberships: [
                TeamMembershipObservation(
                    teamID: TeamID(rawValue: team.nodeID)!,
                    membership: .authoritativeNonMembership(
                        GitHubResponse(
                            value: GitHubTeamMembershipDTO(state: "none", role: nil),
                            payload: Data(#"{"state":"none"}"#.utf8),
                            etag: nil,
                            lastModified: nil,
                            ssoHeader: nil
                        )
                    )
                )
            ],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )

        XCTAssertEqual(summaries.first?.membershipState, "none")
        let membership = try await fixture.vault.read { database in
            try String.fetchOne(database, sql: "SELECT membership_state FROM team_memberships")
        }
        XCTAssertEqual(membership, "none")
    }

    func testUnknownMembershipDoesNotEraseActiveMembershipAndIsPartialCoverage() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = TeamInventoryRepository(vault: fixture.vault)
        let team = GitHubTeamDTO(
            id: 1,
            nodeID: "T_1",
            name: "Triage",
            slug: "triage",
            privacy: "closed"
        )
        let activeResponse = GitHubResponse(
            value: GitHubTeamMembershipDTO(state: "active", role: "member"),
            payload: Data(#"{"state":"active","role":"member"}"#.utf8),
            etag: nil,
            lastModified: nil,
            ssoHeader: nil
        )
        try await repository.replace(
            teams: [team],
            memberships: [
                TeamMembershipObservation(
                    teamID: TeamID(rawValue: team.nodeID)!,
                    membership: .member(activeResponse)
                )
            ],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.replace(
                teams: [team],
                memberships: [
                    TeamMembershipObservation(
                        teamID: TeamID(rawValue: team.nodeID)!,
                        membership: .unknown
                    )
                ],
                accountID: fixture.account.id,
                organization: fixture.organization,
                observedAt: fixture.date.addingTimeInterval(1)
            )
        } verify: { error in
            XCTAssertEqual(error as? TeamInventoryRepositoryError, .unknownMembershipVisibility)
        }

        let membership = try await fixture.vault.read { database in
            try String.fetchOne(database, sql: "SELECT membership_state FROM team_memberships")
        }
        XCTAssertEqual(membership, "active")
        XCTAssertEqual(
            OrganizationInventoryRefreshService.coverageStatus(
                for: GitHubRepositoryTeamClientError.ambiguousMembershipVisibility
            ),
            .partial
        )
    }

    func testInvalidRepositoryPageDoesNotDeletePriorAuthoritativeInventory() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let original = fixture.repository(id: 1, nodeID: "R_1", name: "retained")
        try await repository.replace(
            [original],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        var invalid = fixture.repository(id: 2, nodeID: "R_2", name: "invalid")
        invalid = GitHubRepositoryDTO(
            id: invalid.id,
            nodeID: invalid.nodeID,
            name: invalid.name,
            isPrivate: invalid.isPrivate,
            isArchived: invalid.isArchived,
            hasDiscussions: invalid.hasDiscussions,
            htmlURL: invalid.htmlURL,
            updatedAt: invalid.updatedAt,
            owner: .init(login: "other")
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.replace(
                [invalid],
                accountID: fixture.account.id,
                organization: fixture.organization,
                observedAt: fixture.date.addingTimeInterval(1)
            )
        } verify: { error in
            XCTAssertEqual(error as? RepositoryInventoryRepositoryError, .invalidRepository)
        }

        let retainedNames = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM repositories")
        }
        XCTAssertEqual(retainedNames, ["retained"])
    }

    func testCachedETagAndExistingRepositoriesAreAvailableForNotModifiedResponse() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let existing = fixture.repository(id: 1, nodeID: "R_1", name: "retained")
        try await repository.replace(
            [existing],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        try await RawAPISnapshotRepository(vault: fixture.vault).save(
            RawAPISnapshot(
                id: RawAPISnapshotID.make(),
                accountID: fixture.account.id,
                githubNodeID: nil,
                endpoint: "/orgs/acme/repos?type=all&per_page=100",
                eTag: "\"inventory-v1\"",
                parserVersion: 1,
                observedAt: fixture.date,
                payload: Data("[]".utf8)
            )
        )

        let cachedETag = try await repository.cachedETag(
            accountID: fixture.account.id,
            organization: fixture.organization,
            fullReconciliationCutoff: fixture.date.addingTimeInterval(-1)
        )
        XCTAssertEqual(cachedETag, "\"inventory-v1\"")
        let staleETag = try await repository.cachedETag(
            accountID: fixture.account.id,
            organization: fixture.organization,
            fullReconciliationCutoff: fixture.date.addingTimeInterval(1)
        )
        XCTAssertNil(staleETag)
        let existingRepositories = try await repository.repositories(
            accountID: fixture.account.id,
            organization: fixture.organization
        )
        XCTAssertEqual(existingRepositories.map(\.name), ["retained"])
    }

    func testRepositoryReplacementRejectsOrganizationOutsideAccountScope() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let unlinkedOrganization = GitHubOrganization(
            id: OrganizationID(rawValue: "unlinked")!,
            githubOrganizationID: 9,
            nodeID: GitHubNodeID(rawValue: "O_9")!,
            login: "other"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.replace(
                [],
                accountID: fixture.account.id,
                organization: unlinkedOrganization,
                observedAt: fixture.date
            )
        } verify: { error in
            XCTAssertEqual(
                error as? RepositoryInventoryRepositoryError,
                .organizationScopeMismatch
            )
        }
    }
}

private final class InventoryFixture: @unchecked Sendable {
    let root: URL
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let date: Date

    init() async throws {
        let observedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".triage-inventory-test-\(UUID().uuidString)", isDirectory: true)
        date = observedAt
        let accountID = AccountID.make()
        account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt,
            lastValidatedAt: observedAt
        )
        organization = GitHubOrganization(
            id: OrganizationID(rawValue: "acme")!,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_2")!,
            login: "acme"
        )
        vault = try await VaultRegistry(rootDirectory: root).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let accountRepository = AccountRepository(vault: vault)
        try await accountRepository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await accountRepository.save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organization.id,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: observedAt
            )
        )
    }

    func repository(id: UInt64, nodeID: String, name: String) -> GitHubRepositoryDTO {
        GitHubRepositoryDTO(
            id: id,
            nodeID: nodeID,
            name: name,
            isPrivate: true,
            isArchived: false,
            hasDiscussions: true,
            htmlURL: URL(string: "https://github.com/acme/\(name)")!,
            updatedAt: date,
            owner: .init(login: "acme")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        verify(error)
    }
}
