import Foundation
import GRDB

/// Mutable, authority-scoped high-water metadata for a pull-request review
/// candidate. It is intentionally not evidence: callers must still validate an
/// immutable complete traversal receipt before treating cached data as current.
struct ReviewCandidateIncrementalState: Sendable {
    let scope: SynchronizationScope
    let feature: CoverageFeature
    let streamID: SyncStreamID
    let candidate: PullRequestReviewCandidate
    let firstPageRequestKey: String
    let highWater: Date
    let rootCursor: String?
    let updatedAt: Date
}

struct ReviewThreadRootCheckpoint: Sendable {
    let rootCursor: String
    let rawPrefix: [GitHubPullRequestReviewThreadRawPage]
}

enum ReviewCandidateIncrementalStateRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case invalidFeature
    case invalidAuthority
    case invalidStream
    case invalidState
}

actor ReviewCandidateIncrementalStateRepository {
    private let vault: AccountVault

    init(vault: AccountVault) { self.vault = vault }

    func state(
        scope: SynchronizationScope,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        candidate: PullRequestReviewCandidate
    ) async throws -> ReviewCandidateIncrementalState? {
        guard scope.accountID == vault.accountID else {
            throw ReviewCandidateIncrementalStateRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Self.state(scope: scope, feature: feature, streamID: streamID, candidate: candidate, in: database)
        }
    }

    func save(_ state: ReviewCandidateIncrementalState) async throws {
        guard state.scope.accountID == vault.accountID else {
            throw ReviewCandidateIncrementalStateRepositoryError.accountScopeMismatch
        }
        try await vault.writeTransaction { database in
            try Self.save(state, in: database)
        }
    }

    nonisolated static func state(
        scope: SynchronizationScope,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        candidate: PullRequestReviewCandidate,
        in database: Database
    ) throws -> ReviewCandidateIncrementalState? {
        try validate(scope: scope, feature: feature, streamID: streamID, candidate: candidate, in: database)
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT source_revision, first_page_request_key, high_water_ms, root_cursor, updated_at_ms
                FROM review_candidate_incremental_states
                WHERE account_id = ? AND organization_id = ? AND feature = ? AND stream_id = ?
                  AND candidate_node_id = ? AND repository_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, feature.rawValue,
                        streamID.rawValue, candidate.nodeID.rawValue, candidate.repositoryID.rawValue,
                        scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue]
        ) else { return nil }
        guard let sourceRevision: String = row["source_revision"],
              let requestKey: String = row["first_page_request_key"],
              let highWaterMilliseconds: Int64 = row["high_water_ms"],
              let updatedAtMilliseconds: Int64 = row["updated_at_ms"],
              !requestKey.isEmpty
        else { throw ReviewCandidateIncrementalStateRepositoryError.invalidState }
        // A changed source revision intentionally starts a fresh overlapping
        // traversal; it is not a corrupt checkpoint.
        guard sourceRevision == candidate.sourceRevision else { return nil }
        return .init(
            scope: scope, feature: feature, streamID: streamID, candidate: candidate,
            firstPageRequestKey: requestKey,
            highWater: Date(timeIntervalSince1970: TimeInterval(highWaterMilliseconds) / 1_000),
            rootCursor: row["root_cursor"],
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAtMilliseconds) / 1_000)
        )
    }

    nonisolated static func save(_ state: ReviewCandidateIncrementalState, in database: Database) throws {
        try validate(
            scope: state.scope, feature: state.feature, streamID: state.streamID,
            candidate: state.candidate, in: database
        )
        guard !state.firstPageRequestKey.isEmpty,
              state.firstPageRequestKey.count <= 2_048,
              state.highWater.timeIntervalSinceReferenceDate.isFinite,
              state.updatedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw ReviewCandidateIncrementalStateRepositoryError.invalidState }
        try database.execute(
            sql: """
                INSERT INTO review_candidate_incremental_states (
                    account_id, organization_id, feature, stream_id, candidate_node_id, repository_id,
                    credential_revision, capability_revision, source_revision, first_page_request_key,
                    high_water_ms, root_cursor, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id, organization_id, feature, stream_id, candidate_node_id,
                            credential_revision, capability_revision)
                DO UPDATE SET repository_id = excluded.repository_id,
                              source_revision = excluded.source_revision,
                              first_page_request_key = excluded.first_page_request_key,
                              high_water_ms = excluded.high_water_ms,
                              root_cursor = excluded.root_cursor,
                              updated_at_ms = excluded.updated_at_ms
                """,
            arguments: [
                state.scope.accountID.rawValue, state.scope.organizationID.rawValue,
                state.feature.rawValue, state.streamID.rawValue, state.candidate.nodeID.rawValue,
                state.candidate.repositoryID.rawValue, state.scope.credentialRevision.rawValue,
                state.scope.capabilityRevision.rawValue, state.candidate.sourceRevision,
                state.firstPageRequestKey, milliseconds(state.highWater), state.rootCursor,
                milliseconds(state.updatedAt)
            ]
        )
    }

    nonisolated static func threadCheckpoint(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        candidate: PullRequestReviewCandidate,
        in database: Database
    ) throws -> ReviewThreadRootCheckpoint? {
        guard let state = try state(
            scope: scope, feature: .reviewThreads, streamID: streamID, candidate: candidate, in: database
        ), let rootCursor = state.rootCursor, !rootCursor.isEmpty else { return nil }
        let rows = try Row.fetchAll(database, sql: """
            SELECT pages.page_ordinal, raw.endpoint, raw.authority_request_key, raw.payload
            FROM review_candidate_thread_checkpoint_pages pages
            JOIN raw_api_snapshots raw ON raw.id = pages.raw_snapshot_id
            WHERE pages.account_id = ? AND pages.organization_id = ? AND pages.stream_id = ?
              AND pages.candidate_node_id = ? AND pages.repository_id = ?
              AND pages.credential_revision = ? AND pages.capability_revision = ?
              AND pages.source_revision = ?
              AND raw.account_id = ? AND raw.github_node_id = ?
              AND raw.authority_organization_id = ? AND raw.authority_feature = 'reviewThreads'
              AND raw.authority_stream_id = ? AND raw.authority_credential_revision = ?
              AND raw.authority_capability_revision = ?
            ORDER BY pages.page_ordinal
            """, arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, streamID.rawValue,
                                candidate.nodeID.rawValue, candidate.repositoryID.rawValue,
                                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                                candidate.sourceRevision, scope.accountID.rawValue, candidate.nodeID.rawValue,
                                scope.organizationID.rawValue, streamID.rawValue,
                                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue])
        guard !rows.isEmpty else { return nil }
        var rawPrefix = [GitHubPullRequestReviewThreadRawPage]()
        for (offset, row) in rows.enumerated() {
            guard let ordinal: Int = row["page_ordinal"], ordinal == offset + 1,
                  let endpoint: String = row["endpoint"], let requestKey: String = row["authority_request_key"],
                  let payload: Data = row["payload"]
            else { return nil }
            rawPrefix.append(.init(endpoint: endpoint, requestKey: requestKey, payload: payload))
        }
        return .init(rootCursor: rootCursor, rawPrefix: rawPrefix)
    }

    nonisolated static func saveThreadCheckpoint(
        _ checkpoint: ReviewThreadRootCheckpoint,
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        candidate: PullRequestReviewCandidate,
        observedAt: Date,
        in database: Database
    ) throws {
        guard !checkpoint.rootCursor.isEmpty, checkpoint.rootCursor.count <= 2_048,
              !checkpoint.rawPrefix.isEmpty, checkpoint.rawPrefix.count <= 100 else {
            throw ReviewCandidateIncrementalStateRepositoryError.invalidState
        }
        try save(.init(scope: scope, feature: .reviewThreads, streamID: streamID, candidate: candidate,
                       firstPageRequestKey: "graphql:TriagePullRequestReviewThreads/pull-request=\(candidate.nodeID.rawValue)/after=none",
                       highWater: observedAt, rootCursor: checkpoint.rootCursor, updatedAt: observedAt), in: database)
        try database.execute(sql: """
            DELETE FROM review_candidate_thread_checkpoint_pages
            WHERE account_id = ? AND organization_id = ? AND stream_id = ? AND candidate_node_id = ?
              AND credential_revision = ? AND capability_revision = ?
            """, arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, streamID.rawValue,
                                candidate.nodeID.rawValue, scope.credentialRevision.rawValue,
                                scope.capabilityRevision.rawValue])
        for (offset, page) in checkpoint.rawPrefix.enumerated() {
            let snapshotID = RawAPISnapshotID.make()
            try RawAPISnapshotRepository.save(.init(
                id: snapshotID, accountID: scope.accountID, githubNodeID: candidate.nodeID,
                endpoint: page.endpoint, eTag: nil, lastModified: nil,
                parserVersion: 1, observedAt: observedAt, payload: page.payload,
                requestIdentity: .init(scope: scope, feature: .reviewThreads, streamID: streamID,
                                       requestKey: page.requestKey)
            ), in: database)
            try database.execute(sql: """
                INSERT INTO review_candidate_thread_checkpoint_pages (
                    account_id, organization_id, stream_id, candidate_node_id, repository_id,
                    credential_revision, capability_revision, source_revision, page_ordinal, raw_snapshot_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, streamID.rawValue,
                                    candidate.nodeID.rawValue, candidate.repositoryID.rawValue,
                                    scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                                    candidate.sourceRevision, offset + 1, snapshotID.rawValue])
        }
    }

    private nonisolated static func validate(
        scope: SynchronizationScope,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        candidate: PullRequestReviewCandidate,
        in database: Database
    ) throws {
        guard feature == .reviews || feature == .reviewThreads else {
            throw ReviewCandidateIncrementalStateRepositoryError.invalidFeature
        }
        try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        let streamCount = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM sync_streams WHERE id = ? AND account_id = ? AND organization_id = ? AND feature = ?",
            arguments: [streamID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue, feature.rawValue]
        ) ?? 0
        guard streamCount == 1 else { throw ReviewCandidateIncrementalStateRepositoryError.invalidStream }
        let candidateCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM github_nodes
                WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                  AND repository_id = ? AND source_revision = ? AND accessibility_state = 'accessible'
                """,
            arguments: [candidate.nodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue,
                        candidate.repositoryID.rawValue, candidate.sourceRevision]
        ) ?? 0
        guard candidateCount == 1 else { throw ReviewCandidateIncrementalStateRepositoryError.invalidAuthority }
    }

    private nonisolated static func milliseconds(_ value: Date) -> Int64 {
        Int64((value.timeIntervalSince1970 * 1_000).rounded())
    }
}
