import Foundation
import GRDB
import XCTest

@testable import Triage

final class WorkflowHistoryRepositoryTests: XCTestCase {
    func testGroupedWorkflowUndoSurvivesVaultRelaunch() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkflowHistoryRepository(vault: fixture.vault)

        let transaction = try await repository.apply(
            .archive,
            to: [fixture.firstWorkItemID, fixture.secondWorkItemID],
            in: fixture.scope,
            at: fixture.date.addingTimeInterval(1)
        )
        XCTAssertEqual(transaction.changes.count, 2)
        let archivedStates = try await fixture.states()
        XCTAssertEqual(archivedStates, [.archived, .archived])

        try await fixture.reopen()
        let reopened = WorkflowHistoryRepository(vault: fixture.vault)
        let undone = try await reopened.undoLatest(in: fixture.scope)
        XCTAssertEqual(undone.id, transaction.id)
        let restoredStates = try await fixture.states()
        let history = try await fixture.historySummary()
        XCTAssertEqual(restoredStates, [.active, .active])
        XCTAssertEqual(history.0, 1)
        XCTAssertEqual(history.1, 2)
        XCTAssertEqual(history.2, 2)
    }

    func testInvalidMemberRollsBackEveryWorkflowStateAndHistoryRow() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkflowHistoryRepository(vault: fixture.vault)

        await assertWorkflowHistoryThrows {
            _ = try await repository.apply(
                .archive,
                to: [fixture.firstWorkItemID, WorkItemID(rawValue: "outside-scope")!],
                in: fixture.scope,
                at: fixture.date.addingTimeInterval(1)
            )
        }

        let states = try await fixture.states()
        let history = try await fixture.historySummary()
        XCTAssertEqual(states, [.active, .active])
        XCTAssertEqual(history.0, 0)
        XCTAssertEqual(history.1, 0)
        XCTAssertEqual(history.2, 0)
    }

    func testNewApplyInvalidatesTheDurableRedoBranch() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkflowHistoryRepository(vault: fixture.vault)
        _ = try await repository.apply(.archive, to: [fixture.firstWorkItemID], in: fixture.scope, at: fixture.date)
        _ = try await repository.undoLatest(in: fixture.scope)
        _ = try await repository.apply(.setPinned(true), to: [fixture.firstWorkItemID], in: fixture.scope, at: fixture.date.addingTimeInterval(1))

        await assertWorkflowHistoryThrows {
            _ = try await repository.redoLatest(in: fixture.scope)
        } errorHandler: { error in
            XCTAssertEqual(error as? WorkflowHistoryRepositoryError, .noRedoAvailable)
        }
    }

    func testRedoReplaysOldestTransactionInUndoneSuffixUsingDatabaseOrder() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkflowHistoryRepository(vault: fixture.vault)

        // Deliberately give both entries an identical caller timestamp.  Redo
        // ordering must be driven by SQLite's insertion sequence, never UUID
        // ordering or the millisecond timestamp supplied by the caller.
        let first = try await repository.apply(
            .archive,
            to: [fixture.firstWorkItemID],
            in: fixture.scope,
            at: fixture.date
        )
        let second = try await repository.apply(
            .setPinned(true),
            to: [fixture.firstWorkItemID],
            in: fixture.scope,
            at: fixture.date
        )

        let undoneSecond = try await repository.undoLatest(in: fixture.scope)
        let undoneFirst = try await repository.undoLatest(in: fixture.scope)
        let redoneFirst = try await repository.redoLatest(in: fixture.scope)
        let redoneSecond = try await repository.redoLatest(in: fixture.scope)
        XCTAssertEqual(undoneSecond.id, second.id)
        XCTAssertEqual(undoneFirst.id, first.id)
        XCTAssertEqual(redoneFirst.id, first.id)
        XCTAssertEqual(redoneSecond.id, second.id)
    }

    func testOverflowPrunesWholeOldestGroupsAndRetainsRecentUndoAfterRelaunch() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkflowHistoryRepository(vault: fixture.vault, maximumRetainedTransactionCount: 2)

        let oldest = try await repository.apply(
            .archive,
            to: [fixture.firstWorkItemID, fixture.secondWorkItemID],
            in: fixture.scope,
            at: fixture.date
        )
        let middle = try await repository.apply(
            .setPinned(true),
            to: [fixture.firstWorkItemID],
            in: fixture.scope,
            at: fixture.date
        )
        let newest = try await repository.apply(
            .setPriority(.high),
            to: [fixture.secondWorkItemID],
            in: fixture.scope,
            at: fixture.date
        )

        let retainedRows = try await fixture.historyTransactionRowCounts()
        XCTAssertEqual(
            retainedRows,
            [middle.id: 1, newest.id: 1],
            "The two-row batch must be removed as one complete transaction group."
        )
        XCTAssertFalse(retainedRows.keys.contains(oldest.id))

        try await fixture.reopen()
        let reopened = WorkflowHistoryRepository(vault: fixture.vault, maximumRetainedTransactionCount: 2)
        let undoneNewest = try await reopened.undoLatest(in: fixture.scope)
        let undoneMiddle = try await reopened.undoLatest(in: fixture.scope)
        XCTAssertEqual(undoneNewest.id, newest.id)
        XCTAssertEqual(undoneMiddle.id, middle.id)
        await assertWorkflowHistoryThrows {
            _ = try await reopened.undoLatest(in: fixture.scope)
        } errorHandler: { error in
            XCTAssertEqual(error as? WorkflowHistoryRepositoryError, .noUndoAvailable)
        }
    }

    func testCapturedWindowUndoCannotReverseNewerNotificationTransaction() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkflowHistoryRepository(vault: fixture.vault)
        let windowTransaction = try await repository.apply(
            .archive,
            to: [fixture.firstWorkItemID],
            in: fixture.scope,
            at: fixture.date
        )
        _ = try await repository.apply(
            .setPinned(true),
            to: [fixture.firstWorkItemID],
            in: fixture.scope,
            at: fixture.date
        )

        await assertWorkflowHistoryThrows {
            _ = try await repository.undo(windowTransaction.id, in: fixture.scope)
        } errorHandler: { error in
            XCTAssertEqual(error as? WorkflowHistoryRepositoryError, .staleWorkflowState)
        }
        let states = try await fixture.states()
        XCTAssertEqual(states, [.archived, .active])
    }

    func testCapturedTransactionCanUndoAndRedoWhenItRemainsStackHead() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkflowHistoryRepository(vault: fixture.vault)
        let transaction = try await repository.apply(.archive, to: [fixture.firstWorkItemID], in: fixture.scope, at: fixture.date)

        _ = try await repository.undo(transaction.id, in: fixture.scope)
        let undoneStates = try await fixture.states()
        XCTAssertEqual(undoneStates, [.active, .active])
        _ = try await repository.redo(transaction.id, in: fixture.scope)
        let states = try await fixture.states()
        XCTAssertEqual(states, [.archived, .active])
    }

    private func assertWorkflowHistoryThrows(
        _ operation: () async throws -> Void,
        errorHandler: ((Error) -> Void)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected an error", file: file, line: line)
        } catch {
            errorHandler?(error)
        }
    }
}

