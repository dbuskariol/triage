import Foundation
import GRDB

enum WorkItemGroupingMutation: Equatable, Sendable {
    case confirmMerge(
        sourceNodeID: GitHubNodeID,
        destinationNodeID: GitHubNodeID,
        relation: WorkRelationKind
    )
    case keepSeparate(
        sourceNodeID: GitHubNodeID,
        destinationNodeID: GitHubNodeID,
        relation: WorkRelationKind
    )

    var sourceNodeID: GitHubNodeID {
        switch self {
        case let .confirmMerge(sourceNodeID, _, _), let .keepSeparate(sourceNodeID, _, _):
            sourceNodeID
        }
    }

    var destinationNodeID: GitHubNodeID {
        switch self {
        case let .confirmMerge(_, destinationNodeID, _), let .keepSeparate(_, destinationNodeID, _):
            destinationNodeID
        }
    }

    var relation: WorkRelationKind {
        switch self {
        case let .confirmMerge(_, _, relation), let .keepSeparate(_, _, relation): relation
        }
    }

    var strength: GroupingStrength {
        switch self {
        case .confirmMerge: .userConfirmed
        case .keepSeparate: .userSeparated
        }
    }
}

struct WorkItemGroupingMutationHistory: Equatable, Sendable {
    let before: [WorkItemGroupingDecision]
    let after: [WorkItemGroupingDecision]
}

enum WorkItemGroupingDecisionServiceError: Error, Equatable, Sendable {
    case invalidPair
    case actionOwnershipUnavailable
    case staleGroupingState
    case staleRollbackPreserved
    case rollbackFailed
}

