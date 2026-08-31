import Foundation
import GRDB
import XCTest
@testable import Triage

/// Regression coverage for the workspace-list and bounded-search query shapes.
///
/// These assertions run after all production migrations. They are deliberately
/// tied to migration 044 so a future schema replay cannot silently drop a
/// workspace or derived-input index.
final class WorkspaceQueryPlanRegressionTests: XCTestCase {
    func testMigratedIndexesServeWorkspaceAndBoundedSearchQueryShapes() throws {
        let fixture = try QueryPlanFixture()
        defer { fixture.close() }

        try fixture.seedWorkspaceRows(count: 64)

        try fixture.assertIndexSupportsQuery(
            "workspace_work_items_scope_activity",
            sql: """
                SELECT id
                FROM work_items INDEXED BY workspace_work_items_scope_activity
                WHERE account_id = ? AND organization_id = ?
                ORDER BY last_relevant_activity_at_ms DESC, id
                """,
            arguments: fixture.scopeArguments
        )
        try fixture.assertIndexSupportsQuery(
            "workspace_attention_reasons_order",
            sql: """
                SELECT id, strength
                FROM attention_reasons INDEXED BY workspace_attention_reasons_order
                WHERE work_item_id = ?
                ORDER BY strength DESC, id
                """,
            arguments: [fixture.workItemID(at: 0)]
        )
        try fixture.assertIndexSupportsQuery(
            "workspace_attention_reasons_rule",
            sql: """
                SELECT work_item_id, rule_id
                FROM attention_reasons INDEXED BY workspace_attention_reasons_rule
                WHERE work_item_id = ? AND rule_id IN ('awaitedActorResponded', 'followUpDue')
                """,
            arguments: [fixture.workItemID(at: 0)]
        )
        try fixture.assertIndexSupportsQuery(
            "workspace_relations_subject_kind",
            sql: """
                SELECT subject_node_id, kind
                FROM relations INDEXED BY workspace_relations_subject_kind
                WHERE account_id = ? AND subject_node_id = ?
                  AND kind IN ('assigned', 'authored')
                """,
            arguments: [fixture.accountID, fixture.nodeID(at: 0)]
        )
        try fixture.assertIndexSupportsQuery(
            "workspace_relation_evidence_order",
            sql: """
                SELECT relation_id, observed_at_ms, source, source_locator_kind, source_locator, evidence_id
                FROM relation_evidence INDEXED BY workspace_relation_evidence_order
                WHERE relation_id = ?
                ORDER BY observed_at_ms, source, source_locator_kind, source_locator, evidence_id
                """,
            arguments: ["relation-0"]
        )
        try fixture.assertIndexSupportsQuery(
            "search_comments_parent_updated",
            sql: """
                SELECT github_node_id, updated_at_ms
                FROM comments INDEXED BY search_comments_parent_updated
                WHERE parent_node_id = ?
                ORDER BY updated_at_ms DESC, github_node_id
                LIMIT 32
                """,
            arguments: [fixture.nodeID(at: 0)]
        )
        try fixture.assertIndexSupportsQuery(
            "search_reviews_parent_updated",
            sql: """
                SELECT github_node_id, updated_at_ms
                FROM reviews INDEXED BY search_reviews_parent_updated
                WHERE pull_request_node_id = ?
                ORDER BY updated_at_ms DESC, github_node_id
                LIMIT 32
                """,
            arguments: [fixture.nodeID(at: 0)]
        )
        try fixture.assertIndexSupportsQuery(
            "search_project_items_content_updated",
            sql: """
                SELECT github_node_id, updated_at_ms
                FROM project_items INDEXED BY search_project_items_content_updated
                WHERE content_node_id = ?
                ORDER BY updated_at_ms DESC, github_node_id
                LIMIT 32
                """,
            arguments: [fixture.nodeID(at: 0)]
        )
        try fixture.assertIndexSupportsQuery(
            "sqlite_autoindex_project_field_values_1",
            sql: """
                SELECT project_item_node_id, field_name
                FROM project_field_values INDEXED BY sqlite_autoindex_project_field_values_1
                WHERE project_item_node_id = ?
                ORDER BY field_name
                """,
            arguments: ["project-item-0"]
        )
        try fixture.assertIndexSupportsQuery(
            "search_action_items_work_updated",
            sql: """
                SELECT work_item_id, updated_at_ms, id
                FROM action_items INDEXED BY search_action_items_work_updated
                WHERE work_item_id = ?
                ORDER BY updated_at_ms DESC, id
                LIMIT 32
                """,
            arguments: [fixture.workItemID(at: 0)]
        )
    }

