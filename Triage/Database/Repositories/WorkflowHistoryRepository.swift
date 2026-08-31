import Foundation
import GRDB

enum WorkflowHistoryRepositoryError: Error, Equatable, Sendable {
    case scopeMismatch
    case noUndoAvailable
    case noRedoAvailable
    case staleWorkflowState
    case invalidPersistedHistory
}

struct WorkflowHistoryTransaction: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        let workItemID: WorkItemID
        let previous: WorkflowState
        let next: WorkflowState
    }

    let id: String
    let accountID: AccountID
    let organizationID: OrganizationID
    let changes: [Change]
}

/// Encrypted-vault history for reversible, strictly local workflow changes.
/// The workflow-state writes and their one grouped undo record share one
/// database transaction, so an invalid member rolls every member back.
actor WorkflowHistoryRepository {
    /// Retain the most recent local workflow transactions per encrypted
    /// account/organization scope. A transaction may contain many work items,
    /// so pruning always deletes complete transaction groups.
    static let maximumRetainedTransactionCount = 100

    private let vault: AccountVault
    private let maximumRetainedTransactionCount: Int

    init(vault: AccountVault) {
        self.vault = vault
        maximumRetainedTransactionCount = WorkflowHistoryRepository.maximumRetainedTransactionCount
    }

    init(vault: AccountVault, maximumRetainedTransactionCount: Int) {
        precondition(maximumRetainedTransactionCount > 0)
        self.vault = vault
        self.maximumRetainedTransactionCount = maximumRetainedTransactionCount
    }

    func apply(
        _ action: WorkflowAction,
        to workItemIDs: [WorkItemID],
        in scope: SynchronizationScope,
        at date: Date = .now
    ) async throws -> WorkflowHistoryTransaction {
        try validate(scope)
        try Task.checkCancellation()
        let uniqueIDs = Array(Set(workItemIDs)).sorted { $0.rawValue < $1.rawValue }
        guard !uniqueIDs.isEmpty else { throw WorkflowHistoryRepositoryError.scopeMismatch }
        let transactionID = UUID().uuidString.lowercased()
        let createdAt = Self.milliseconds(date)
        let retentionLimit = maximumRetainedTransactionCount
        return try await vault.writeTransaction { database in
            try Task.checkCancellation()
            // A new local edit starts a fresh branch. Never allow an old
            // UndoManager redo to replay a pre-branch history transaction.
            try database.execute(
                sql: "UPDATE workflow_history SET is_undone = 2 WHERE account_id = ? AND organization_id = ? AND is_undone = 1",
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
            )
            var changes = [WorkflowHistoryTransaction.Change]()
            for workItemID in uniqueIDs {
                try Self.validateScope(workItemID, in: scope, database: database)
                let previous = try Self.state(for: workItemID, database: database)
                let next = WorkflowTransitionEngine.apply(action, to: previous, at: date).next
                try Self.save(next, for: workItemID, database: database)
                let priorJSON = try JSONEncoder().encode(previous)
                let nextJSON = try JSONEncoder().encode(next)
                try database.execute(
                    sql: """
                        INSERT INTO workflow_history (
                            id, work_item_id, action_item_id, kind, prior_state_json,
                            next_state_json, created_at_ms, transaction_id, account_id,
                            organization_id, is_undone
                        ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, 0)
                        """,
                    arguments: [
                        UUID().uuidString.lowercased(), workItemID.rawValue,
                        Self.kind(for: action), priorJSON, nextJSON, createdAt,
                        transactionID, scope.accountID.rawValue, scope.organizationID.rawValue,
                    ]
                )
                changes.append(.init(workItemID: workItemID, previous: previous, next: next))
            }
            try Self.pruneOldestTransactionGroups(
                retaining: retentionLimit,
                in: scope,
                database: database
            )
            try Task.checkCancellation()
            return .init(
                id: transactionID,
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                changes: changes
            )
        }
    }

    func undoLatest(in scope: SynchronizationScope) async throws -> WorkflowHistoryTransaction {
        try await restoreLatest(in: scope, isUndone: false, restoringNext: false, expectedTransactionID: nil)
    }

    func redoLatest(in scope: SynchronizationScope) async throws -> WorkflowHistoryTransaction {
        try await restoreLatest(in: scope, isUndone: true, restoringNext: true, expectedTransactionID: nil)
    }

    func undo(_ transactionID: String, in scope: SynchronizationScope) async throws -> WorkflowHistoryTransaction {
        try await restoreLatest(in: scope, isUndone: false, restoringNext: false, expectedTransactionID: transactionID)
    }

    func redo(_ transactionID: String, in scope: SynchronizationScope) async throws -> WorkflowHistoryTransaction {
        try await restoreLatest(in: scope, isUndone: true, restoringNext: true, expectedTransactionID: transactionID)
    }

    private func restoreLatest(
        in scope: SynchronizationScope,
        isUndone: Bool,
        restoringNext: Bool,
        expectedTransactionID: String?
    ) async throws -> WorkflowHistoryTransaction {
        try validate(scope)
        try Task.checkCancellation()
        // `rowid` is assigned by SQLite inside the enclosing write transaction,
        // and is the only ordering authority for the durable undo stack.  The
        // caller-supplied timestamp and random transaction ID are retained as
        // history data, but must never decide stack head ordering.
        let stackOrdering = isUndone ? "ASC" : "DESC"
        let retentionLimit = maximumRetainedTransactionCount
        return try await vault.writeTransaction { database in
            try Task.checkCancellation()
            guard let transactionID = try String.fetchOne(
                database,
                sql: """
                    SELECT transaction_id FROM workflow_history
                    WHERE account_id = ? AND organization_id = ?
                      AND is_undone = ? AND transaction_id IS NOT NULL
                    GROUP BY transaction_id
                    ORDER BY MIN(rowid) \(stackOrdering)
                    LIMIT 1
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, isUndone]
            ) else {
                throw isUndone ? WorkflowHistoryRepositoryError.noRedoAvailable : .noUndoAvailable
            }
            if let expectedTransactionID, transactionID != expectedTransactionID {
                throw WorkflowHistoryRepositoryError.staleWorkflowState
            }
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT work_item_id, prior_state_json, next_state_json
                    FROM workflow_history
                    WHERE transaction_id = ? AND account_id = ? AND organization_id = ?
                    ORDER BY id ASC
                    """,
                arguments: [transactionID, scope.accountID.rawValue, scope.organizationID.rawValue]
            )
            guard !rows.isEmpty else { throw WorkflowHistoryRepositoryError.invalidPersistedHistory }
            var changes = [WorkflowHistoryTransaction.Change]()
            for row in rows {
                guard let rawID: String = row["work_item_id"],
                      let workItemID = WorkItemID(rawValue: rawID),
                      let priorData: Data = row["prior_state_json"],
                      let nextData: Data = row["next_state_json"]
                else { throw WorkflowHistoryRepositoryError.invalidPersistedHistory }
                let previous: WorkflowState
                let next: WorkflowState
                do {
                    previous = try JSONDecoder().decode(WorkflowState.self, from: priorData)
                    next = try JSONDecoder().decode(WorkflowState.self, from: nextData)
                } catch {
                    throw WorkflowHistoryRepositoryError.invalidPersistedHistory
                }
                try Self.validateScope(workItemID, in: scope, database: database)
                let current = try Self.state(for: workItemID, database: database)
                let expected = restoringNext ? previous : next
                guard Self.hasSamePersistentState(current, expected) else {
                    throw WorkflowHistoryRepositoryError.staleWorkflowState
                }
                changes.append(.init(workItemID: workItemID, previous: previous, next: next))
            }
            for change in changes {
                try Self.save(restoringNext ? change.next : change.previous, for: change.workItemID, database: database)
            }
            try database.execute(
                sql: "UPDATE workflow_history SET is_undone = ? WHERE transaction_id = ? AND account_id = ? AND organization_id = ?",
                arguments: [restoringNext ? 0 : 1, transactionID, scope.accountID.rawValue, scope.organizationID.rawValue]
            )
            try Self.pruneOldestTransactionGroups(
                retaining: retentionLimit,
                in: scope,
                database: database
            )
            try Task.checkCancellation()
            return .init(id: transactionID, accountID: scope.accountID, organizationID: scope.organizationID, changes: changes)
        }
    }

    private func validate(_ scope: SynchronizationScope) throws {
        guard scope.accountID == vault.accountID else { throw WorkflowHistoryRepositoryError.scopeMismatch }
    }

    private nonisolated static func validateScope(
        _ workItemID: WorkItemID,
        in scope: SynchronizationScope,
        database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM work_items WHERE id = ? AND account_id = ? AND organization_id = ?",
            arguments: [workItemID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue]
        ) ?? 0
        guard count == 1 else { throw WorkflowHistoryRepositoryError.scopeMismatch }
    }

    /// Database row IDs are assigned within the vault write transaction.  Keep
    /// the newest complete durable groups and remove older groups in the same
    /// transaction as the successful history write, so history never exposes
    /// a partially pruned batch after relaunch.
    private nonisolated static func pruneOldestTransactionGroups(
        retaining limit: Int,
        in scope: SynchronizationScope,
        database: Database
    ) throws {
        try database.execute(
            sql: """
                DELETE FROM workflow_history
                WHERE account_id = ? AND organization_id = ?
                  AND transaction_id IN (
                    SELECT transaction_id
                    FROM (
                        SELECT transaction_id
                        FROM workflow_history
                        WHERE account_id = ? AND organization_id = ?
                          AND transaction_id IS NOT NULL
                        GROUP BY transaction_id
                        ORDER BY MIN(rowid) DESC
                        LIMIT -1 OFFSET ?
                    )
                  )
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                limit,
            ]
        )
    }

    private nonisolated static func state(for workItemID: WorkItemID, database: Database) throws -> WorkflowState {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT status, pinned, priority, snoozed_until_ms, follow_up_at_ms, local_note, updated_at_ms
                FROM workflow_states WHERE work_item_id = ?
                """,
            arguments: [workItemID.rawValue]
        ), let statusRaw: String = row["status"], let status = LocalWorkStatus(rawValue: statusRaw),
              let priorityRaw: Int = row["priority"], let priority = WorkPriority(rawValue: priorityRaw),
              let updatedAt: Int64 = row["updated_at_ms"]
        else { throw WorkflowHistoryRepositoryError.invalidPersistedHistory }
        let snoozedAt: Int64? = row["snoozed_until_ms"]
        let followUpAt: Int64? = row["follow_up_at_ms"]
        let note: String? = row["local_note"]
        let pinned: Bool = row["pinned"]
        return .init(
            status: status,
            isPinned: pinned,
            priority: priority,
            snoozedUntil: snoozedAt.map(Self.date),
            followUpAt: followUpAt.map(Self.date),
            localNote: note,
            updatedAt: Self.date(updatedAt)
        )
    }

    private nonisolated static func save(_ state: WorkflowState, for workItemID: WorkItemID, database: Database) throws {
        try database.execute(
            sql: """
                UPDATE workflow_states
                SET status = ?, pinned = ?, priority = ?, snoozed_until_ms = ?, follow_up_at_ms = ?,
                    local_note = ?, updated_at_ms = ?
                WHERE work_item_id = ?
                """,
            arguments: [
                state.status.rawValue, state.isPinned, state.priority.rawValue,
                state.snoozedUntil.map(Self.milliseconds), state.followUpAt.map(Self.milliseconds),
                state.localNote, Self.milliseconds(state.updatedAt), workItemID.rawValue,
            ]
        )
    }

    private nonisolated static func kind(for action: WorkflowAction) -> String {
        switch action {
        case .archive: "archive"
        case .unarchive: "unarchive"
        case .setPinned: "set_pinned"
        case .setPriority: "set_priority"
        case .snooze: "snooze"
        case .clearSnooze: "clear_snooze"
        case .markWaiting: "mark_waiting"
        case .clearWaiting: "clear_waiting"
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private nonisolated static func hasSamePersistentState(_ lhs: WorkflowState, _ rhs: WorkflowState) -> Bool {
        lhs.status == rhs.status && lhs.isPinned == rhs.isPinned && lhs.priority == rhs.priority
            && lhs.snoozedUntil == rhs.snoozedUntil && lhs.followUpAt == rhs.followUpAt
            && lhs.localNote == rhs.localNote
    }
}
