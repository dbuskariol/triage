import CryptoKit
import Foundation
import GRDB

enum RelationReplacementMode: String, Codable, Sendable {
    case incremental
    case completeReconciliation
}

/// The single source whose evidence may be replaced. It deliberately includes
/// source revision, so a newer response cannot erase another revision.
struct RelationReplacementAuthority: Equatable, Sendable {
    let source: EvidenceSource
    let locator: EvidenceLocator
    let scope: SynchronizationScope
    let feature: CoverageFeature
    let streamID: SyncStreamID
    let repositoryID: RepositoryID?
    let sourceRevision: String
    let rawSnapshotID: RawAPISnapshotID?
    let observedAt: Date
    let mode: RelationReplacementMode
}

/// One exact raw page contributing to a stream-complete reconciliation. The
/// page may have no eligible relations; it is still required so an empty page
/// can safely remove its former evidence.
struct PageBoundRelationReplacement: Sendable {
    let relations: [WorkRelation]
    let authority: RelationReplacementAuthority
}

enum WorkRelationRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case subjectScopeMismatch
    case subjectNodeScopeMismatch
    case objectNodeScopeMismatch
    case duplicateRelation
    case duplicateEvidence
    case missingEvidence
    case evidenceAuthorityMismatch
    case invalidSourceAuthority
    case staleSynchronizationScope
    case incompleteCoverage
    case missingRawSnapshot
    case rawSnapshotScopeMismatch
}