    func testMigratedIndexesServeDerivedInputAdapterQueryShapes() throws {
        let fixture = try QueryPlanFixture()
        defer { fixture.close() }

        try fixture.seedWorkspaceRows(count: 64)

        try fixture.assertIndexSupportsQuery(
            "derived_work_items_scope_id",
            sql: """
                SELECT id, primary_node_id
                FROM work_items INDEXED BY derived_work_items_scope_id
                WHERE account_id = ? AND organization_id = ?
                ORDER BY id
                """,
            arguments: fixture.scopeArguments
        )
        try fixture.assertIndexSupportsQuery(
            "derived_team_memberships_account_state_expiry",
            sql: """
                SELECT team_id
                FROM team_memberships INDEXED BY derived_team_memberships_account_state_expiry
                WHERE account_id = ? AND membership_state = 'active'
                  AND (expires_at_ms IS NULL OR expires_at_ms > ?)
                """,
            arguments: [fixture.accountID, Int64(0)]
        )
        try fixture.assertIndexSupportsQuery(
            "derived_timeline_events_subject_occurred_id",
            sql: """
                SELECT github_event_id, occurred_at_ms
                FROM timeline_events INDEXED BY derived_timeline_events_subject_occurred_id
                WHERE subject_node_id = ?
                ORDER BY occurred_at_ms ASC, github_event_id ASC
                """,
            arguments: [fixture.nodeID(at: 0)]
        )
        try fixture.assertIndexSupportsQuery(
            "derived_review_threads_pull_request_updated",
            sql: """
                SELECT github_node_id, updated_at_ms
                FROM review_threads INDEXED BY derived_review_threads_pull_request_updated
                WHERE pull_request_node_id = ?
                ORDER BY updated_at_ms ASC, github_node_id ASC
                """,
            arguments: [fixture.nodeID(at: 0)]
        )
        try fixture.assertIndexSupportsQuery(
            "derived_project_items_content_node",
            sql: """
                SELECT github_node_id
                FROM project_items INDEXED BY derived_project_items_content_node
                WHERE content_node_id = ?
                ORDER BY github_node_id
                """,
            arguments: [fixture.nodeID(at: 0)]
        )
    }

    /// A generated fan-out fixture for SearchRepository benchmarking. It is
    /// deliberately larger than the `LIMIT 32` child-document budget so a
    /// future SQL change that drops the limit fails deterministically.
    func testLargeVolumeSearchFixtureKeepsChildFanOutBounded() throws {
        let fixture = try QueryPlanFixture()
        defer { fixture.close() }

        try fixture.seedLargeVolumeSearchFixture()

        let itemCount = try fixture.pool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM work_items")
        }
        XCTAssertEqual(itemCount, QueryPlanFixture.largeVolumeWorkItemCount)

        let commentRows = try fixture.boundedChildRows(
            table: "comments",
            parentColumn: "parent_node_id",
            parentID: fixture.nodeID(at: 0)
        )
        let reviewRows = try fixture.boundedChildRows(
            table: "reviews",
            parentColumn: "pull_request_node_id",
            parentID: fixture.nodeID(at: 0)
        )
        XCTAssertEqual(commentRows.count, QueryPlanFixture.searchChildLimit)
        XCTAssertEqual(reviewRows.count, QueryPlanFixture.searchChildLimit)
        XCTAssertLessThanOrEqual(
            commentRows.reduce(0) { $0 + $1.utf8.count },
            QueryPlanFixture.searchChildLimit * QueryPlanFixture.searchChildBodyBytes
        )
        XCTAssertLessThanOrEqual(
            reviewRows.reduce(0) { $0 + $1.utf8.count },
            QueryPlanFixture.searchChildLimit * QueryPlanFixture.searchChildBodyBytes
        )
    }

    func testTenThousandWorkspaceRowsUseTheProductionObservationProjectionWithoutASortScan() throws {
        let fixture = try QueryPlanFixture()
        defer { fixture.close() }
        try fixture.seedWorkspaceRows(count: 10_000)

        // Exercise the real production value-projection path, not a
        // LIMIT-only stand-in. The projection is what feeds the observer
        // before its bounded full-graph decode.
        let snapshot = try fixture.pool.read { database in
            try WorkspaceDatabaseObservationService.snapshot(
                in: database,
                scope: fixture.workspaceScope,
                selectedWorkItemID: nil
            )
        }
        XCTAssertEqual(snapshot.workItems.count, 10_000)
        XCTAssertEqual(snapshot.menuCounts.allWork, 10_000)

        try fixture.assertIndexSupportsQuery(
            "workspace_work_items_scope_activity",
            sql: """
                SELECT
                    work_items.id, work_items.primary_node_id, work_items.state,
                    work_items.last_relevant_activity_at_ms,
                    github_nodes.kind, github_nodes.title, github_nodes.html_url
                FROM work_items
                JOIN github_nodes ON github_nodes.github_node_id = work_items.primary_node_id
                    AND github_nodes.account_id = work_items.account_id
                    AND github_nodes.organization_id = work_items.organization_id
                WHERE work_items.account_id = ? AND work_items.organization_id = ?
                ORDER BY work_items.last_relevant_activity_at_ms DESC, work_items.id
                """,
            arguments: fixture.scopeArguments
        )
    }
}

