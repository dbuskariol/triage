import Foundation
import GRDB
import XCTest
@testable import Triage

final class InventoryRepositoryTests: XCTestCase {
    func testRepositoryReconciliationHandlesRenameWithoutChangingImmutableIdentity() async throws {
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
        let result = try await repository.reconcile(
            [renamed],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date.addingTimeInterval(1),
            reconciliationIntent: .incremental
        )

        XCTAssertEqual(result.summaries.map(\.name), ["new-name"])
        XCTAssertEqual(result.returnedRepositoryIDs, [RepositoryID(rawValue: "R_1")!])
        XCTAssertTrue(result.omittedRepositoryIDs.isEmpty)
        let persisted = try await fixture.vault.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT id, github_repository_id, github_node_id, name FROM repositories"
            ).map { row in
                (
                    row["id"] as String,
                    row["github_repository_id"] as String,
                    row["github_node_id"] as String,
                    row["name"] as String
                )
            }
        }
        XCTAssertEqual(persisted.map(\.0), ["R_1"])
        XCTAssertEqual(persisted.map(\.1), ["1"])
        XCTAssertEqual(persisted.map(\.2), ["R_1"])
        XCTAssertEqual(persisted.map(\.3), ["new-name"])
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

        let result = try await repository.reconcile(
            [visibleRepository],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date.addingTimeInterval(60),
            reconciliationIntent: .fullReconciliation
        )

        XCTAssertEqual(result.summaries.map(\.id.rawValue), [visibleRepository.nodeID])
        XCTAssertEqual(
            result.returnedRepositoryIDs,
            [RepositoryID(rawValue: visibleRepository.nodeID)!]
        )
        XCTAssertEqual(
            result.omittedRepositoryIDs,
            [RepositoryID(rawValue: privateRepository.nodeID)!]
        )
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

        let restored = try await repository.reconcile(
            [privateRepository, visibleRepository],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date.addingTimeInterval(120),
            reconciliationIntent: .incremental
        )
        XCTAssertEqual(
            Set(restored.summaries.map(\.id.rawValue)),
            Set([privateRepository.nodeID, visibleRepository.nodeID])
        )
        XCTAssertEqual(
            Set(restored.returnedRepositoryIDs.map(\.rawValue)),
            Set([privateRepository.nodeID, visibleRepository.nodeID])
        )
        XCTAssertTrue(restored.omittedRepositoryIDs.isEmpty)
        let restoredAccess = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT access_state FROM account_repository_access WHERE repository_id = ?",
                arguments: [privateRepository.nodeID]
            )
        }
        XCTAssertEqual(restoredAccess, RepositoryAccessState.available.rawValue)
    }

    func testOmittedPersistedRepositoryWithoutAccessLeafIsReportedAndRepairedToUnknown() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let omitted = fixture.repository(id: 1, nodeID: "R_omitted", name: "omitted")
        let returned = fixture.repository(id: 2, nodeID: "R_returned", name: "returned")
        _ = try await repository.replace(
            [omitted, returned],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        try await fixture.vault.write { database in
            try database.execute(
                sql: "DELETE FROM account_repository_access WHERE account_id = ? AND repository_id = ?",
                arguments: [fixture.account.id.rawValue, omitted.nodeID]
            )
        }

        let result = try await repository.reconcile(
            [returned],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date.addingTimeInterval(1),
            reconciliationIntent: .incremental
        )

        XCTAssertEqual(result.returnedRepositoryIDs, [RepositoryID(rawValue: returned.nodeID)!])
        XCTAssertEqual(result.omittedRepositoryIDs, [RepositoryID(rawValue: omitted.nodeID)!])
        let access = try await fixture.vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT repository_id, access_state
                    FROM account_repository_access
                    WHERE account_id = ?
                    ORDER BY repository_id
                    """,
                arguments: [fixture.account.id.rawValue]
            ).map { (($0["repository_id"] as String), ($0["access_state"] as String)) }
        }
        XCTAssertEqual(access.map(\.0), [omitted.nodeID, returned.nodeID])
        XCTAssertEqual(access.map(\.1), [
            RepositoryAccessState.unknown.rawValue,
            RepositoryAccessState.available.rawValue
        ])
    }

    func testMissingAccessLeafRepairRollsBackWithLaterReconciliationFailure() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let omitted = fixture.repository(id: 1, nodeID: "R_omitted", name: "omitted")
        let returned = fixture.repository(id: 2, nodeID: "R_returned", name: "returned")
        _ = try await repository.replace(
            [omitted, returned],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        try await fixture.vault.write { database in
            try database.execute(
                sql: "DELETE FROM account_repository_access WHERE account_id = ? AND repository_id = ?",
                arguments: [fixture.account.id.rawValue, omitted.nodeID]
            )
            try database.execute(sql: """
                CREATE TRIGGER fail_returned_repository_access
                BEFORE UPDATE OF access_state ON account_repository_access
                WHEN NEW.repository_id = 'R_returned' AND NEW.access_state = 'available'
                BEGIN
                    SELECT RAISE(ABORT, 'forced reconciliation failure');
                END
                """)
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.reconcile(
                [returned],
                accountID: fixture.account.id,
                organization: fixture.organization,
                observedAt: fixture.date.addingTimeInterval(1),
                reconciliationIntent: .fullReconciliation
            )
        } verify: { error in
            XCTAssertTrue(error is DatabaseError)
        }

        let access = try await fixture.vault.read { database in
            (
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT access_state FROM account_repository_access
                        WHERE account_id = ? AND repository_id = ?
                        """,
                    arguments: [fixture.account.id.rawValue, omitted.nodeID]
                ) as String?,
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT access_state FROM account_repository_access
                        WHERE account_id = ? AND repository_id = ?
                        """,
                    arguments: [fixture.account.id.rawValue, returned.nodeID]
                ) as String?
            )
        }
        XCTAssertNil(access.0)
        XCTAssertEqual(access.1, RepositoryAccessState.available.rawValue)
    }

    func testSameNameDifferentNodeFailsClosedWithoutDeletingPersistedGraph() async throws {
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
        let replacement = fixture.repository(id: 2, nodeID: "R_new", name: "RECREATED")

        for intent in [
            SynchronizationReconciliationIntent.incremental,
            .fullReconciliation
        ] {
            await XCTAssertThrowsErrorAsync {
                _ = try await repository.reconcile(
                    [replacement],
                    accountID: fixture.account.id,
                    organization: fixture.organization,
                    observedAt: fixture.date.addingTimeInterval(60),
                    reconciliationIntent: intent
                )
            } verify: { error in
                XCTAssertEqual(
                    error as? RepositoryInventoryRepositoryError,
                    .immutableIdentityConflict
                )
            }
        }

        let persisted = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT id FROM repositories ORDER BY id"),
                try String.fetchOne(
                    database,
                    sql: "SELECT repository_id FROM github_nodes WHERE github_node_id = ?",
                    arguments: [oldNode.nodeID.rawValue]
                ) as String?,
                try String.fetchOne(
                    database,
                    sql: "SELECT access_state FROM account_repository_access WHERE repository_id = ?",
                    arguments: [oldRepository.nodeID]
                ) as String?
            )
        }
        XCTAssertEqual(persisted.0, [oldRepository.nodeID])
        XCTAssertEqual(persisted.1, oldRepository.nodeID)
        XCTAssertEqual(persisted.2, RepositoryAccessState.available.rawValue)
    }

    func testSameNodeWithChangedNumericGitHubIDFailsClosed() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let original = fixture.repository(id: 1, nodeID: "R_1", name: "retained")
        _ = try await repository.replace(
            [original],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        let changedNumericID = fixture.repository(id: 2, nodeID: "R_1", name: "retained")

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.reconcile(
                [changedNumericID],
                accountID: fixture.account.id,
                organization: fixture.organization,
                observedAt: fixture.date.addingTimeInterval(1),
                reconciliationIntent: .incremental
            )
        } verify: { error in
            XCTAssertEqual(
                error as? RepositoryInventoryRepositoryError,
                .immutableIdentityConflict
            )
        }

        let identity = try await fixture.persistedRepositoryIdentity()
        XCTAssertEqual(identity, .init(id: "R_1", numericID: "1", nodeID: "R_1", access: "available"))
    }

    func testSameNumericGitHubIDWithChangedNodeFailsClosed() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let original = fixture.repository(id: 1, nodeID: "R_1", name: "retained")
        _ = try await repository.replace(
            [original],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        let changedNodeID = fixture.repository(id: 1, nodeID: "R_2", name: "different-name")

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.reconcile(
                [changedNodeID],
                accountID: fixture.account.id,
                organization: fixture.organization,
                observedAt: fixture.date.addingTimeInterval(1),
                reconciliationIntent: .fullReconciliation
            )
        } verify: { error in
            XCTAssertEqual(
                error as? RepositoryInventoryRepositoryError,
                .immutableIdentityConflict
            )
        }

        let identity = try await fixture.persistedRepositoryIdentity()
        XCTAssertEqual(identity, .init(id: "R_1", numericID: "1", nodeID: "R_1", access: "available"))
    }

    func testDuplicateCaseFoldedOwnerAndNameFailsBeforeMutation() async throws {
        let fixture = try await InventoryFixture()
        defer { fixture.remove() }
        let repository = RepositoryInventoryRepository(vault: fixture.vault)
        let original = fixture.repository(id: 1, nodeID: "R_1", name: "retained")
        _ = try await repository.replace(
            [original],
            accountID: fixture.account.id,
            organization: fixture.organization,
            observedAt: fixture.date
        )
        let first = fixture.repository(id: 2, nodeID: "R_2", name: "Case-Name")
        let second = fixture.repository(id: 3, nodeID: "R_3", name: "case-name")

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.reconcile(
                [first, second],
                accountID: fixture.account.id,
                organization: fixture.organization,
                observedAt: fixture.date.addingTimeInterval(1),
                reconciliationIntent: .incremental
            )
        } verify: { error in
            XCTAssertEqual(error as? RepositoryInventoryRepositoryError, .duplicateRepository)
        }

        let identity = try await fixture.persistedRepositoryIdentity()
        XCTAssertEqual(identity, .init(id: "R_1", numericID: "1", nodeID: "R_1", access: "available"))
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

    func persistedRepositoryIdentity() async throws -> PersistedRepositoryIdentity? {
        try await vault.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT repositories.id, repositories.github_repository_id,
                           repositories.github_node_id, account_repository_access.access_state
                    FROM repositories
                    JOIN account_repository_access
                      ON account_repository_access.repository_id = repositories.id
                    WHERE account_repository_access.account_id = ?
                    """,
                arguments: [account.id.rawValue]
            ).map { row in
                PersistedRepositoryIdentity(
                    id: row["id"],
                    numericID: row["github_repository_id"],
                    nodeID: row["github_node_id"],
                    access: row["access_state"]
                )
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct PersistedRepositoryIdentity: Equatable {
    let id: String
    let numericID: String
    let nodeID: String
    let access: String
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
