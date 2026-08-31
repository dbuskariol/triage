import Foundation
import GRDB

enum WorkItemGroupingDecisionRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case duplicateDecision
    case invalidDecision
    case nodeScopeMismatch
    case evidenceAuthorityMismatch
    case invalidPersistedData
}

actor WorkItemGroupingDecisionRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    /// Replaces the account's complete set of authoritative grouping decisions
    /// so stale decisions cannot affect subsequent grouping calculations.
    func replace(
        _ decisions: [WorkItemGroupingDecision],
        accountID: AccountID
    ) async throws {
        try await replace(decisions, accountID: accountID, organizationID: nil)
    }

    /// Replaces the local decisions in one organization without touching a
    /// different organization in the same encrypted account vault.
    func replace(
        _ decisions: [WorkItemGroupingDecision],
        scope: SynchronizationScope
    ) async throws {
        try await replace(
            decisions,
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
    }

    private func replace(
        _ decisions: [WorkItemGroupingDecision],
        accountID: AccountID,
        organizationID: OrganizationID?
    ) async throws {
        try ensureAccountScope(accountID)
        guard Set(decisions.map {
            "\($0.sourceNodeID.rawValue)\u{0}\($0.destinationNodeID.rawValue)"
        }).count == decisions.count else {
            throw WorkItemGroupingDecisionRepositoryError.duplicateDecision
        }
        guard decisions.allSatisfy({ $0.sourceNodeID != $0.destinationNodeID }) else {
            throw WorkItemGroupingDecisionRepositoryError.invalidDecision
        }

        try await vault.write { database in
            try Self.replace(
                decisions,
                accountID: accountID,
                organizationID: organizationID,
                in: database
            )
        }
    }

    /// Atomically installs a scoped replacement only if the exact scoped state
    /// still belongs to this operation. This fences both initial writes and
    /// compensation so another window's newer local decision is never
    /// overwritten.
    func compareAndReplace(
        _ replacement: [WorkItemGroupingDecision],
        expectedCurrent: [WorkItemGroupingDecision],
        scope: SynchronizationScope
    ) async throws -> Bool {
        try ensureAccountScope(scope.accountID)
        return try await vault.write { database in
            let current = try Self.decisions(for: scope, in: database)
            guard Self.same(current, expectedCurrent) else { return false }
            try Self.replace(
                replacement,
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                in: database
            )
            return true
        }
    }

    func decisions(for accountID: AccountID) async throws -> [WorkItemGroupingDecision] {
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT source_node_id, destination_node_id, relation, strength,
                           evidence_json, decided_at_ms
                    FROM grouping_decisions
                    WHERE source_node_id IN (
                        SELECT github_node_id FROM github_nodes WHERE account_id = ?
                    )
                    ORDER BY source_node_id, destination_node_id
                    """,
                arguments: [accountID.rawValue]
            ).map(Self.decision(from:))
        }
    }

    func decisions(for scope: SynchronizationScope) async throws -> [WorkItemGroupingDecision] {
        try ensureAccountScope(scope.accountID)
        return try await vault.read { database in
            try Self.decisions(for: scope, in: database)
        }
    }

    private func ensureAccountScope(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw WorkItemGroupingDecisionRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func replace(
        _ decisions: [WorkItemGroupingDecision],
        accountID: AccountID,
        organizationID: OrganizationID?,
        in database: Database
    ) throws {
        guard Set(decisions.map { "\($0.sourceNodeID.rawValue)\u{0}\($0.destinationNodeID.rawValue)" }).count == decisions.count else {
            throw WorkItemGroupingDecisionRepositoryError.duplicateDecision
        }
        guard decisions.allSatisfy({ $0.sourceNodeID != $0.destinationNodeID }) else {
            throw WorkItemGroupingDecisionRepositoryError.invalidDecision
        }
        try validateNodeScopes(
            Set(decisions.flatMap { [$0.sourceNodeID, $0.destinationNodeID] }),
            accountID: accountID,
            organizationID: organizationID,
            in: database
        )
        for decision in decisions {
            try validateDecision(decision, accountID: accountID, organizationID: organizationID, in: database)
        }
        if let organizationID {
            try database.execute(
                sql: """
                    DELETE FROM grouping_decisions
                    WHERE source_node_id IN (
                        SELECT github_node_id FROM github_nodes
                        WHERE account_id = ? AND organization_id = ?
                    )
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
        } else {
            try database.execute(
                sql: """
                    DELETE FROM grouping_decisions
                    WHERE source_node_id IN (
                        SELECT github_node_id FROM github_nodes WHERE account_id = ?
                    )
                    """,
                arguments: [accountID.rawValue]
            )
        }
        for decision in decisions {
            try database.execute(
                sql: """
                    INSERT INTO grouping_decisions (
                        source_node_id, destination_node_id, relation, strength,
                        evidence_json, decided_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    decision.sourceNodeID.rawValue,
                    decision.destinationNodeID.rawValue,
                    decision.relation.rawValue,
                    decision.strength.rawValue,
                    try JSONEncoder().encode(decision.evidence),
                    milliseconds(decision.decidedAt)
                ]
            )
        }
    }

    private nonisolated static func decisions(
        for scope: SynchronizationScope,
        in database: Database
    ) throws -> [WorkItemGroupingDecision] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT grouping_decisions.source_node_id, grouping_decisions.destination_node_id,
                       grouping_decisions.relation, grouping_decisions.strength,
                       grouping_decisions.evidence_json, grouping_decisions.decided_at_ms
                FROM grouping_decisions
                JOIN github_nodes AS source ON source.github_node_id = grouping_decisions.source_node_id
                JOIN github_nodes AS destination ON destination.github_node_id = grouping_decisions.destination_node_id
                WHERE source.account_id = ? AND source.organization_id = ?
                  AND destination.account_id = ? AND destination.organization_id = ?
                ORDER BY grouping_decisions.source_node_id, grouping_decisions.destination_node_id
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue
            ]
        ).map(decision(from:))
    }

    private nonisolated static func same(
        _ lhs: [WorkItemGroupingDecision],
        _ rhs: [WorkItemGroupingDecision]
    ) -> Bool {
        lhs.sorted(by: decisionSort) == rhs.sorted(by: decisionSort)
    }

    private nonisolated static func decisionSort(
        _ lhs: WorkItemGroupingDecision,
        _ rhs: WorkItemGroupingDecision
    ) -> Bool {
        "\(lhs.sourceNodeID.rawValue)\u{0}\(lhs.destinationNodeID.rawValue)"
            < "\(rhs.sourceNodeID.rawValue)\u{0}\(rhs.destinationNodeID.rawValue)"
    }

    private nonisolated static func validateNodeScopes(
        _ nodeIDs: Set<GitHubNodeID>,
        accountID: AccountID,
        organizationID: OrganizationID?,
        in database: Database
    ) throws {
        guard !nodeIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: nodeIDs.count).joined(separator: ", ")
        let values = nodeIDs.map(\.rawValue).sorted()
        let organizationClause = organizationID == nil ? "" : " AND organization_id = ?"
        let arguments = [accountID.rawValue]
            + (organizationID.map { [$0.rawValue] } ?? [])
            + values
        let matchingCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM github_nodes
                WHERE account_id = ?\(organizationClause) AND github_node_id IN (\(placeholders))
                """,
            arguments: StatementArguments(arguments)
        ) ?? 0
        guard matchingCount == nodeIDs.count else {
            throw WorkItemGroupingDecisionRepositoryError.nodeScopeMismatch
        }
    }

    /// Grouping decisions are the one manual override in the graph. They are
    /// consequently never allowed to masquerade as a GitHub-derived strong
    /// edge: both endpoint nodes and every proof must be from the same local
    /// workflow scope.
    private nonisolated static func validateDecision(
        _ decision: WorkItemGroupingDecision,
        accountID: AccountID,
        organizationID: OrganizationID?,
        in database: Database
    ) throws {
        guard (decision.strength == .userConfirmed || decision.strength == .userSeparated),
              !decision.evidence.isEmpty,
              Set(decision.evidence.map(\.id)).count == decision.evidence.count
        else {
            throw WorkItemGroupingDecisionRepositoryError.invalidDecision
        }
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT source.organization_id AS source_organization_id,
                       destination.organization_id AS destination_organization_id
                FROM github_nodes AS source
                JOIN github_nodes AS destination
                  ON destination.github_node_id = ?
                WHERE source.github_node_id = ?
                  AND source.account_id = ? AND destination.account_id = ?
                """,
            arguments: [
                decision.destinationNodeID.rawValue,
                decision.sourceNodeID.rawValue,
                accountID.rawValue,
                accountID.rawValue
            ]
        ),
        let sourceOrganizationID = OrganizationID(rawValue: row["source_organization_id"]),
        let destinationOrganizationID = OrganizationID(rawValue: row["destination_organization_id"]),
        sourceOrganizationID == destinationOrganizationID,
        organizationID.map({ $0 == sourceOrganizationID }) ?? true
        else {
            throw WorkItemGroupingDecisionRepositoryError.nodeScopeMismatch
        }
        guard decision.evidence.allSatisfy({ evidence in
            evidence.source == .localWorkflow
                && evidence.locator == .localWorkflow("grouping-decision")
                && evidence.authority == .localWorkflow(
                    accountID: accountID,
                    organizationID: sourceOrganizationID
                )
                && evidence.confidence == .confirmed
                && evidence.confirmation == .confirmed
                && evidence.rawSnapshotID == nil
        }) else {
            throw WorkItemGroupingDecisionRepositoryError.evidenceAuthorityMismatch
        }
    }

    private nonisolated static func decision(from row: Row) throws -> WorkItemGroupingDecision {
        guard let sourceNodeID = GitHubNodeID(rawValue: row["source_node_id"]),
              let destinationNodeID = GitHubNodeID(rawValue: row["destination_node_id"]),
              let relation = WorkRelationKind(rawValue: row["relation"]),
              let strength = GroupingStrength(rawValue: row["strength"]),
              let decidedAtMilliseconds: Int64 = row["decided_at_ms"],
              let evidenceData: Data = row["evidence_json"]
        else {
            throw WorkItemGroupingDecisionRepositoryError.invalidPersistedData
        }
        let evidence: [EvidenceReference]
        do {
            evidence = try JSONDecoder().decode([EvidenceReference].self, from: evidenceData)
        } catch {
            throw WorkItemGroupingDecisionRepositoryError.invalidPersistedData
        }
        return WorkItemGroupingDecision(
            sourceNodeID: sourceNodeID,
            destinationNodeID: destinationNodeID,
            relation: relation,
            strength: strength,
            evidence: evidence,
            decidedAt: Date(timeIntervalSince1970: TimeInterval(decidedAtMilliseconds) / 1_000)
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