actor WorkRelationRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    /// Incremental input is additive. Only a completed reconciliation of this
    /// exact source, locator, scope, and revision can remove its own evidence.
    func replace(
        _ relations: [WorkRelation],
        accountID: AccountID,
        subjectNodeID: GitHubNodeID,
        authority: RelationReplacementAuthority
    ) async throws {
        guard accountID == vault.accountID else {
            throw WorkRelationRepositoryError.accountScopeMismatch
        }
        try await vault.write { database in
            try Self.replace(
                relations,
                accountID: accountID,
                subjectNodeID: subjectNodeID,
                authority: authority,
                in: database
            )
        }
    }

    nonisolated static func replace(
        _ relations: [WorkRelation],
        accountID: AccountID,
        subjectNodeID: GitHubNodeID,
        authority: RelationReplacementAuthority,
        in database: Database
    ) throws {
        try Task.checkCancellation()
        guard accountID == authority.scope.accountID else {
            throw WorkRelationRepositoryError.accountScopeMismatch
        }
        try validate(authority)
        try validateCurrentScope(authority.scope, in: database)
        try validateSubjectNodeScope(subjectNodeID, scope: authority.scope, in: database)
        try validateCoverage(authority, in: database)
        try validateRawSnapshot(authority, subjectNodeID: subjectNodeID, in: database)
        try validate(relations, subjectNodeID: subjectNodeID, authority: authority, in: database)

        if authority.mode == .completeReconciliation {
            try database.execute(
                sql: """
                    DELETE FROM relation_evidence
                    WHERE relation_id IN (
                        SELECT id FROM relations
                        WHERE account_id = ? AND subject_node_id = ?
                    )
                      AND source = ?
                      AND source_locator_kind = ? AND source_locator = ?
                      AND authority_kind = 'github'
                      AND authority_account_id = ? AND authority_organization_id = ?
                      AND authority_feature = ? AND authority_stream_id = ?
                      AND authority_credential_revision = ?
                      AND authority_capability_revision = ?
                      AND source_revision = ?
                """,
                arguments: [
                    accountID.rawValue, subjectNodeID.rawValue, authority.source.rawValue,
                    authority.locator.kind, authority.locator.value,
                    authority.scope.accountID.rawValue, authority.scope.organizationID.rawValue,
                    authority.feature.rawValue, authority.streamID.rawValue,
                    authority.scope.credentialRevision.rawValue,
                    authority.scope.capabilityRevision.rawValue,
                    authority.sourceRevision
                ]
            )
        }

        for relation in relations {
            try Task.checkCancellation()
            let relationID = identifier(accountID: accountID, relation: relation)
            let existingRelationID = try String.fetchOne(
                database,
                sql: """
                    SELECT id FROM relations
                    WHERE account_id = ? AND subject_node_id = ?
                      AND object_node_id IS ? AND kind = ?
                """,
                arguments: [
                    accountID.rawValue, relation.subjectNodeID.rawValue,
                    relation.objectNodeID?.rawValue, relation.kind.rawValue
                ]
            )
            if let existingRelationID {
                try database.execute(
                    sql: """
                        UPDATE relations
                        SET confidence = CASE
                                WHEN ? = 'confirmed' THEN ?
                                ELSE confidence
                            END,
                            observed_at_ms = MAX(observed_at_ms, ?)
                        WHERE id = ?
                    """,
                    arguments: [
                        relation.confidence.rawValue, relation.confidence.rawValue,
                        milliseconds(relation.observedAt), existingRelationID
                    ]
                )
            } else {
                try database.execute(
                    sql: """
                        INSERT INTO relations (
                            id, account_id, subject_node_id, object_node_id, kind,
                            confidence, observed_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        relationID, accountID.rawValue, relation.subjectNodeID.rawValue,
                        relation.objectNodeID?.rawValue, relation.kind.rawValue,
                        relation.confidence.rawValue, milliseconds(relation.observedAt)
                    ]
                )
            }
            let persistedRelationID = existingRelationID ?? relationID
            for evidence in relation.evidence {
                try Task.checkCancellation()
                let existingCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM relation_evidence
                        WHERE relation_id = ? AND evidence_id = ?
                    """,
                    arguments: [persistedRelationID, evidence.id.rawValue]
                ) ?? 0
                if existingCount > 0 {
                    let exactCount = try Int.fetchOne(
                        database,
                        sql: """
                            SELECT COUNT(*) FROM relation_evidence
                            WHERE relation_id = ? AND evidence_id = ?
                              AND source = ? AND source_locator_kind = ? AND source_locator = ?
                              AND authority_kind = 'github'
                              AND authority_account_id = ? AND authority_organization_id = ?
                              AND authority_feature = ? AND authority_stream_id = ?
                              AND authority_credential_revision = ?
                              AND authority_capability_revision = ?
                              AND source_node_id IS ? AND source_event_id IS ?
                              AND source_revision IS ? AND raw_snapshot_id IS ?
                              AND confidence = ? AND confirmation = ?
                              AND observed_at_ms = ? AND excerpt IS ?
                        """,
                        arguments: [
                            persistedRelationID, evidence.id.rawValue, evidence.source.rawValue,
                            evidence.locator.kind, evidence.locator.value,
                            authority.scope.accountID.rawValue, authority.scope.organizationID.rawValue,
                            authority.feature.rawValue, authority.streamID.rawValue,
                            authority.scope.credentialRevision.rawValue,
                            authority.scope.capabilityRevision.rawValue,
                            evidence.nodeID?.rawValue, evidence.eventID?.rawValue,
                            evidence.sourceRevision, evidence.rawSnapshotID?.rawValue,
                            evidence.confidence.rawValue, evidence.confirmation.rawValue,
                            milliseconds(evidence.observedAt), evidence.excerpt
                        ]
                    ) ?? 0
                    guard exactCount == 1 else {
                        throw WorkRelationRepositoryError.duplicateEvidence
                    }
                    continue
                }
                try database.execute(
                    sql: """
                        INSERT INTO relation_evidence (
                            relation_id, evidence_id, source, source_locator_kind, source_locator,
                            authority_kind, authority_account_id, authority_organization_id,
                            authority_feature, authority_stream_id, authority_credential_revision,
                            authority_capability_revision, source_node_id, source_event_id,
                            source_revision, raw_snapshot_id, confidence, confirmation,
                            observed_at_ms, excerpt
                        ) VALUES (?, ?, ?, ?, ?, 'github', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        persistedRelationID, evidence.id.rawValue, evidence.source.rawValue,
                        evidence.locator.kind, evidence.locator.value,
                        authority.scope.accountID.rawValue, authority.scope.organizationID.rawValue,
                        authority.feature.rawValue, authority.streamID.rawValue,
                        authority.scope.credentialRevision.rawValue,
                        authority.scope.capabilityRevision.rawValue,
                        evidence.nodeID?.rawValue, evidence.eventID?.rawValue,
                        evidence.sourceRevision, evidence.rawSnapshotID?.rawValue,
                        evidence.confidence.rawValue, evidence.confirmation.rawValue,
                        milliseconds(evidence.observedAt), evidence.excerpt
                    ]
                )
            }
        }

        if authority.mode == .completeReconciliation {
            try database.execute(
                sql: """
                    DELETE FROM relations
                    WHERE account_id = ? AND subject_node_id = ?
                      AND NOT EXISTS (
                          SELECT 1 FROM relation_evidence
                          WHERE relation_evidence.relation_id = relations.id
                      )
                """,
                arguments: [accountID.rawValue, subjectNodeID.rawValue]
            )
        }
    }

    /// Replaces a fully traversed paginated source as one stream operation.
    /// Every page remains separately raw-bound, while the deletion scope is
    /// the stream rather than the current set of page locators. This avoids
    /// retaining evidence from a page that became empty or no longer exists.
    nonisolated static func replaceCompletePages(
        _ replacements: [PageBoundRelationReplacement],
        accountID: AccountID,
        subjectNodeID: GitHubNodeID,
        scope: SynchronizationScope,
        source: EvidenceSource,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        repositoryID: RepositoryID?,
        sourceRevision: String,
        observedAt: Date,
        in database: Database
    ) throws {
        try Task.checkCancellation()
        guard accountID == scope.accountID else {
            throw WorkRelationRepositoryError.accountScopeMismatch
        }
        guard source != .localWorkflow,
              source != .legacyUnverified,
              !sourceRevision.isEmpty,
              sourceRevision.count <= 500
        else {
            throw WorkRelationRepositoryError.invalidSourceAuthority
        }
        try validateCurrentScope(scope, in: database)
        try validateSubjectNodeScope(subjectNodeID, scope: scope, in: database)
        try validateCoverage(
            scope: scope,
            repositoryID: repositoryID,
            feature: feature,
            streamID: streamID,
            observedAt: observedAt,
            in: database
        )
        for replacement in replacements {
            let authority = replacement.authority
            guard authority.scope == scope,
                  authority.source == source,
                  authority.feature == feature,
                  authority.streamID == streamID,
                  authority.repositoryID == repositoryID,
                  authority.sourceRevision == sourceRevision,
                  milliseconds(authority.observedAt) == milliseconds(observedAt),
                  authority.mode == .completeReconciliation
            else {
                throw WorkRelationRepositoryError.evidenceAuthorityMismatch
            }
            try validate(authority)
            try validate(
                replacement.relations,
                subjectNodeID: subjectNodeID,
                authority: authority,
                in: database
            )
            try validateRawSnapshot(authority, subjectNodeID: subjectNodeID, in: database)
        }

        try database.execute(
            sql: """
                DELETE FROM relation_evidence
                WHERE relation_id IN (
                    SELECT id FROM relations
                    WHERE account_id = ? AND subject_node_id = ?
                )
                  AND source = ?
                  AND authority_kind = 'github'
                  AND authority_account_id = ? AND authority_organization_id = ?
                  AND authority_feature = ? AND authority_stream_id = ?
                  AND authority_credential_revision = ?
                  AND authority_capability_revision = ?
                  AND source_revision = ?
                """,
            arguments: [
                accountID.rawValue, subjectNodeID.rawValue, source.rawValue,
                scope.accountID.rawValue, scope.organizationID.rawValue,
                feature.rawValue, streamID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                sourceRevision
            ]
        )
        try database.execute(
            sql: """
                DELETE FROM relations
                WHERE account_id = ? AND subject_node_id = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM relation_evidence
                      WHERE relation_evidence.relation_id = relations.id
                  )
                """,
            arguments: [accountID.rawValue, subjectNodeID.rawValue]
        )
        for replacement in replacements where !replacement.relations.isEmpty {
            try replace(
                replacement.relations,
                accountID: accountID,
                subjectNodeID: subjectNodeID,
                authority: replacement.authority,
                in: database
            )
        }
    }

    private nonisolated static func validate(
        _ relations: [WorkRelation],
        subjectNodeID: GitHubNodeID,
        authority: RelationReplacementAuthority,
        in database: Database
    ) throws {
        guard Set(relations.map(\.subjectNodeID)).isSubset(of: [subjectNodeID]) else {
            throw WorkRelationRepositoryError.subjectScopeMismatch
        }
        let relationKeys = relations.map(canonicalKey)
        guard Set(relationKeys).count == relationKeys.count else {
            throw WorkRelationRepositoryError.duplicateRelation
        }
        for relation in relations {
            guard !relation.evidence.isEmpty else {
                throw WorkRelationRepositoryError.missingEvidence
            }
            guard Set(relation.evidence.map(\.id)).count == relation.evidence.count else {
                throw WorkRelationRepositoryError.duplicateEvidence
            }
            if let objectNodeID = relation.objectNodeID {
                try validateObjectNodeScope(objectNodeID, scope: authority.scope, in: database)
            }
            for evidence in relation.evidence {
                guard evidence.source == authority.source,
                      evidence.locator == authority.locator,
                      evidence.sourceRevision == authority.sourceRevision,
                      evidence.authority == .github(
                        scope: authority.scope,
                        feature: authority.feature,
                        streamID: authority.streamID
                      ),
                      evidence.confirmation == (authority.mode == .completeReconciliation ? .confirmed : .provisional),
                      evidence.rawSnapshotID == authority.rawSnapshotID
                else {
                    throw WorkRelationRepositoryError.evidenceAuthorityMismatch
                }
            }
        }
    }

    private nonisolated static func validate(_ authority: RelationReplacementAuthority) throws {
        guard authority.source != .localWorkflow,
              authority.source != .legacyUnverified,
              authority.locator.kind == "endpoint" || authority.locator.kind == "query",
              !authority.locator.value.isEmpty, authority.locator.value.count <= 2_048,
              !authority.sourceRevision.isEmpty, authority.sourceRevision.count <= 500
        else {
            throw WorkRelationRepositoryError.invalidSourceAuthority
        }
        if authority.mode == .completeReconciliation, authority.rawSnapshotID == nil {
            throw WorkRelationRepositoryError.missingRawSnapshot
        }
    }

    private nonisolated static func validateCurrentScope(
        _ scope: SynchronizationScope,
        in database: Database
    ) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope {
            throw WorkRelationRepositoryError.staleSynchronizationScope
        } catch {
            throw WorkRelationRepositoryError.subjectNodeScopeMismatch
        }
    }

    private nonisolated static func validateCoverage(
        _ authority: RelationReplacementAuthority,
        in database: Database
    ) throws {
        try validateCoverage(
            scope: authority.scope,
            repositoryID: authority.repositoryID,
            feature: authority.feature,
            streamID: authority.streamID,
            observedAt: authority.observedAt,
            in: database
        )
    }

    private nonisolated static func validateCoverage(
        scope: SynchronizationScope,
        repositoryID: RepositoryID?,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        observedAt: Date,
        in database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM coverage_records
                WHERE account_id = ? AND organization_id = ? AND repository_id IS ?
                  AND feature = ? AND stream_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                  AND status = ? AND last_successful_at_ms = ?
            """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                repositoryID?.rawValue, feature.rawValue,
                streamID.rawValue, scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue, CoverageStatus.complete.rawValue,
                milliseconds(observedAt)
            ]
        ) ?? 0
        guard count == 1 else {
            throw WorkRelationRepositoryError.incompleteCoverage
        }
    }

    private nonisolated static func validateRawSnapshot(
        _ authority: RelationReplacementAuthority,
        subjectNodeID: GitHubNodeID,
        in database: Database
    ) throws {
        guard let rawSnapshotID = authority.rawSnapshotID else { return }
        let locatorClause: String
        let locatorArguments: [String]
        switch authority.locator {
        case let .endpoint(endpoint):
            locatorClause = "endpoint = ? AND authority_request_key = ?"
            locatorArguments = [endpoint, "GET \(endpoint)"]
        case let .query(query):
            locatorClause = "authority_request_key = ?"
            locatorArguments = [query]
        case .localWorkflow, .legacyUnverified:
            throw WorkRelationRepositoryError.invalidSourceAuthority
        }
        var arguments: [DatabaseValueConvertible?] = [
            rawSnapshotID.rawValue, authority.scope.accountID.rawValue,
            authority.scope.organizationID.rawValue, authority.feature.rawValue,
            authority.streamID.rawValue, authority.scope.credentialRevision.rawValue,
            authority.scope.capabilityRevision.rawValue, milliseconds(authority.observedAt)
        ]
        arguments.append(contentsOf: locatorArguments)
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM raw_api_snapshots
                WHERE id = ? AND account_id = ?
                  AND authority_organization_id = ? AND authority_feature = ?
                  AND authority_stream_id = ? AND authority_credential_revision = ?
                  AND authority_capability_revision = ? AND observed_at_ms = ?
                  AND \(locatorClause)
                  AND (github_node_id IS NULL OR github_node_id = ?)
            """,
            arguments: StatementArguments(arguments + [subjectNodeID.rawValue])
        ) ?? 0
        guard count == 1 else {
            throw WorkRelationRepositoryError.rawSnapshotScopeMismatch
        }
    }

    private nonisolated static func validateSubjectNodeScope(
        _ subjectNodeID: GitHubNodeID,
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        let matchingCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM github_nodes
                WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
            """,
            arguments: [subjectNodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue]
        ) ?? 0
        guard matchingCount == 1 else {
            throw WorkRelationRepositoryError.subjectNodeScopeMismatch
        }
    }

    private nonisolated static func validateObjectNodeScope(
        _ objectNodeID: GitHubNodeID,
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        // Content nodes are account/organization scoped. Actor identities are
        // globally keyed GitHub identities; teams are organization scoped; the
        // selected account's own node is valid only for that account. This
        // admits authored/assigned/reviewer edges without letting a team or
        // content node cross the selected organization boundary.
        let matchingCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM (
                    SELECT github_node_id AS node_id
                    FROM github_nodes
                    WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                    UNION ALL
                    SELECT github_node_id AS node_id
                    FROM actors
                    WHERE github_node_id = ?
                    UNION ALL
                    SELECT github_node_id AS node_id
                    FROM teams
                    WHERE github_node_id = ? AND organization_id = ?
                    UNION ALL
                    SELECT github_node_id AS node_id
                    FROM accounts
                    WHERE github_node_id = ? AND id = ?
                )
            """,
            arguments: [
                objectNodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue,
                objectNodeID.rawValue,
                objectNodeID.rawValue, scope.organizationID.rawValue,
                objectNodeID.rawValue, scope.accountID.rawValue
            ]
        ) ?? 0
        guard matchingCount == 1 else {
            throw WorkRelationRepositoryError.objectNodeScopeMismatch
        }
    }

    private nonisolated static func canonicalKey(_ relation: WorkRelation) -> String {
        [relation.subjectNodeID.rawValue, relation.objectNodeID?.rawValue ?? "", relation.kind.rawValue]
            .joined(separator: "\u{0}")
    }

    private nonisolated static func identifier(accountID: AccountID, relation: WorkRelation) -> String {
        let canonicalValue = "\(accountID.rawValue)\u{0}\(canonicalKey(relation))"
        return SHA256.hash(data: Data(canonicalValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
