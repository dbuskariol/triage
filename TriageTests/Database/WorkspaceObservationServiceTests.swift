import Foundation
import GRDB
import XCTest
@testable import Triage

final class WorkspaceObservationServiceTests: XCTestCase {
    func testSnapshotIsScopeBoundAndContainsPresentationCoverageCountsAndEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.close() }

        try fixture.seedWorkspace()
        try fixture.seedForeignWorkspace()

        let snapshot = try fixture.pool.read { database in
            try WorkspaceDatabaseObservationService.snapshot(
                in: database,
                scope: fixture.scope,
                selectedWorkItemID: fixture.inboxWorkItemID
            )
        }

        XCTAssertEqual(snapshot.scope, fixture.scope)
        XCTAssertEqual(snapshot.workItems.map { (item: WorkspaceWorkItemPresentation) in item.id }, [
            fixture.inboxWorkItemID,
            fixture.waitingWorkItemID,
            fixture.snoozedWorkItemID
        ])
        XCTAssertEqual(snapshot.menuCounts.inbox, 1)
        XCTAssertEqual(snapshot.menuCounts.myWork, 1)
        XCTAssertEqual(snapshot.menuCounts.reviews, 1)
        XCTAssertEqual(snapshot.menuCounts.waiting, 1)
        XCTAssertEqual(snapshot.menuCounts.snoozed, 1)
        XCTAssertEqual(snapshot.menuCounts.allWork, 3)
        XCTAssertEqual(snapshot.freshness.status, FreshnessStatus.partial)
        XCTAssertFalse(snapshot.isRefreshing)
        XCTAssertEqual(snapshot.selectedItemEvidence?.workItemID, fixture.inboxWorkItemID)
        XCTAssertEqual(
            snapshot.selectedItemEvidence?.evidence.map { (evidence: EvidenceReference) in
                evidence.id.rawValue
            },
            ["local-evidence"]
        )
        let expectedAuthority: EvidenceAuthority = .localWorkflow(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(snapshot.selectedItemEvidence?.evidence.first?.authority, expectedAuthority)
    }

    func testGRDBObservationPublishesOneConsistentPostCommitProjection() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.seedWorkspace()

        let service = WorkspaceDatabaseObservationService(
            bridge: WorkspaceDatabaseObservationService.bridge(
                in: fixture.pool,
                accountID: fixture.accountID
            )
        )
        var iterator = service.values(
            for: fixture.scope,
            selectedWorkItemID: fixture.inboxWorkItemID
        ).makeAsyncIterator()

        let initialValue = try await iterator.next()
        let initial = try XCTUnwrap(initialValue)
        XCTAssertEqual(initial.menuCounts.waiting, 1)
        XCTAssertEqual(initial.menuCounts.inbox, 1)
        XCTAssertEqual(
            initial.selectedItemEvidence?.evidence.map { (evidence: EvidenceReference) in
                evidence.id.rawValue
            },
            ["local-evidence"]
        )

        try await fixture.pool.write { database in
            try database.execute(
                sql: """
                    UPDATE workflow_states
                    SET status = 'active', pinned = 1, updated_at_ms = 2_000
                    WHERE work_item_id = ?
                    """,
                arguments: [fixture.waitingWorkItemID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO action_items (
                        id, work_item_id, title, detail, origin, state, priority,
                        due_at_ms, source_fingerprint, created_at_ms, updated_at_ms,
                        completed_at_ms, dismissed_at_ms
                    ) VALUES ('action-1', ?, 'Follow up', NULL, 'manual', 'open', 2,
                              NULL, NULL, 2_000, 2_000, NULL, NULL)
                    """,
                arguments: [fixture.waitingWorkItemID.rawValue]
            )
        }

        let refreshedValue = try await iterator.next()
        let refreshed = try XCTUnwrap(refreshedValue)
        XCTAssertEqual(refreshed.menuCounts.waiting, 0)
        XCTAssertEqual(refreshed.menuCounts.inbox, 2)
        XCTAssertEqual(
            refreshed.workItems.first(where: { $0.id == fixture.waitingWorkItemID })?.openActionItemCount,
            1
        )
    }

    func testGRDBObservationPublishesCoverageChangeWhenFreshnessIsUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.seedWorkspace()

        let service = WorkspaceDatabaseObservationService(
            bridge: WorkspaceDatabaseObservationService.bridge(
                in: fixture.pool,
                accountID: fixture.accountID
            )
        )
        var iterator = service.values(
            for: fixture.scope,
            selectedWorkItemID: nil
        ).makeAsyncIterator()
        let initialValue = try await iterator.next()
        let initial = try XCTUnwrap(initialValue)
        XCTAssertEqual(initial.freshness.status, FreshnessStatus.partial)

        try await fixture.pool.write { database in
            try database.execute(
                sql: """
                    UPDATE coverage_records
                    SET interval_start_ms = 3_000,
                        interval_end_ms = 4_000
                    WHERE id = 'issues-coverage'
                    """
            )
        }

        let refreshedValue = try await iterator.next()
        let refreshed = try XCTUnwrap(refreshedValue)
        XCTAssertEqual(refreshed.freshness.status, FreshnessStatus.partial)
        XCTAssertNotEqual(
            refreshed.revision.coverageFingerprint,
            initial.revision.coverageFingerprint
        )
    }

    func testTerminationCancelsTheVaultOwnedSubscription() async throws {
        let cancellation = expectation(description: "subscription cancelled")
        let bridge = WorkspaceDatabaseObservationBridge { _, _, _, _ in
            AnyDatabaseCancellable { cancellation.fulfill() }
        }
        let service = WorkspaceDatabaseObservationService(bridge: bridge)
        let scope = SynchronizationScope(
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "organization")!,
            credentialRevision: CredentialRevision(rawValue: "credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability")!
        )

        let task = Task {
            for try await _ in service.values(for: scope, selectedWorkItemID: nil) {
                break
            }
        }
        await Task.yield()
        task.cancel()
        _ = await task.result
        await fulfillment(of: [cancellation], timeout: 1)
    }

    func testBridgeRejectsAnotherAccountBeforeOpeningAnObservation() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let service = WorkspaceDatabaseObservationService(
            bridge: WorkspaceDatabaseObservationService.bridge(
                in: fixture.pool,
                accountID: fixture.accountID
            )
        )
        let foreignScope = SynchronizationScope(
            accountID: AccountID(rawValue: "foreign-account")!,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        var iterator = service.values(
            for: foreignScope,
            selectedWorkItemID: nil
        ).makeAsyncIterator()

        do {
            _ = try await iterator.next()
            XCTFail("Expected the bridge to reject a foreign account scope.")
        } catch {
            XCTAssertEqual(error as? WorkspaceObservationError, .invalidScope)
        }
    }
}

private final class Fixture: @unchecked Sendable {
    let directory: URL
    let pool: DatabasePool
    let accountID = AccountID(rawValue: "account")!
    let organizationID = OrganizationID(rawValue: "organization")!
    let credentialRevision = CredentialRevision(rawValue: "credential")!
    let capabilityRevision = CapabilityRevision(rawValue: "capability")!
    let inboxWorkItemID = WorkItemID(rawValue: "work-inbox")!
    let waitingWorkItemID = WorkItemID(rawValue: "work-waiting")!
    let snoozedWorkItemID = WorkItemID(rawValue: "work-snoozed")!

    var scope: SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pool = try DatabasePool(path: directory.appendingPathComponent("triage.sqlite").path)
        try TriageDatabaseMigrator.migrate(pool, beforeDestructiveMigration: { _ in })
    }

    func close() {
        try? pool.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func seedWorkspace() throws {
        try pool.write { database in
            try seedIdentity(database, accountID: accountID, organizationID: organizationID)
            for (workItemID, nodeID, title, activity) in [
                (inboxWorkItemID, "node-inbox", "Inbox", Int64(3_000)),
                (waitingWorkItemID, "node-waiting", "Waiting", Int64(2_000)),
                (snoozedWorkItemID, "node-snoozed", "Snoozed", Int64(1_000))
            ] {
                try database.execute(
                    sql: """
                        INSERT INTO github_nodes (
                            github_node_id, account_id, organization_id, repository_id,
                            kind, numeric_id, number, title, state, html_url, body_markdown,
                            author_id, created_at_ms, updated_at_ms, closed_at_ms, merged_at_ms,
                            source_revision, last_observed_at_ms, accessibility_state
                        ) VALUES (?, ?, ?, NULL, 'issue', NULL, NULL, ?, 'open', ?, NULL,
                                  NULL, 1, ?, NULL, NULL, 'revision', ?, 'accessible')
                        """,
                    arguments: [
                        nodeID, accountID.rawValue, organizationID.rawValue, title,
                        "https://github.com/octo/triage/issues/1", activity, activity
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO work_items (
                            id, account_id, organization_id, primary_node_id, state,
                            last_relevant_activity_at_ms, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, ?, 'active', ?, ?, ?)
                        """,
                    arguments: [
                        workItemID.rawValue, accountID.rawValue, organizationID.rawValue,
                        nodeID, activity, activity, activity
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO work_item_members (work_item_id, github_node_id, role)
                        VALUES (?, ?, 'primary')
                        """,
                    arguments: [workItemID.rawValue, nodeID]
                )
            }
            try database.execute(
                sql: """
                    INSERT INTO workflow_states (
                        work_item_id, status, pinned, priority, snoozed_until_ms,
                        follow_up_at_ms, local_note, updated_at_ms
                    ) VALUES (?, 'active', 0, 2, NULL, NULL, NULL, 3_000),
                             (?, 'waiting', 0, 2, NULL, NULL, NULL, 2_000),
                             (?, 'active', 0, 2, ?, NULL, NULL, 1_000)
                    """,
                arguments: [
                    inboxWorkItemID.rawValue,
                    waitingWorkItemID.rawValue,
                    snoozedWorkItemID.rawValue,
                    Int64((Date.now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000).rounded())
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO attention_reasons (
                        id, work_item_id, rule_id, rule_version, category, strength,
                        title, explanation, evaluated_at_ms
                    ) VALUES ('reason-1', ?, 'direct', 1, 'directResponsibility', 100,
                              'Assigned', 'Assigned to you.', 3_000)
                    """,
                arguments: [inboxWorkItemID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO relations (
                        id, account_id, subject_node_id, object_node_id, kind, confidence, observed_at_ms
                    ) VALUES ('assigned-1', ?, 'node-inbox', NULL, 'assigned', 'confirmed', 3_000),
                             ('review-1', ?, 'node-inbox', NULL, 'reviewRequestedDirectly', 'confirmed', 3_000)
                    """,
                arguments: [accountID.rawValue, accountID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO relation_evidence (
                        relation_id, evidence_id, source, source_locator_kind, source_locator,
                        authority_kind, authority_account_id, authority_organization_id,
                        authority_feature, authority_stream_id, authority_credential_revision,
                        authority_capability_revision, source_node_id, source_event_id,
                        source_revision, raw_snapshot_id, confidence, confirmation,
                        observed_at_ms, excerpt
                    ) VALUES (
                        'assigned-1', 'local-evidence', 'localWorkflow', 'localWorkflow', 'workflow://assigned',
                        'localWorkflow', ?, ?, NULL, NULL, NULL, NULL, 'node-inbox', NULL,
                        'local', NULL, 'confirmed', 'confirmed', 3_000, 'Assigned locally.'
                    )
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO sync_streams (
                        id, account_id, organization_id, feature, high_water_ms,
                        last_successful_at_ms, last_attempt_at_ms, state, failure_detail
                    ) VALUES ('issues-stream', ?, ?, 'issues', NULL, 3_000, 3_000, 'complete', NULL)
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO coverage_records (
                        id, account_id, organization_id, repository_id, feature, stream_id,
                        interval_start_ms, interval_end_ms, credential_revision, capability_revision,
                        status, last_successful_at_ms, failure_detail
                    ) VALUES ('issues-coverage', ?, ?, NULL, 'issues', 'issues-stream',
                              NULL, NULL, ?, ?, 'complete', 3_000, NULL)
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue,
                    credentialRevision.rawValue, capabilityRevision.rawValue
                ]
            )
        }
    }

    func seedForeignWorkspace() throws {
        let foreignOrganizationID = OrganizationID(rawValue: "foreign-organization")!
        try pool.write { database in
            try seedIdentity(database, accountID: accountID, organizationID: foreignOrganizationID)
            try database.execute(
                sql: """
                    INSERT INTO github_nodes (
                        github_node_id, account_id, organization_id, repository_id, kind, numeric_id,
                        number, title, state, html_url, body_markdown, author_id, created_at_ms,
                        updated_at_ms, closed_at_ms, merged_at_ms, source_revision,
                        last_observed_at_ms, accessibility_state
                    ) VALUES ('node-foreign', ?, ?, NULL, 'issue', NULL, NULL, 'Foreign', 'open',
                              'https://github.com/octo/foreign/issues/1', NULL, NULL, 4_000, 4_000,
                              NULL, NULL, 'revision', 4_000, 'accessible')
                    """,
                arguments: [accountID.rawValue, foreignOrganizationID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO work_items (
                        id, account_id, organization_id, primary_node_id, state,
                        last_relevant_activity_at_ms, created_at_ms, updated_at_ms
                    ) VALUES ('work-foreign', ?, ?, 'node-foreign', 'active', 4_000, 4_000, 4_000)
                    """,
                arguments: [accountID.rawValue, foreignOrganizationID.rawValue]
            )
        }
    }

    private func seedIdentity(
        _ database: Database,
        accountID: AccountID,
        organizationID: OrganizationID
    ) throws {
        let accountCount = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM accounts WHERE id = ?",
            arguments: [accountID.rawValue]
        ) ?? 0
        if accountCount == 0 {
            try database.execute(
                sql: """
                    INSERT INTO accounts (
                        id, github_user_id, github_node_id, login, display_name, avatar_url,
                        authentication_kind, credential_id, credential_status, credential_revision,
                        created_at_ms, last_validated_at_ms, disabled_at_ms
                    ) VALUES (?, '1', 'account-node', 'octocat', NULL, NULL, 'oauth', 'credential-id',
                              'active', ?, 1, 1, NULL)
                    """,
                arguments: [accountID.rawValue, credentialRevision.rawValue]
            )
        }
        try database.execute(
            sql: """
                INSERT INTO organizations (
                    id, github_organization_id, github_node_id, login, display_name, avatar_url, updated_at_ms
                ) VALUES (?, ?, ?, ?, NULL, NULL, 1)
                """,
            arguments: [
                organizationID.rawValue,
                "github-\(organizationID.rawValue)",
                "organization-node-\(organizationID.rawValue)",
                organizationID.rawValue
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO account_organizations (
                    account_id, organization_id, access_state, capability_revision, selected_at_ms, checked_at_ms
                ) VALUES (?, ?, 'available', ?, NULL, 1)
                """,
            arguments: [accountID.rawValue, organizationID.rawValue, capabilityRevision.rawValue]
        )
    }
}