/// The only mutation boundary for manual grouping. It writes local evidence to
/// the encrypted vault, then immediately rebuilds the exact scoped projection;
/// it never creates or changes GitHub content.
actor WorkItemGroupingDecisionService {
    private let vault: AccountVault
    private let project: @Sendable (SynchronizationScope, Date) async throws -> Void
    private let rebuildSearch: @Sendable (SynchronizationScope) async throws -> Void
    /// Test-only synchronization seam for exercising a second window changing
    /// the scoped decision set after this operation has computed its proposed
    /// state but before the atomic installation begins.
    private let beforeInitialInstallation: @Sendable (SynchronizationScope) async -> Void

    init(
        vault: AccountVault,
        project: (@Sendable (SynchronizationScope, Date) async throws -> Void)? = nil,
        rebuildSearch: (@Sendable (SynchronizationScope) async throws -> Void)? = nil,
        beforeInitialInstallation: (@Sendable (SynchronizationScope) async -> Void)? = nil
    ) {
        self.vault = vault
        self.project = project ?? { scope, date in
            try await OrganizationWorkItemGraphProjectionService(vault: vault)
                .projectAfterNormalizedCommit(for: scope, at: date)
        }
        self.rebuildSearch = rebuildSearch ?? { scope in
            try await SearchRepository(vault: vault).rebuild(
                accountID: scope.accountID,
                organizationID: scope.organizationID
            )
        }
        self.beforeInitialInstallation = beforeInitialInstallation ?? { _ in }
    }

    func apply(
        _ mutation: WorkItemGroupingMutation,
        scope: SynchronizationScope,
        at date: Date = .now
    ) async throws -> WorkItemGroupingMutationHistory {
        guard mutation.sourceNodeID != mutation.destinationNodeID else {
            throw WorkItemGroupingDecisionServiceError.invalidPair
        }
        let repository = WorkItemGroupingDecisionRepository(vault: vault)
        let before = try await repository.decisions(for: scope)
        let after = before.filter {
            !Self.matchesPair($0, mutation.sourceNodeID, mutation.destinationNodeID)
        } + [Self.decision(for: mutation, scope: scope, at: date)]
        try await commit(
            after,
            expectedCurrent: before,
            scope: scope,
            at: date
        )
        // This history belongs to this installation, not a later write from a
        // second window. Reading the current vault state here could otherwise
        // make this window's Undo fence a newer operation as its own.
        return WorkItemGroupingMutationHistory(
            before: before.sorted(by: Self.sort),
            after: after.sorted(by: Self.sort)
        )
    }

    /// Restores exactly the decision set that preceded a local edit. The
    /// expected set prevents Undo from overwriting a newer decision made in a
    /// different window.
    func restore(
        _ before: [WorkItemGroupingDecision],
        expectedCurrent: [WorkItemGroupingDecision],
        scope: SynchronizationScope,
        at date: Date = .now
    ) async throws {
        try await commit(
            before,
            expectedCurrent: expectedCurrent,
            scope: scope,
            at: date
        )
    }

    /// Commits a grouping decision only with its derived graph/index. The
    /// repositories have independent transactions, so a failed projection or
    /// cancellation is compensated before this method returns. Rollback runs
    /// in a fresh task because cancellation must not strand a new decision
    /// beside the old visible graph.
    private func commit(
        _ decisions: [WorkItemGroupingDecision],
        expectedCurrent: [WorkItemGroupingDecision],
        scope: SynchronizationScope,
        at date: Date
    ) async throws {
        let repository = WorkItemGroupingDecisionRepository(vault: vault)
        let applied = decisions
        var didApply = false
        do {
            await beforeInitialInstallation(scope)
            let installed = try await repository.compareAndReplace(
                decisions,
                expectedCurrent: expectedCurrent,
                scope: scope
            )
            guard installed else {
                try await Self.rebuildProjectionAndSearch(vault: vault, scope: scope, date: date)
                throw WorkItemGroupingDecisionServiceError.staleRollbackPreserved
            }
            didApply = true
            try Task.checkCancellation()
            try await project(scope, date)
            try Task.checkCancellation()
            try await rebuildSearch(scope)
        } catch {
            let originalError = error
            guard didApply else { throw originalError }
            do {
                let restored = try await repository.compareAndReplace(
                    expectedCurrent,
                    expectedCurrent: applied,
                    scope: scope
                )
                if restored {
                    try await Self.rebuildProjectionAndSearch(vault: vault, scope: scope, date: date)
                } else {
                    try await Self.rebuildProjectionAndSearch(vault: vault, scope: scope, date: date)
                    throw WorkItemGroupingDecisionServiceError.staleRollbackPreserved
                }
            } catch {
                if let serviceError = error as? WorkItemGroupingDecisionServiceError,
                   serviceError == .staleRollbackPreserved {
                    throw serviceError
                }
                throw WorkItemGroupingDecisionServiceError.rollbackFailed
            }
            throw originalError
        }
    }

    private nonisolated static func rebuildProjectionAndSearch(
        vault: AccountVault,
        scope: SynchronizationScope,
        date: Date
    ) async throws {
        try await Task.detached(priority: nil) {
            try await OrganizationWorkItemGraphProjectionService(vault: vault)
                .projectAfterNormalizedCommit(for: scope, at: date)
            try await SearchRepository(vault: vault).rebuild(
                accountID: scope.accountID,
                organizationID: scope.organizationID
            )
        }.value
    }

    /// Assigns one already-local action item to a constituent before a manual
    /// split. Both the current canonical group and the destination work item
    /// are revalidated in the transaction, so an old inspector cannot move an
    /// action across an account or organization boundary.
    func assignActionItem(
        _ actionItemID: ActionItemID,
        expectedOwnerWorkItemID: WorkItemID,
        visibleWorkItemID: WorkItemID,
        destinationNodeID: GitHubNodeID,
        scope: SynchronizationScope,
        at date: Date = .now
    ) async throws {
        try await vault.write { database in
            let target = try Row.fetchOne(
                database,
                sql: """
                    SELECT id FROM work_items
                    WHERE account_id = ? AND organization_id = ? AND primary_node_id = ?
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, destinationNodeID.rawValue]
            )
            guard let targetID: String = target?["id"],
                  let destinationWorkItemID = WorkItemID(rawValue: targetID)
            else { throw WorkItemGroupingDecisionServiceError.actionOwnershipUnavailable }

            let canonicalOwner = try String.fetchOne(
                database,
                sql: """
                    SELECT COALESCE(membership.canonical_work_item_id, work_items.id)
                    FROM work_items
                    LEFT JOIN work_item_group_memberships AS membership
                      ON membership.constituent_work_item_id = work_items.id
                     AND membership.account_id = work_items.account_id
                     AND membership.organization_id = work_items.organization_id
                    WHERE work_items.id = ? AND work_items.account_id = ? AND work_items.organization_id = ?
                    """,
                arguments: [expectedOwnerWorkItemID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue]
            )
            let canonicalDestination = try String.fetchOne(
                database,
                sql: """
                    SELECT COALESCE(membership.canonical_work_item_id, work_items.id)
                    FROM work_items
                    LEFT JOIN work_item_group_memberships AS membership
                      ON membership.constituent_work_item_id = work_items.id
                     AND membership.account_id = work_items.account_id
                     AND membership.organization_id = work_items.organization_id
                    WHERE work_items.id = ? AND work_items.account_id = ? AND work_items.organization_id = ?
                    """,
                arguments: [destinationWorkItemID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue]
            )
            guard canonicalOwner == visibleWorkItemID.rawValue,
                  canonicalDestination == visibleWorkItemID.rawValue
            else { throw WorkItemGroupingDecisionServiceError.actionOwnershipUnavailable }
            try database.execute(
                sql: """
                    UPDATE action_items
                    SET work_item_id = ?, updated_at_ms = ?
                    WHERE id = ? AND work_item_id = ?
                    """,
                arguments: [
                    destinationWorkItemID.rawValue,
                    Int64((date.timeIntervalSince1970 * 1_000).rounded()),
                    actionItemID.rawValue,
                    expectedOwnerWorkItemID.rawValue
                ]
            )
            guard database.changesCount == 1 else {
                throw WorkItemGroupingDecisionServiceError.actionOwnershipUnavailable
            }
        }
        try await SearchRepository(vault: vault).rebuild(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
    }

    private nonisolated static func decision(
        for mutation: WorkItemGroupingMutation,
        scope: SynchronizationScope,
        at date: Date
    ) -> WorkItemGroupingDecision {
        WorkItemGroupingDecision(
            sourceNodeID: mutation.sourceNodeID,
            destinationNodeID: mutation.destinationNodeID,
            relation: mutation.relation,
            strength: mutation.strength,
            evidence: [EvidenceReference(
                id: EvidenceID(rawValue: "grouping-decision-\(UUID().uuidString.lowercased())")!,
                source: .localWorkflow,
                locator: .localWorkflow("grouping-decision"),
                authority: .localWorkflow(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID
                ),
                nodeID: mutation.sourceNodeID,
                confidence: .confirmed,
                confirmation: .confirmed,
                observedAt: date,
                excerpt: nil
            )],
            decidedAt: date
        )
    }

    private nonisolated static func matchesPair(
        _ decision: WorkItemGroupingDecision,
        _ sourceNodeID: GitHubNodeID,
        _ destinationNodeID: GitHubNodeID
    ) -> Bool {
        (decision.sourceNodeID == sourceNodeID && decision.destinationNodeID == destinationNodeID)
            || (decision.sourceNodeID == destinationNodeID && decision.destinationNodeID == sourceNodeID)
    }

    private nonisolated static func sort(
        _ lhs: WorkItemGroupingDecision,
        _ rhs: WorkItemGroupingDecision
    ) -> Bool {
        let left = "\(lhs.sourceNodeID.rawValue)\u{0}\(lhs.destinationNodeID.rawValue)"
        let right = "\(rhs.sourceNodeID.rawValue)\u{0}\(rhs.destinationNodeID.rawValue)"
        return left < right
    }
}
