import CryptoKit
import Foundation
import GRDB

enum WorkRelationRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case subjectScopeMismatch
    case subjectNodeScopeMismatch
    case duplicateRelation
    case duplicateEvidence
}

actor WorkRelationRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    /// Replaces all relations observed for one source node so removed GitHub
    /// relationships and evidence cannot survive a later synchronization.
    func replace(
        _ relations: [WorkRelation],
        accountID: AccountID,
        subjectNodeID: GitHubNodeID
    ) async throws {
        guard accountID == vault.accountID else {
            throw WorkRelationRepositoryError.accountScopeMismatch
        }
        try await vault.write { database in
            try Self.replace(
                relations,
                accountID: accountID,
                subjectNodeID: subjectNodeID,
                in: database
            )
        }
    }

    nonisolated static func replace(
        _ relations: [WorkRelation],
        accountID: AccountID,
        subjectNodeID: GitHubNodeID,
        in database: Database
    ) throws {
        try validate(relations, subjectNodeID: subjectNodeID)
        try validateSubjectNodeScope(subjectNodeID, accountID: accountID, in: database)
        try database.execute(
                sql: """
                    DELETE FROM relations
                    WHERE account_id = ? AND subject_node_id = ?
                    """,
                arguments: [accountID.rawValue, subjectNodeID.rawValue]
        )

        for relation in relations {
                    let relationID = identifier(
                    accountID: accountID,
                    relation: relation
                )
                try database.execute(
                    sql: """
                        INSERT INTO relations (
                            id, account_id, subject_node_id, object_node_id, kind,
                            confidence, observed_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        relationID,
                        accountID.rawValue,
                        relation.subjectNodeID.rawValue,
                        relation.objectNodeID?.rawValue,
                        relation.kind.rawValue,
                        relation.confidence.rawValue,
                        milliseconds(relation.observedAt)
                    ]
                )
                for evidence in relation.evidence {
                    try database.execute(
                        sql: """
                            INSERT INTO relation_evidence (
                                relation_id, evidence_id, source, source_node_id,
                                source_event_id, source_revision, observed_at_ms, excerpt
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            relationID,
                            evidence.id.rawValue,
                            evidence.source.rawValue,
                            evidence.nodeID?.rawValue,
                            evidence.eventID?.rawValue,
                            evidence.sourceRevision,
                            milliseconds(evidence.observedAt),
                            evidence.excerpt
                        ]
                    )
                }
        }
    }

    private nonisolated static func validate(
        _ relations: [WorkRelation],
        subjectNodeID: GitHubNodeID
    ) throws {
        guard Set(relations.map(\.subjectNodeID)).isSubset(of: [subjectNodeID]) else {
            throw WorkRelationRepositoryError.subjectScopeMismatch
        }
        let relationKeys = relations.map(canonicalKey)
        guard Set(relationKeys).count == relationKeys.count else {
            throw WorkRelationRepositoryError.duplicateRelation
        }
        guard relations.allSatisfy({
            Set($0.evidence.map(\.id)).count == $0.evidence.count
        }) else {
            throw WorkRelationRepositoryError.duplicateEvidence
        }
    }

    private nonisolated static func canonicalKey(_ relation: WorkRelation) -> String {
        [
            relation.subjectNodeID.rawValue,
            relation.objectNodeID?.rawValue ?? "",
            relation.kind.rawValue
        ].joined(separator: "\u{0}")
    }

    private nonisolated static func validateSubjectNodeScope(
        _ subjectNodeID: GitHubNodeID,
        accountID: AccountID,
        in database: Database
    ) throws {
        let matchingCount = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM github_nodes WHERE github_node_id = ? AND account_id = ?",
            arguments: [subjectNodeID.rawValue, accountID.rawValue]
        ) ?? 0
        guard matchingCount == 1 else {
            throw WorkRelationRepositoryError.subjectNodeScopeMismatch
        }
    }

    private nonisolated static func identifier(
        accountID: AccountID,
        relation: WorkRelation
    ) -> String {
        let canonicalValue = "\(accountID.rawValue)\u{0}\(canonicalKey(relation))"
        return SHA256.hash(data: Data(canonicalValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
