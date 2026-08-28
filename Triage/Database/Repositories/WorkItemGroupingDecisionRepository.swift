import Foundation
import GRDB

enum WorkItemGroupingDecisionRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case duplicateDecision
    case invalidDecision
    case nodeScopeMismatch
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
            try Self.validateNodeScopes(
                Set(decisions.flatMap { [$0.sourceNodeID, $0.destinationNodeID] }),
                accountID: accountID,
                in: database
            )
            try database.execute(
                sql: """
                    DELETE FROM grouping_decisions
                    WHERE source_node_id IN (
                        SELECT github_node_id FROM github_nodes WHERE account_id = ?
                    )
                    """,
                arguments: [accountID.rawValue]
            )
            for decision in decisions {
                let evidence = try JSONEncoder().encode(decision.evidence)
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
                        evidence,
                        Self.milliseconds(decision.decidedAt)
                    ]
                )
            }
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

    private func ensureAccountScope(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw WorkItemGroupingDecisionRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func validateNodeScopes(
        _ nodeIDs: Set<GitHubNodeID>,
        accountID: AccountID,
        in database: Database
    ) throws {
        guard !nodeIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: nodeIDs.count).joined(separator: ", ")
        let values = nodeIDs.map(\.rawValue).sorted()
        let matchingCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM github_nodes
                WHERE account_id = ? AND github_node_id IN (\(placeholders))
                """,
            arguments: StatementArguments([accountID.rawValue] + values)
        ) ?? 0
        guard matchingCount == nodeIDs.count else {
            throw WorkItemGroupingDecisionRepositoryError.nodeScopeMismatch
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
