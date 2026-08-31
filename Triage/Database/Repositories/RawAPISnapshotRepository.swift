import Foundation
import GRDB

enum RawAPISnapshotRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case nodeScopeMismatch
    case requestAuthorityScopeMismatch
    case invalidEndpoint
    case invalidValidator
    case invalidParserVersion
    case invalidLimit
    case invalidRetentionLimit
    case invalidPersistedData
    case payloadTooLarge
    case immutableSnapshotConflict
}

actor RawAPISnapshotRepository {
    static let maximumPayloadBytes = 4 * 1_024 * 1_024

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(_ snapshot: RawAPISnapshot) async throws {
        guard snapshot.accountID == vault.accountID else {
            throw RawAPISnapshotRepositoryError.accountScopeMismatch
        }
        try await vault.write { database in
            try Self.save(snapshot, in: database)
        }
    }

    nonisolated static func save(_ snapshot: RawAPISnapshot, in database: Database) throws {
        try validate(snapshot)
        if let nodeID = snapshot.githubNodeID {
            let contentNodeCount: Int
            if let identity = snapshot.requestIdentity {
                contentNodeCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM github_nodes
                        WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                        """,
                    arguments: [
                        nodeID.rawValue, snapshot.accountID.rawValue,
                        identity.scope.organizationID.rawValue
                    ]
                ) ?? 0
            } else {
                // Historical raw rows did not carry source authority. Retain
                // their existing account-only diagnostic validation, but they
                // can never authorize scoped conditional replay.
                contentNodeCount = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM github_nodes WHERE github_node_id = ? AND account_id = ?",
                    arguments: [nodeID.rawValue, snapshot.accountID.rawValue]
                ) ?? 0
            }
            let repositoryNodeCount: Int
            if let identity = snapshot.requestIdentity {
                repositoryNodeCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*)
                        FROM repositories
                        JOIN account_repository_access
                          ON account_repository_access.repository_id = repositories.id
                        WHERE repositories.github_node_id = ?
                          AND repositories.organization_id = ?
                          AND account_repository_access.account_id = ?
                          AND account_repository_access.access_state = 'available'
                        """,
                    arguments: [
                        nodeID.rawValue, identity.scope.organizationID.rawValue,
                        snapshot.accountID.rawValue
                    ]
                ) ?? 0
            } else {
                repositoryNodeCount = 0
            }
            let organizationNodeCount: Int
            if let identity = snapshot.requestIdentity {
                organizationNodeCount = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM organizations WHERE id = ? AND github_node_id = ?",
                    arguments: [identity.scope.organizationID.rawValue, nodeID.rawValue]
                ) ?? 0
            } else {
                organizationNodeCount = 0
            }
            guard contentNodeCount + repositoryNodeCount + organizationNodeCount == 1 else {
                throw RawAPISnapshotRepositoryError.nodeScopeMismatch
            }
        }
        if let identity = snapshot.requestIdentity {
            let authorityCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM account_organizations
                    JOIN accounts ON accounts.id = account_organizations.account_id
                    WHERE account_organizations.account_id = ?
                      AND account_organizations.organization_id = ?
                      AND accounts.credential_revision = ?
                      AND account_organizations.capability_revision = ?
                    """,
                arguments: [
                    snapshot.accountID.rawValue,
                    identity.scope.organizationID.rawValue,
                    identity.scope.credentialRevision.rawValue,
                    identity.scope.capabilityRevision.rawValue
                ]
            ) ?? 0
            guard authorityCount == 1 else {
                throw RawAPISnapshotRepositoryError.requestAuthorityScopeMismatch
            }
        }
        if let row = try Row.fetchOne(database, sql: """
            SELECT id, account_id, github_node_id, endpoint, etag, last_modified,
                   authority_organization_id, authority_feature, authority_stream_id,
                   authority_request_key, authority_credential_revision,
                   authority_capability_revision, parser_version, observed_at_ms, payload
            FROM raw_api_snapshots WHERE id = ?
            """, arguments: [snapshot.id.rawValue]) {
            guard Self.matchesPersistedIdentity(
                try Self.snapshot(from: row),
                candidate: snapshot
            ) else {
                throw RawAPISnapshotRepositoryError.immutableSnapshotConflict
            }
            return
        }
        try database.execute(
                sql: """
                    INSERT INTO raw_api_snapshots (
                        id, account_id, github_node_id, endpoint, etag, last_modified,
                        authority_organization_id, authority_feature, authority_stream_id,
                        authority_request_key, authority_credential_revision,
                        authority_capability_revision, parser_version, observed_at_ms, payload
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    snapshot.id.rawValue, snapshot.accountID.rawValue, snapshot.githubNodeID?.rawValue,
                    snapshot.endpoint, snapshot.eTag, snapshot.lastModified,
                    snapshot.requestIdentity?.scope.organizationID.rawValue,
                    snapshot.requestIdentity?.feature.rawValue,
                    snapshot.requestIdentity?.streamID.rawValue,
                    snapshot.requestIdentity?.requestKey,
                    snapshot.requestIdentity?.scope.credentialRevision.rawValue,
                    snapshot.requestIdentity?.scope.capabilityRevision.rawValue,
                    snapshot.parserVersion,
                    Self.milliseconds(snapshot.observedAt), snapshot.payload
                ]
        )
    }

    private nonisolated static func validate(_ snapshot: RawAPISnapshot) throws {
        guard !snapshot.endpoint.isEmpty, snapshot.endpoint.count <= 2_048 else {
            throw RawAPISnapshotRepositoryError.invalidEndpoint
        }
        guard validHeaderValidator(snapshot.eTag), validHeaderValidator(snapshot.lastModified) else {
            throw RawAPISnapshotRepositoryError.invalidValidator
        }
        if let identity = snapshot.requestIdentity {
            guard identity.scope.accountID == snapshot.accountID,
                  !identity.requestKey.isEmpty,
                  identity.requestKey.count <= 2_048,
                  !identity.streamID.rawValue.isEmpty,
                  identity.streamID.rawValue.count <= 512
            else {
                throw RawAPISnapshotRepositoryError.requestAuthorityScopeMismatch
            }
        }
        guard snapshot.parserVersion > 0 else {
            throw RawAPISnapshotRepositoryError.invalidParserVersion
        }
        guard snapshot.payload.count <= maximumPayloadBytes else {
            throw RawAPISnapshotRepositoryError.payloadTooLarge
        }
    }

    func snapshots(for accountID: AccountID, limit: Int = 100) async throws -> [RawAPISnapshot] {
        guard accountID == vault.accountID else {
            throw RawAPISnapshotRepositoryError.accountScopeMismatch
        }
        guard limit >= 0 else {
            throw RawAPISnapshotRepositoryError.invalidLimit
        }
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, account_id, github_node_id, endpoint, etag, last_modified,
                           authority_organization_id, authority_feature, authority_stream_id,
                           authority_request_key, authority_credential_revision,
                           authority_capability_revision, parser_version, observed_at_ms, payload
                    FROM raw_api_snapshots
                    WHERE account_id = ?
                    ORDER BY observed_at_ms DESC, id
                    LIMIT ?
                """,
                arguments: [accountID.rawValue, limit]
            ).map { try Self.snapshot(from: $0) }
        }
    }

    /// Removes superseded snapshots only when a newer replayable snapshot remains for the same source.
    /// Snapshots referenced by normalization failures are retained as durable diagnostic provenance.
    func compact(
        accountID: AccountID,
        retainingMostRecentPerSource retentionLimit: Int = 1,
        before cutoff: Date
    ) async throws -> Int {
        guard accountID == vault.accountID else {
            throw RawAPISnapshotRepositoryError.accountScopeMismatch
        }
        guard retentionLimit > 0 else {
            throw RawAPISnapshotRepositoryError.invalidRetentionLimit
        }
        return try await vault.write { database in
            try database.execute(
                sql: """
                    DELETE FROM raw_api_snapshots
                    WHERE account_id = ?
                      AND observed_at_ms < ?
                      AND id IN (
                          SELECT id
                          FROM (
                              SELECT id,
                                     ROW_NUMBER() OVER (
                                         PARTITION BY github_node_id, endpoint, parser_version
                                         ORDER BY observed_at_ms DESC, id DESC
                                     ) AS retention_rank
                              FROM raw_api_snapshots
                              WHERE account_id = ?
                          )
                          WHERE retention_rank > ?
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM normalization_failures
                          WHERE normalization_failures.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM role_search_page_replays
                          WHERE role_search_page_replays.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM timeline_replay_receipt_pages
                          WHERE timeline_replay_receipt_pages.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM timeline_current_pages
                          WHERE timeline_current_pages.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM timeline_staged_pages
                          WHERE timeline_staged_pages.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM notification_current_pages
                          WHERE notification_current_pages.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM notification_threads
                          WHERE notification_threads.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM notification_failure_pages
                          WHERE notification_failure_pages.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM review_candidate_failure_pages
                          WHERE review_candidate_failure_pages.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM review_candidate_complete_traversal_pages
                          WHERE review_candidate_complete_traversal_pages.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM rule_evaluation_evidence
                          WHERE rule_evaluation_evidence.raw_snapshot_id = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM repository_inventory_replay_receipt_pages
                          WHERE repository_inventory_replay_receipt_pages.raw_snapshot_id
                              = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM account_organization_inventory_replay_receipt_pages
                          WHERE account_organization_inventory_replay_receipt_pages.raw_snapshot_id
                              = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM organization_metadata_replay_receipts
                          WHERE organization_metadata_replay_receipts.raw_snapshot_id
                              = raw_api_snapshots.id
                      )
                      AND NOT EXISTS (
                          SELECT 1
                          FROM source_access_observations
                          WHERE source_access_observations.raw_snapshot_id = raw_api_snapshots.id
                            AND source_access_observations.result = 'authoritativelyDeleted'
                      )
                    """,
                arguments: [
                    accountID.rawValue,
                    Self.milliseconds(cutoff),
                    accountID.rawValue,
                    retentionLimit
                ]
            )
            return database.changesCount
        }
    }

    nonisolated static func snapshot(from row: Row) throws -> RawAPISnapshot {
        guard let id = RawAPISnapshotID(rawValue: row["id"]),
              let accountID = AccountID(rawValue: row["account_id"]),
              let endpoint: String = row["endpoint"],
              let parserVersion: Int = row["parser_version"],
              let observedAtMilliseconds: Int64 = row["observed_at_ms"],
              let payload: Data = row["payload"]
        else {
            throw RawAPISnapshotRepositoryError.invalidPersistedData
        }
        let rawNodeID: String? = row["github_node_id"]
        let nodeID = rawNodeID.flatMap(GitHubNodeID.init(rawValue:))
        guard rawNodeID == nil || nodeID != nil else {
            throw RawAPISnapshotRepositoryError.invalidPersistedData
        }
        let authorityValues: [String?] = [
            row["authority_organization_id"],
            row["authority_feature"],
            row["authority_stream_id"],
            row["authority_request_key"],
            row["authority_credential_revision"],
            row["authority_capability_revision"]
        ]
        let requestIdentity: ConditionalRequestIdentity?
        if authorityValues.allSatisfy({ $0 == nil }) {
            requestIdentity = nil
        } else {
            guard let organizationID = authorityValues[0].flatMap(OrganizationID.init(rawValue:)),
                  let featureValue = authorityValues[1],
                  let feature = CoverageFeature(rawValue: featureValue),
                  let streamID = authorityValues[2].flatMap(SyncStreamID.init(rawValue:)),
                  let requestKey = authorityValues[3],
                  !requestKey.isEmpty,
                  requestKey.count <= 2_048,
                  let credentialRevision = authorityValues[4].flatMap(CredentialRevision.init(rawValue:)),
                  let capabilityRevision = authorityValues[5].flatMap(CapabilityRevision.init(rawValue:))
            else {
                throw RawAPISnapshotRepositoryError.invalidPersistedData
            }
            requestIdentity = ConditionalRequestIdentity(
                scope: SynchronizationScope(
                    accountID: accountID,
                    organizationID: organizationID,
                    credentialRevision: credentialRevision,
                    capabilityRevision: capabilityRevision
                ),
                feature: feature,
                streamID: streamID,
                requestKey: requestKey
            )
        }
        let eTag: String? = row["etag"]
        let lastModified: String? = row["last_modified"]
        guard validHeaderValidator(eTag), validHeaderValidator(lastModified) else {
            throw RawAPISnapshotRepositoryError.invalidPersistedData
        }
        let snapshot = RawAPISnapshot(
            id: id, accountID: accountID, githubNodeID: nodeID, endpoint: endpoint,
            eTag: eTag, lastModified: lastModified, parserVersion: parserVersion,
            observedAt: Date(timeIntervalSince1970: TimeInterval(observedAtMilliseconds) / 1_000),
            payload: payload,
            requestIdentity: requestIdentity
        )
        do {
            try validate(snapshot)
        } catch {
            throw RawAPISnapshotRepositoryError.invalidPersistedData
        }
        return snapshot
    }

    private nonisolated static func validHeaderValidator(_ value: String?) -> Bool {
        guard let value else { return true }
        guard !value.isEmpty, value.count <= 2_048 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    private nonisolated static func matchesPersistedIdentity(
        _ persisted: RawAPISnapshot,
        candidate: RawAPISnapshot
    ) -> Bool {
        persisted.id == candidate.id
            && persisted.accountID == candidate.accountID
            && persisted.githubNodeID == candidate.githubNodeID
            && persisted.endpoint == candidate.endpoint
            && persisted.eTag == candidate.eTag
            && persisted.lastModified == candidate.lastModified
            && persisted.parserVersion == candidate.parserVersion
            && milliseconds(persisted.observedAt) == milliseconds(candidate.observedAt)
            && persisted.payload == candidate.payload
            && persisted.requestIdentity == candidate.requestIdentity
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