private final class QueryPlanFixture: @unchecked Sendable {
    static let largeVolumeWorkItemCount = 96
    static let searchChildLimit = 32
    static let searchChildBodyBytes = 4_096

    let directory: URL
    let pool: DatabasePool
    let accountID = "query-plan-account"
    let organizationID = "query-plan-organization"

    var scopeArguments: StatementArguments {
        StatementArguments([accountID, organizationID])
    }

    var workspaceScope: SynchronizationScope {
        SynchronizationScope(
            accountID: AccountID(rawValue: accountID)!,
            organizationID: OrganizationID(rawValue: organizationID)!,
            credentialRevision: CredentialRevision(rawValue: "query-plan-revision")!,
            capabilityRevision: CapabilityRevision(rawValue: "query-plan-capability")!
        )
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pool = try DatabasePool(path: directory.appendingPathComponent("triage.sqlite").path)
        try TriageDatabaseMigrator.migrate(pool, beforeDestructiveMigration: { _ in })
        try pool.write(seedIdentity)
    }

    func close() {
        try? pool.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func workItemID(at index: Int) -> String { "work-item-\(index)" }
    func nodeID(at index: Int) -> String { "node-\(index)" }

    func seedWorkspaceRows(count: Int) throws {
        try pool.write { database in
            for index in 0..<count {
                try insertWorkItem(index: index, into: database)
            }
        }
    }

    func seedLargeVolumeSearchFixture() throws {
        try pool.write { database in
            for index in 0..<Self.largeVolumeWorkItemCount {
                try insertWorkItem(index: index, into: database)
                for childIndex in 0..<(Self.searchChildLimit + 8) {
                    let body = String(repeating: "x", count: Self.searchChildBodyBytes)
                    try insertNode(
                        id: "comment-\(index)-\(childIndex)",
                        kind: "issueComment",
                        title: "Comment \(childIndex)",
                        into: database
                    )
                    try database.execute(
                        sql: """
                            INSERT INTO comments (
                                github_node_id, parent_node_id, author_id, kind, body_markdown,
                                created_at_ms, updated_at_ms, html_url
                            ) VALUES (?, ?, NULL, 'issueComment', ?, ?, ?, ?)
                            """,
                        arguments: [
                            "comment-\(index)-\(childIndex)", nodeID(at: index), body,
                            Int64(childIndex), Int64(childIndex), "https://example.invalid/comment/\(index)-\(childIndex)"
                        ]
                    )
                    try insertNode(
                        id: "review-\(index)-\(childIndex)",
                        kind: "pullRequestReview",
                        title: "Review \(childIndex)",
                        into: database
                    )
                    try database.execute(
                        sql: """
                            INSERT INTO reviews (
                                github_node_id, pull_request_node_id, author_id, state,
                                body_markdown, submitted_at_ms, html_url, updated_at_ms
                            ) VALUES (?, ?, NULL, 'COMMENTED', ?, ?, ?, ?)
                            """,
                        arguments: [
                            "review-\(index)-\(childIndex)", nodeID(at: index), body,
                            Int64(childIndex), "https://example.invalid/review/\(index)-\(childIndex)", Int64(childIndex)
                        ]
                    )
                }
            }
        }
    }

    func boundedChildRows(
        table: String,
        parentColumn: String,
        parentID: String
    ) throws -> [String] {
        precondition(table == "comments" || table == "reviews")
        precondition(parentColumn == "parent_node_id" || parentColumn == "pull_request_node_id")
        return try pool.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT body_markdown
                    FROM \(table)
                    WHERE \(parentColumn) = ?
                    ORDER BY updated_at_ms DESC, github_node_id
                    LIMIT \(Self.searchChildLimit)
                    """,
                arguments: [parentID]
            )
        }
    }

    func assertIndexSupportsQuery(
        _ index: String,
        sql: String,
        arguments: StatementArguments
    ) throws {
        let details = try pool.read { database in
            try Row.fetchAll(
                database,
                sql: "EXPLAIN QUERY PLAN \(sql)",
                arguments: arguments
            ).map { row in row["detail"] as String }
        }
        XCTAssertTrue(
            details.contains { $0.contains(index) },
            "Expected \(index) to serve its query shape, got: \(details.joined(separator: " | "))"
        )
        if sql.contains("ORDER BY") {
            XCTAssertFalse(
                details.contains { $0.contains("USE TEMP B-TREE FOR ORDER BY") },
                "Expected \(index) to satisfy ordering without a temporary sort, got: \(details.joined(separator: " | "))"
            )
        }
        let indexExists = try pool.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?)",
                arguments: [index]
            ) ?? false
        }
        XCTAssertTrue(
            indexExists,
            "Expected migrated index \(index) to exist."
        )
    }

    private func seedIdentity(_ database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO accounts (
                    id, github_user_id, github_node_id, login, display_name, avatar_url,
                    authentication_kind, credential_id, credential_status, credential_revision,
                    created_at_ms, last_validated_at_ms, disabled_at_ms
                ) VALUES (?, '1', 'query-plan-account-node', 'octocat', NULL, NULL,
                          'oauth', 'query-plan-credential', 'active', 'query-plan-revision',
                          1, 1, NULL)
                """,
            arguments: [accountID]
        )
        try database.execute(
            sql: """
                INSERT INTO organizations (
                    id, github_organization_id, github_node_id, login, display_name, avatar_url, updated_at_ms
                ) VALUES (?, '2', 'query-plan-organization-node', 'octo-org', NULL, NULL, 1)
                """,
            arguments: [organizationID]
        )
        try database.execute(
            sql: """
                INSERT INTO account_organizations (
                    account_id, organization_id, access_state, capability_revision, selected_at_ms, checked_at_ms
                ) VALUES (?, ?, 'available', 'query-plan-capability', NULL, 1)
                """,
            arguments: scopeArguments
        )
    }

