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

    func testExistingRepositoriesAreAvailableForNotModifiedResponse() async throws {
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
        let existingRepositories = try await repository.repositories(
            accountID: fixture.account.id,
            organization: fixture.organization
        )
        XCTAssertEqual(existingRepositories.map(\.name), ["retained"])
    }

    func testUnavailableRepositoryAccessIsExcludedFromRefreshCandidates() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        try await repository.replace(
            [fixture.repository(id: 1, nodeID: "R_1", name: "revoked")],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    UPDATE account_repository_access
                    SET access_state = 'unavailable'
                    WHERE account_id = ? AND repository_id = ?
                    """,
                arguments: [fixture.account.id.rawValue, "R_1"]
            )
        }

        let candidates = try await repository.repositories(
            accountID: fixture.account.id,
            organization: fixture.organization
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testInventoryOmissionRetainsPrivateTopologyAndMarksAccessUnknown() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let privateRepository = fixture.repository(id: 1, nodeID: "R_private", name: "private")
        let visibleRepository = fixture.repository(id: 2, nodeID: "R_visible", name: "visible")
        _ = try await repository.replace(
            [privateRepository, visibleRepository],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        let cachedNode = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "I_private")!,
            accountID: fixture.account.id,
            organizationID: fixture.organization.id,
            repositoryID: RepositoryID(rawValue: privateRepository.nodeID)!,
            kind: .issue,
            numericID: "101",
            number: 1,
            title: "Retained private issue",
            state: .open,
            url: URL(string: "https://github.com/acme/private/issues/1")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: fixture.date,
            updatedAt: fixture.date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "private-1",
            observedAt: fixture.date,
            accessibility: .accessible
        )
        try await GitHubNodeRepository(vault: fixture.vault).save(cachedNode)

        let summaries = try await repository.replace(
            [visibleRepository],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date.addingTimeInterval(60)
        )

        XCTAssertEqual(summaries.map(\.id.rawValue), [visibleRepository.nodeID])
        let retained = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM repositories"),
                try String.fetchOne(
                    database,
                    sql: "SELECT access_state FROM account_repository_access WHERE repository_id = ?",
                    arguments: [privateRepository.nodeID]
                ),
                try String.fetchOne(
                    database,
                    sql: "SELECT repository_id FROM github_nodes WHERE github_node_id = ?",
                    arguments: [cachedNode.nodeID.rawValue]
                )
            )
        }
        XCTAssertEqual(retained.0, 2)
        XCTAssertEqual(retained.1, RepositoryAccessState.unknown.rawValue)
        XCTAssertEqual(retained.2, privateRepository.nodeID)
        let omittedCandidates = try await repository.repositories(
            accountID: fixture.account.id,
            organization: fixture.organization
        )
        XCTAssertEqual(omittedCandidates.map(\.id.rawValue), [visibleRepository.nodeID])

        let restored = try await repository.replace(
            [privateRepository, visibleRepository],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date.addingTimeInterval(120)
        )
        XCTAssertEqual(
            Set(restored.map(\.id.rawValue)),
            Set([privateRepository.nodeID, visibleRepository.nodeID])
        )
        let restoredAccess = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT access_state FROM account_repository_access WHERE repository_id = ?",
                arguments: [privateRepository.nodeID]
            )
        }
        XCTAssertEqual(restoredAccess, RepositoryAccessState.available.rawValue)
    }

    func testSameNameDifferentNodeIsExplicitReplacementEvidence() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let oldRepository = fixture.repository(id: 1, nodeID: "R_old", name: "recreated")
        _ = try await repository.replace(
            [oldRepository],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        let oldNode = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "I_old")!,
            accountID: fixture.account.id,
            organizationID: fixture.organization.id,
            repositoryID: RepositoryID(rawValue: oldRepository.nodeID)!,
            kind: .issue,
            numericID: "1",
            number: 1,
            title: "Old identity",
            state: .open,
            url: URL(string: "https://github.com/acme/recreated/issues/1")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: fixture.date,
            updatedAt: fixture.date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "old",
            observedAt: fixture.date,
            accessibility: .accessible
        )
        try await GitHubNodeRepository(vault: fixture.vault).save(oldNode)
        let replacement = fixture.repository(id: 2, nodeID: "R_new", name: "recreated")

        _ = try await repository.replace(
            [replacement],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date.addingTimeInterval(60)
        )

        let persisted = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT id FROM repositories ORDER BY id"),
                try String.fetchOne(
                    database,
                    sql: "SELECT repository_id FROM github_nodes WHERE github_node_id = ?",
                    arguments: [oldNode.nodeID.rawValue]
                ) as String?
            )
        }
        XCTAssertEqual(persisted.0, [replacement.nodeID])
        XCTAssertNil(persisted.1)
    }

    func testInventoryOmissionDoesNotChangeSiblingOrganizationAccess() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let siblingOrganization = GitHubOrganization(
            id: OrganizationID(rawValue: "beta")!,
            githubOrganizationID: 3,
            nodeID: GitHubNodeID(rawValue: "O_3")!,
            login: "beta"
        )
        try await AccountRepository(vault: fixture.vault).save(
            siblingOrganization,
            access: OrganizationAccess(
                accountID: fixture.account.id,
                organizationID: siblingOrganization.id,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: fixture.date
            )
        )
        let acmeRepository = fixture.repository(id: 1, nodeID: "R_acme", name: "acme-private")
        let betaRepository = fixture.repository(
            id: 2,
            nodeID: "R_beta",
            name: "beta-private",
            owner: "beta"
        )
        _ = try await repository.replace(
            [acmeRepository],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        _ = try await repository.replace(
            [betaRepository],
            accountID: fixture.account.id,
            organization: siblingOrganization,
            observedAt: fixture.date
        )

        _ = try await repository.replace(
            [],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date.addingTimeInterval(60)
        )

        let states = try await fixture.vault.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT repository_id, access_state FROM account_repository_access ORDER BY repository_id"
            ).map { (($0["repository_id"] as String), ($0["access_state"] as String)) }
        }
        XCTAssertEqual(states.map(\.0), [acmeRepository.nodeID, betaRepository.nodeID])
        XCTAssertEqual(states.map(\.1), [
            RepositoryAccessState.unknown.rawValue,
            RepositoryAccessState.available.rawValue
        ])
    }

    func testOmittedDiscussionCapabilityRemainsExplicitlyUnknown() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let value = fixture.repository(id: 1, nodeID: "R_1", name: "unknown")
        let omitted = GitHubRepositoryDTO(
            id: value.id,
            nodeID: value.nodeID,
            name: value.name,
            isPrivate: value.isPrivate,
            isArchived: value.isArchived,
            hasDiscussions: nil,
            htmlURL: value.htmlURL,
            updatedAt: value.updatedAt,
            owner: value.owner
        )

        let summaries = try await repository.replace(
            [omitted], accountID: fixture.account.id,
            organization: fixture.organization, observedAt: fixture.date
        )

        XCTAssertEqual(summaries.first?.hasDiscussions, false)
        XCTAssertEqual(summaries.first?.hasDiscussionsKnown, false)
        let known = try await fixture.vault.read { database in
            try Bool.fetchOne(database, sql: "SELECT has_discussions_known FROM repositories")
        }
        XCTAssertEqual(known, false)
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

    func repository(
        id: UInt64,
        nodeID: String,
        name: String,
        owner: String = "acme"
    ) -> GitHubRepositoryDTO {
        GitHubRepositoryDTO(
            id: id,
            nodeID: nodeID,
            name: name,
            isPrivate: true,
            isArchived: false,
            hasDiscussions: true,
            htmlURL: URL(string: "https://github.com/\(owner)/\(name)")!,
            updatedAt: date,
            owner: .init(login: owner)
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