private final class Fixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "workflow-history-organization")!
    let firstWorkItemID = WorkItemID(rawValue: "workflow-history-one")!
    let secondWorkItemID = WorkItemID(rawValue: "workflow-history-two")!
    let date = Date(timeIntervalSince1970: 1_000)
    let key: VaultKey
    let registry: VaultRegistry
    private(set) var vault: AccountVault

    var scope: SynchronizationScope {
        .init(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "workflow-history-credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "workflow-history-capability")!
        )
    }

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "triage-workflow-history-\(UUID().uuidString)",
            isDirectory: true
        )
        key = try VaultKey.generate()
        registry = try VaultRegistry(rootDirectory: directory)
        vault = try await registry.open(accountID: accountID, vaultKey: key)
        try await seed()
    }

    func reopen() async throws {
        try await registry.close(accountID: accountID)
        vault = try await registry.open(accountID: accountID, vaultKey: key)
    }

    func states() async throws -> [LocalWorkStatus] {
        try await vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT status FROM workflow_states WHERE work_item_id IN (?, ?) ORDER BY work_item_id",
                arguments: [firstWorkItemID.rawValue, secondWorkItemID.rawValue]
            ).compactMap(LocalWorkStatus.init(rawValue:))
        }
    }

    func historySummary() async throws -> (Int, Int, Int) {
        try await vault.read { database in
            let groups = try Int.fetchOne(database, sql: "SELECT COUNT(DISTINCT transaction_id) FROM workflow_history") ?? 0
            let rows = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM workflow_history") ?? 0
            let undone = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM workflow_history WHERE is_undone = 1") ?? 0
            return (groups, rows, undone)
        }
    }

    func historyTransactionRowCounts() async throws -> [String: Int] {
        try await vault.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT transaction_id, COUNT(*) AS row_count
                    FROM workflow_history
                    WHERE transaction_id IS NOT NULL
                    GROUP BY transaction_id
                    """
            )
            return Dictionary(uniqueKeysWithValues: try rows.map { row in
                guard let transactionID: String = row["transaction_id"],
                      let rowCount: Int = row["row_count"]
                else { throw WorkflowHistoryRepositoryError.invalidPersistedHistory }
                return (transactionID, rowCount)
            })
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private func seed() async throws {
        let accountID = accountID
        let organizationID = organizationID
        let firstWorkItemID = firstWorkItemID
        let secondWorkItemID = secondWorkItemID
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO accounts (id, github_user_id, github_node_id, login, display_name, avatar_url,
                        authentication_kind, credential_id, credential_status, credential_revision, created_at_ms)
                    VALUES (?, '1', 'ACCOUNT_NODE', 'account', NULL, NULL, 'oauth', 'credential', 'active', 'workflow-history-credential', 0)
                    """,
                arguments: [accountID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO organizations (id, github_organization_id, github_node_id, login, display_name, avatar_url, updated_at_ms)
                    VALUES (?, '2', 'ORG_NODE', 'organization', NULL, NULL, 0)
                    """,
                arguments: [organizationID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_organizations (account_id, organization_id, access_state, capability_revision, selected_at_ms, checked_at_ms)
                    VALUES (?, ?, 'available', 'workflow-history-capability', NULL, 0)
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
            for (workItemID, nodeID) in [(firstWorkItemID, "WORKFLOW_HISTORY_NODE_ONE"), (secondWorkItemID, "WORKFLOW_HISTORY_NODE_TWO")] {
                try database.execute(
                    sql: """
                        INSERT INTO github_nodes (github_node_id, account_id, organization_id, repository_id, kind, numeric_id, number,
                            title, state, html_url, body_markdown, author_id, created_at_ms, updated_at_ms, closed_at_ms, merged_at_ms,
                            source_revision, last_observed_at_ms, accessibility_state)
                        VALUES (?, ?, ?, NULL, 'issue', NULL, NULL, 'Work', 'open', 'https://github.com/example/work', NULL, NULL, 0, 0, NULL, NULL, 'source', 0, 'accessible')
                        """,
                    arguments: [nodeID, accountID.rawValue, organizationID.rawValue]
                )
                try database.execute(
                    sql: """
                        INSERT INTO work_items (id, account_id, organization_id, primary_node_id, state, last_relevant_activity_at_ms, created_at_ms, updated_at_ms)
                        VALUES (?, ?, ?, ?, 'active', 0, 0, 0)
                        """,
                    arguments: [workItemID.rawValue, accountID.rawValue, organizationID.rawValue, nodeID]
                )
                try database.execute(
                    sql: """
                        INSERT INTO workflow_states (work_item_id, status, pinned, priority, snoozed_until_ms, follow_up_at_ms, local_note, updated_at_ms)
                        VALUES (?, 'active', 0, 2, NULL, NULL, NULL, 0)
                        """,
                    arguments: [workItemID.rawValue]
                )
            }
        }
    }
}
