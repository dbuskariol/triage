import Foundation
import GRDB
import XCTest
@testable import Triage

final class WorkItemTransferTests: XCTestCase {
    func testTransferKeepsWorkItemIDAndRebuildsDestinationMemberships() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-item-transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let sourceOrganizationID = OrganizationID(rawValue: "transfer-source")!
        let destinationOrganizationID = OrganizationID(rawValue: "transfer-destination")!
        let credentialRevision = CredentialRevision(rawValue: "transfer-credential")!
        let capabilityRevision = CapabilityRevision(rawValue: "transfer-capability")!
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(
            GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: GitHubNodeID(rawValue: "transfer-account")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: now,
                lastValidatedAt: now
            ),
            credentialRevision: credentialRevision
        )
        for (organizationID, githubID, nodeID, login) in [
            (sourceOrganizationID, 2, "transfer-source-node", "source"),
            (destinationOrganizationID, 3, "transfer-destination-node", "destination")
        ] {
            try await accounts.save(
                GitHubOrganization(
                    id: organizationID,
                    githubOrganizationID: UInt64(githubID),
                    nodeID: GitHubNodeID(rawValue: nodeID)!,
                    login: login
                ),
                access: OrganizationAccess(
                    accountID: accountID,
                    organizationID: organizationID,
                    state: .available,
                    capabilityRevision: capabilityRevision,
                    capabilities: [],
                    checkedAt: now
                ),
                selectedAt: now
            )
        }

        let primaryID = GitHubNodeID(rawValue: "transfer-primary")!
        let nodes = GitHubNodeRepository(vault: vault)
        let workItems = WorkItemRepository(vault: vault)
        let sourcePrimary = node(
            id: primaryID,
            accountID: accountID,
            organizationID: sourceOrganizationID,
            title: "Transferred issue",
            now: now
        )
        try await nodes.save(sourcePrimary)
        let workItemID = try await workItems.ensureWorkItem(for: sourcePrimary)
        let staleContextID = GitHubNodeID(rawValue: "transfer-stale-context")!
        try await nodes.save(node(
            id: staleContextID,
            accountID: accountID,
            organizationID: sourceOrganizationID,
            title: "Former context",
            now: now
        ))
        try await vault.write { database in
            try database.execute(
                sql: "INSERT INTO work_item_members (work_item_id, github_node_id, role) VALUES (?, ?, 'linkedIssue')",
                arguments: [workItemID.rawValue, staleContextID.rawValue]
            )
            try database.execute(
                sql: "INSERT INTO work_item_context_links (work_item_id, github_node_id, relation) VALUES (?, ?, 'crossReferences')",
                arguments: [workItemID.rawValue, staleContextID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO workflow_states (
                        work_item_id, status, pinned, priority, snoozed_until_ms,
                        follow_up_at_ms, local_note, updated_at_ms
                    ) VALUES (?, 'active', 1, 3, NULL, NULL, 'Keep local workflow', 1)
                    """,
                arguments: [workItemID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO work_item_group_memberships (
                        account_id, organization_id, constituent_work_item_id, canonical_work_item_id,
                        credential_revision, capability_revision, source_revision, projected_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                arguments: [
                    accountID.rawValue,
                    sourceOrganizationID.rawValue,
                    workItemID.rawValue,
                    workItemID.rawValue,
                    credentialRevision.rawValue,
                    capabilityRevision.rawValue,
                    String(repeating: "a", count: 64)
                ]
            )
        }

        let destinationPrimary = node(
            id: primaryID,
            accountID: accountID,
            organizationID: destinationOrganizationID,
            title: "Transferred issue",
            now: now.addingTimeInterval(60)
        )
        try await nodes.save(destinationPrimary)
        let transferredID = try await workItems.ensureWorkItem(for: destinationPrimary)
        let sourceItems = try await workItems.fetch(accountID: accountID, organizationID: sourceOrganizationID)
        let destinationItems = try await workItems.fetch(accountID: accountID, organizationID: destinationOrganizationID)
        let transferred = try XCTUnwrap(destinationItems.first)
        let remainingGroups = try await vault.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM work_item_group_memberships
                    WHERE constituent_work_item_id = ? OR canonical_work_item_id = ?
                    """,
                arguments: [workItemID.rawValue, workItemID.rawValue]
            )
        }

        XCTAssertEqual(transferredID, workItemID)
        XCTAssertTrue(sourceItems.isEmpty)
        XCTAssertEqual(transferred.members.map(\.id), [primaryID])
        XCTAssertTrue(transferred.contextLinks.isEmpty)
        XCTAssertTrue(transferred.workflow.isPinned)
        XCTAssertEqual(transferred.workflow.priority, .high)
        XCTAssertEqual(transferred.workflow.localNote, "Keep local workflow")
        XCTAssertEqual(remainingGroups, 0)
    }

    private func node(
        id: GitHubNodeID,
        accountID: AccountID,
        organizationID: OrganizationID,
        title: String,
        now: Date
    ) -> NormalizedGitHubNode {
        NormalizedGitHubNode(
            nodeID: id,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            kind: .issue,
            numericID: "1",
            number: 1,
            title: title,
            state: .open,
            url: URL(string: "https://github.com/octocat/triage/issues/1")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: now,
            updatedAt: now,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "transfer-source-revision",
            observedAt: now,
            accessibility: .accessible
        )
    }
}