    private func insertWorkItem(index: Int, into database: Database) throws {
        try insertNode(id: nodeID(at: index), kind: "pullRequest", title: "Work \(index)", into: database)
        try database.execute(
            sql: """
                INSERT INTO pull_requests (
                    github_node_id, is_draft, mergeable_state, head_ref, base_ref,
                    review_decision, unresolved_thread_count, latest_commit_at_ms, updated_at_ms
                ) VALUES (?, 0, NULL, NULL, NULL, NULL, 0, NULL, ?)
                """,
            arguments: [nodeID(at: index), Int64(index)]
        )
        try database.execute(
            sql: """
                INSERT INTO work_items (
                    id, account_id, organization_id, primary_node_id, state,
                    last_relevant_activity_at_ms, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, 'active', ?, ?, ?)
                """,
            arguments: [
                workItemID(at: index), accountID, organizationID, nodeID(at: index),
                Int64(index), Int64(index), Int64(index)
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO attention_reasons (
                    id, work_item_id, rule_id, rule_version, category, strength,
                    title, explanation, evaluated_at_ms
                ) VALUES (?, ?, 'awaitedActorResponded', 1, 'directResponsibility', 10,
                          'Reason', 'Reason', ?)
                """,
            arguments: ["reason-\(index)", workItemID(at: index), Int64(index)]
        )
        try database.execute(
            sql: """
                INSERT INTO action_items (
                    id, work_item_id, title, detail, origin, state, priority,
                    due_at_ms, source_fingerprint, created_at_ms, updated_at_ms,
                    completed_at_ms, dismissed_at_ms
                ) VALUES (?, ?, 'Action', NULL, 'manual', 'open', 2,
                          NULL, NULL, ?, ?, NULL, NULL)
                """,
            arguments: ["action-\(index)", workItemID(at: index), Int64(index), Int64(index)]
        )
        try database.execute(
            sql: """
                INSERT INTO relations (
                    id, account_id, subject_node_id, object_node_id, kind, confidence, observed_at_ms
                ) VALUES (?, ?, ?, NULL, 'assigned', 'provisional', ?)
                """,
            arguments: ["relation-\(index)", accountID, nodeID(at: index), Int64(index)]
        )
    }

    private func insertNode(id: String, kind: String, title: String, into database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO github_nodes (
                    github_node_id, account_id, organization_id, repository_id,
                    kind, numeric_id, number, title, state, html_url, body_markdown,
                    author_id, created_at_ms, updated_at_ms, closed_at_ms, merged_at_ms,
                    source_revision, last_observed_at_ms, accessibility_state
                ) VALUES (?, ?, ?, NULL, ?, NULL, NULL, ?, 'open', ?, NULL,
                          NULL, 1, 1, NULL, NULL, 'query-plan', 1, 'accessible')
                """,
            arguments: [id, accountID, organizationID, kind, title, "https://example.invalid/\(id)"]
        )
    }
}
