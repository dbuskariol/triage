import XCTest
@testable import Triage

final class TimelineCandidateRepositoryTests: XCTestCase {
    func testFailedOldestCandidatesRotateBehindNeverAttemptedCandidates() async throws {
        let fixture = try await TimelineCandidateFixture()
        defer { fixture.remove() }
        let repository = TimelineCandidateRepository(vault: fixture.vault)

        let firstInventory = try await repository.candidates(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            limit: 2
        )
        XCTAssertEqual(firstInventory.candidates.map(\.nodeID), Array(fixture.nodeIDs.prefix(2)))
        XCTAssertTrue(firstInventory.hasRemainingCandidates)

        for candidate in firstInventory.candidates {
            try await repository.fail(
                candidate: candidate,
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                at: fixture.observedAt.addingTimeInterval(60)
            )
        }

        let rotatedInventory = try await repository.candidates(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            limit: 2
        )
        XCTAssertEqual(rotatedInventory.candidates.first?.nodeID, fixture.nodeIDs[2])
        XCTAssertTrue(rotatedInventory.hasRemainingCandidates)
    }
}

private final class TimelineCandidateFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "acme")!
    let repositoryID = RepositoryID(rawValue: "R_1")!
    let observedAt = Date(timeIntervalSinceReferenceDate: 20_000)
    let nodeIDs = ["I_1", "I_2", "I_3"].map { GitHubNodeID(rawValue: $0)! }
    let vault: AccountVault

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".triage-timeline-candidate-\(UUID().uuidString)", isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let milliseconds = Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
        try await vault.writeTransaction { database in
            try database.execute(
                sql: """
                    INSERT INTO accounts (
                        id, github_user_id, github_node_id, login, display_name, avatar_url,
                        authentication_kind, credential_id, credential_status, credential_revision,
                        created_at_ms, last_validated_at_ms, disabled_at_ms
                    ) VALUES (?, 1, 'U_1', 'octocat', NULL, NULL, 'oauth', 'credential-1', 'active',
                              'credential-revision-1', ?, ?, NULL)
                    """,
                arguments: [accountID.rawValue, milliseconds, milliseconds]
            )
            try database.execute(
                sql: """
                    INSERT INTO organizations (
                        id, github_organization_id, github_node_id, login, display_name, avatar_url, updated_at_ms
                    ) VALUES (?, 2, 'O_1', 'acme', NULL, NULL, ?)
                    """,
                arguments: [organizationID.rawValue, milliseconds]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_organizations (
                        account_id, organization_id, access_state, capability_revision, checked_at_ms, selected_at_ms
                    ) VALUES (?, ?, 'available', 'capability-revision-1', ?, ?)
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue, milliseconds, milliseconds]
            )
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login, name,
                        is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, 3, 'R_NODE_1', 'acme', 'widget', 1, 0, 0,
                              'https://github.com/acme/widget', ?, NULL)
                    """,
                arguments: [repositoryID.rawValue, organizationID.rawValue, milliseconds]
            )
            for (index, nodeID) in nodeIDs.enumerated() {
                let number = index + 1
                try database.execute(
                    sql: """
                        INSERT INTO github_nodes (
                            github_node_id, account_id, organization_id, repository_id, kind,
                            numeric_id, number, title, state, html_url, body_markdown, author_id,
                            created_at_ms, updated_at_ms, closed_at_ms, merged_at_ms,
                            source_revision, last_observed_at_ms, accessibility_state
                        ) VALUES (?, ?, ?, ?, 'issue', ?, ?, ?, 'open', ?, NULL, NULL,
                                  ?, ?, NULL, NULL, ?, ?, 'accessible')
                        """,
                    arguments: [
                        nodeID.rawValue, accountID.rawValue, organizationID.rawValue, repositoryID.rawValue,
                        String(number), number, "Issue \(number)",
                        "https://github.com/acme/widget/issues/\(number)",
                        milliseconds, milliseconds, "revision-\(number)", milliseconds
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO issues (
                            github_node_id, locked, comments_count, assignee_node_ids_json,
                            label_node_ids_json, milestone_node_id, updated_at_ms
                        ) VALUES (?, 0, 0, '[]', '[]', NULL, ?)
                        """,
                    arguments: [nodeID.rawValue, milliseconds]
                )
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
