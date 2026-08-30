import CryptoKit
import Foundation
import GRDB

enum TimelineEventRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case candidateScopeMismatch
    case invalidRawPage
    case invalidPersistedPage(TimelineRawPageProvenance?)
    case invalidEventPayload
    case duplicateEventID
    case eventBelongsToAnotherSubject
}

struct TimelineRawPageProvenance: Equatable, Sendable {
    let snapshotID: RawAPISnapshotID
    let endpoint: String
    let requestKey: String
    let parserVersion: Int
    let observedAt: Date
}

struct TimelineSavedPageInventory: Sendable {
    let events: [GitHubTimelineEventDTO]
    let pageCount: Int
    let firstPageETag: String?
    let firstPageLastModified: String?
    let pageProvenances: [TimelineRawPageProvenance]
    let eventPageProvenances: [GitHubEventID: TimelineRawPageProvenance]
    let latestPageProvenance: TimelineRawPageProvenance
}

/// Relations are only reconciled when every persisted page belongs to this
/// completion. A resumed mixed-age traversal intentionally makes no relation
/// mutation instead of claiming current page authority.
enum TimelineRelationReconciliation: Sendable {
    case unavailable
    case complete(
        scope: SynchronizationScope,
        pageProvenances: [TimelineRawPageProvenance],
        eventPageProvenances: [GitHubEventID: TimelineRawPageProvenance]
    )
}

struct TimelineReplayReceiptInput: Sendable {
    let validator: ConditionalRequestValidator
    let rawSourceRevision: String
    let pages: [TimelineRawPageProvenance]
}

actor TimelineEventRepository {
    static let maximumRawPageBytes = 2 * 1_024 * 1_024

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func saveRawPage(
        _ page: GitHubPage<GitHubTimelineEventDTO>,
        candidate: TimelineCandidate,
        pageIndex: Int,
        requestKey: String,
        scope: SynchronizationScope,
        accountID: AccountID,
        organizationID: OrganizationID,
        observedAt: Date
    ) async throws -> RawAPISnapshotID {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500,
              scope.accountID == accountID,
              scope.organizationID == organizationID,
              Self.isValidRequestKey(requestKey, candidate: candidate, pageIndex: pageIndex)
        else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        guard pageIndex > 0, pageIndex <= 100, page.payload.count <= Self.maximumRawPageBytes else {
            throw TimelineEventRepositoryError.invalidRawPage
        }
        let snapshotID = Self.snapshotID(
            for: candidate,
            pageIndex: pageIndex,
            requestIdentity: Self.requestIdentity(
                scope: scope,
                candidate: candidate,
                requestKey: requestKey
            ),
            observedAt: observedAt,
            payload: page.payload
        )
        try await vault.write { database in
            try Self.requireCandidateScope(
                candidate,
                accountID: accountID,
                organizationID: organizationID,
                in: database
            )
            try RawAPISnapshotRepository.save(
                RawAPISnapshot(
                    id: snapshotID,
                    accountID: accountID,
                    githubNodeID: candidate.nodeID,
                    endpoint: Self.snapshotEndpoint(for: candidate, pageIndex: pageIndex),
                    eTag: page.etag,
                    lastModified: page.lastModified,
                    parserVersion: 1,
                    observedAt: observedAt,
                    payload: page.payload,
                    requestIdentity: Self.requestIdentity(
                        scope: scope,
                        candidate: candidate,
                        requestKey: requestKey
                    )
                ),
                in: database
            )
        }
        return snapshotID
    }

    func saveRejectedRawPage(
        _ page: GitHubUndecodablePage,
        candidate: TimelineCandidate,
        pageIndex: Int,
        requestKey: String,
        scope: SynchronizationScope,
        accountID: AccountID,
        organizationID: OrganizationID,
        observedAt: Date,
        redactedDiagnostic: String
    ) async throws -> RawAPISnapshotID {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500,
              scope.accountID == accountID,
              scope.organizationID == organizationID,
              Self.isValidRequestKey(requestKey, candidate: candidate, pageIndex: pageIndex)
        else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        guard pageIndex > 0, pageIndex <= 100, page.payload.count <= Self.maximumRawPageBytes else {
            throw TimelineEventRepositoryError.invalidRawPage
        }
        let snapshotID = Self.snapshotID(
            for: candidate,
            pageIndex: pageIndex,
            requestIdentity: Self.requestIdentity(
                scope: scope,
                candidate: candidate,
                requestKey: requestKey
            ),
            observedAt: observedAt,
            payload: page.payload
        )
        try await vault.writeTransaction { database in
            try Self.requireCandidateScope(
                candidate,
                accountID: accountID,
                organizationID: organizationID,
                in: database
            )
            try RawAPISnapshotRepository.save(
                RawAPISnapshot(
                    id: snapshotID,
                    accountID: accountID,
                    githubNodeID: candidate.nodeID,
                    endpoint: Self.pendingSnapshotEndpoint(for: candidate, pageIndex: pageIndex),
                    eTag: page.etag,
                    lastModified: page.lastModified,
                    parserVersion: 1,
                    observedAt: observedAt,
                    payload: page.payload,
                    requestIdentity: Self.requestIdentity(
                        scope: scope,
                        candidate: candidate,
                        requestKey: requestKey
                    )
                ),
                in: database
            )
            try NormalizationFailureRepository.record(
                NormalizationFailure(
                    id: UUID(),
                    accountID: accountID,
                    rawSnapshotID: snapshotID,
                    githubNodeID: candidate.nodeID,
                    endpoint: "GET \(candidate.repository.path)/issues/\(candidate.number)/timeline",
                    parserVersion: 1,
                    occurredAt: observedAt,
                    redactedDiagnostic: redactedDiagnostic
                ),
                in: database
            )
        }
        return snapshotID
    }

    func savedPages(
        for candidate: TimelineCandidate,
        scope: SynchronizationScope,
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> TimelineSavedPageInventory {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500,
              scope.accountID == accountID,
              scope.organizationID == organizationID
        else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        return try await vault.read { database in
            try Self.requireCandidateScope(
                candidate,
                accountID: accountID,
                organizationID: organizationID,
                in: database
            )
            let streamID = SyncStreamID(rawValue: "timeline:\(candidate.nodeID.rawValue)")!
            // A staged traversal is private download state. Prefer it while it
            // exists, but never blend it with the last atomically published
            // membership.
            let stagedCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM timeline_staged_pages
                    WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
                      AND feature = ? AND stream_id = ?
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                    CoverageFeature.timelines.rawValue, streamID.rawValue
                ]
            ) ?? 0
            let membershipTable = stagedCount > 0 ? "timeline_staged_pages" : "timeline_current_pages"
            let snapshots = try Row.fetchAll(
                database,
                sql: """
                    SELECT raw_api_snapshots.id, raw_api_snapshots.account_id,
                           raw_api_snapshots.github_node_id, raw_api_snapshots.endpoint,
                           raw_api_snapshots.etag, raw_api_snapshots.last_modified,
                           raw_api_snapshots.authority_organization_id,
                           raw_api_snapshots.authority_feature,
                           raw_api_snapshots.authority_stream_id,
                           raw_api_snapshots.authority_request_key,
                           raw_api_snapshots.authority_credential_revision,
                           raw_api_snapshots.authority_capability_revision,
                           raw_api_snapshots.parser_version,
                           raw_api_snapshots.observed_at_ms, raw_api_snapshots.payload,
                           \(membershipTable).page_index AS current_page_index,
                           \(membershipTable).request_key AS current_request_key,
                           \(membershipTable).observed_at_ms AS current_observed_at_ms,
                           \(membershipTable).is_terminal AS current_is_terminal
                    FROM \(membershipTable)
                    JOIN raw_api_snapshots
                      ON raw_api_snapshots.id = \(membershipTable).raw_snapshot_id
                    WHERE \(membershipTable).account_id = ?
                      AND \(membershipTable).organization_id = ?
                      AND \(membershipTable).github_node_id = ?
                      AND \(membershipTable).feature = ?
                      AND \(membershipTable).stream_id = ?
                      AND \(membershipTable).credential_revision = ?
                      AND \(membershipTable).capability_revision = ?
                      AND \(membershipTable).source_revision = ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM normalization_failures
                          WHERE normalization_failures.raw_snapshot_id = raw_api_snapshots.id
                      )
                    ORDER BY \(membershipTable).page_index ASC
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                    CoverageFeature.timelines.rawValue, streamID.rawValue,
                    scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                    candidate.sourceRevision
                ]
            )
            let matching = try snapshots.map { row -> (RawAPISnapshot, Int, String, Int64, Int) in
                let snapshot = try RawAPISnapshotRepository.snapshot(from: row)
                guard let pageIndex: Int = row["current_page_index"],
                      let requestKey: String = row["current_request_key"],
                      let observedAtMilliseconds: Int64 = row["current_observed_at_ms"],
                      let isTerminal: Int = row["current_is_terminal"]
                else {
                    throw TimelineEventRepositoryError.invalidPersistedPage(nil)
                }
                return (snapshot, pageIndex, requestKey, observedAtMilliseconds, isTerminal)
            }
            guard !matching.isEmpty, matching.count <= 100 else {
                throw TimelineEventRepositoryError.invalidPersistedPage(nil)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persistedPages = try matching.enumerated().map {
                offset, membership -> (TimelineRawPageProvenance, Data) in
                let (snapshot, pageIndex, requestKey, observedAtMilliseconds, isTerminal) = membership
                guard snapshot.endpoint == Self.snapshotEndpoint(
                    for: candidate,
                    pageIndex: pageIndex
                ),
                      pageIndex == offset + 1,
                      requestKey == snapshot.requestIdentity?.requestKey,
                      observedAtMilliseconds == Self.milliseconds(snapshot.observedAt),
                      (offset < matching.count - 1 ? isTerminal == 0 : (isTerminal == 0 || isTerminal == 1)),
                      snapshot.parserVersion == 1,
                      snapshot.payload.count <= Self.maximumRawPageBytes,
                      snapshot.requestIdentity == Self.requestIdentity(
                        scope: scope,
                        candidate: candidate,
                        requestKey: snapshot.requestIdentity?.requestKey ?? ""
                      ),
                      Self.isValidRequestKey(
                        snapshot.requestIdentity?.requestKey ?? "",
                        candidate: candidate,
                        pageIndex: pageIndex
                      )
                else {
                    throw TimelineEventRepositoryError.invalidPersistedPage(nil)
                }
                return (
                    TimelineRawPageProvenance(
                        snapshotID: snapshot.id,
                        endpoint: snapshot.endpoint,
                        requestKey: requestKey,
                        parserVersion: snapshot.parserVersion,
                        observedAt: snapshot.observedAt
                    ),
                    snapshot.payload
                )
            }
            var eventPageProvenances = [GitHubEventID: TimelineRawPageProvenance]()
            let events = try persistedPages.flatMap { provenance, payload in
                do {
                    let pageEvents = try decoder.decode([GitHubTimelineEventDTO].self, from: payload)
                    for event in pageEvents {
                        // Normalization remains responsible for rejecting
                        // malformed or duplicate IDs. This map retains the
                        // exact raw page for IDs that can be addressed.
                        if let rawID = event.id, let eventID = GitHubEventID(rawValue: rawID) {
                            eventPageProvenances[eventID] = provenance
                        }
                    }
                    return pageEvents
                } catch is DecodingError {
                    throw TimelineEventRepositoryError.invalidPersistedPage(provenance)
                }
            }
            return TimelineSavedPageInventory(
                events: events,
                pageCount: matching.count,
                firstPageETag: matching.first?.0.eTag,
                firstPageLastModified: matching.first?.0.lastModified,
                pageProvenances: persistedPages.map(\.0),
                eventPageProvenances: eventPageProvenances,
                latestPageProvenance: persistedPages[persistedPages.count - 1].0
            )
        }
    }

    func commitValidatedRawPage(
        _ snapshotID: RawAPISnapshotID,
        candidate: TimelineCandidate,
        pageIndex: Int,
        requestKey: String,
        scope: SynchronizationScope,
        nextPageURL: URL?,
        accountID: AccountID,
        organizationID: OrganizationID,
        attemptedAt: Date
    ) async throws {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500,
              scope.accountID == accountID,
              scope.organizationID == organizationID,
              Self.isValidRequestKey(requestKey, candidate: candidate, pageIndex: pageIndex)
        else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        guard pageIndex > 0, pageIndex <= 100 else {
            throw TimelineEventRepositoryError.invalidRawPage
        }
        try await vault.writeTransaction { database in
            try Self.requireCandidateScope(
                candidate,
                accountID: accountID,
                organizationID: organizationID,
                in: database
            )
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, account_id, github_node_id, endpoint, etag, last_modified,
                           authority_organization_id, authority_feature, authority_stream_id,
                           authority_request_key, authority_credential_revision,
                           authority_capability_revision, parser_version, observed_at_ms, payload
                    FROM raw_api_snapshots
                    WHERE id = ? AND account_id = ?
                    """,
                arguments: [snapshotID.rawValue, accountID.rawValue]
            ) else {
                throw TimelineEventRepositoryError.invalidPersistedPage(nil)
            }
            let snapshot = try RawAPISnapshotRepository.snapshot(from: row)
            guard snapshot.githubNodeID == candidate.nodeID,
                  snapshot.endpoint == Self.snapshotEndpoint(
                    for: candidate,
                    pageIndex: pageIndex
                  ),
                  snapshot.parserVersion == 1,
                  snapshot.requestIdentity == Self.requestIdentity(
                    scope: scope,
                    candidate: candidate,
                    requestKey: requestKey
                  )
            else {
                throw TimelineEventRepositoryError.invalidPersistedPage(nil)
            }
            try TimelineCandidateRepository.saveDownloadedPageCheckpoint(
                for: candidate,
                nextPageURL: nextPageURL,
                accountID: accountID,
                organizationID: organizationID,
                attemptedAt: attemptedAt,
                in: database
            )
            let streamID = SyncStreamID(rawValue: "timeline:\(candidate.nodeID.rawValue)")!
            if pageIndex == 1 {
                // A fresh traversal replaces only unpublished staging. The
                // prior current membership, coverage, validator, and receipt
                // remain one coherent published generation until completion.
                try database.execute(
                    sql: """
                        DELETE FROM timeline_staged_pages
                        WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
                          AND feature = ? AND stream_id = ?
                        """,
                    arguments: [
                        accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                        CoverageFeature.timelines.rawValue, streamID.rawValue
                    ]
                )
            } else {
                let predecessorCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM timeline_staged_pages
                        WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
                          AND feature = ? AND stream_id = ?
                          AND credential_revision = ? AND capability_revision = ?
                          AND source_revision = ? AND page_index = ? AND is_terminal = 0
                        """,
                    arguments: [
                        accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                        CoverageFeature.timelines.rawValue, streamID.rawValue,
                        scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                        candidate.sourceRevision, pageIndex - 1
                    ]
                ) ?? 0
                guard predecessorCount == 1 else {
                    throw TimelineEventRepositoryError.invalidPersistedPage(nil)
                }
            }
            try database.execute(
                sql: """
                    INSERT INTO timeline_staged_pages (
                        account_id, organization_id, github_node_id, feature, stream_id,
                        credential_revision, capability_revision, source_revision, page_index,
                        raw_snapshot_id, request_key, observed_at_ms, is_terminal
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (
                        account_id, organization_id, github_node_id, feature, stream_id,
                        credential_revision, capability_revision, source_revision, page_index
                    ) DO NOTHING
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                    CoverageFeature.timelines.rawValue, streamID.rawValue,
                    scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                    candidate.sourceRevision, pageIndex, snapshotID.rawValue, requestKey,
                    Self.milliseconds(snapshot.observedAt), nextPageURL == nil ? 1 : 0
                ]
            )
            let stagedMatchCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM timeline_staged_pages
                    WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
                      AND feature = ? AND stream_id = ? AND credential_revision = ?
                      AND capability_revision = ? AND source_revision = ? AND page_index = ?
                      AND raw_snapshot_id = ? AND request_key = ? AND observed_at_ms = ?
                      AND is_terminal = ?
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                    CoverageFeature.timelines.rawValue, streamID.rawValue,
                    scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                    candidate.sourceRevision, pageIndex, snapshotID.rawValue, requestKey,
                    Self.milliseconds(snapshot.observedAt), nextPageURL == nil ? 1 : 0
                ]
            ) ?? 0
            guard stagedMatchCount == 1 else {
                throw TimelineEventRepositoryError.invalidPersistedPage(nil)
            }
        }
    }

    func replace(
        _ events: [NormalizedGitHubTimelineEvent],
        candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        observedAt: Date
    ) async throws {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500 else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        try Self.validate(events)
        try await vault.writeTransaction { database in
            try Self.replace(
                events,
                candidate: candidate,
                accountID: accountID,
                organizationID: organizationID,
                observedAt: observedAt,
                in: database
            )
        }
    }

    func replaceAndComplete(
        _ events: [NormalizedGitHubTimelineEvent],
        candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        observedAt: Date,
        relationReconciliation: TimelineRelationReconciliation,
        conditionalRequestCacheMutation: ConditionalRequestCacheMutation? = nil,
        replayReceipt: TimelineReplayReceiptInput? = nil
    ) async throws {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500 else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        if case let .complete(scope, _, _) = relationReconciliation,
           (scope.accountID != accountID || scope.organizationID != organizationID) {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        try Self.validate(events)
        try await vault.writeTransaction { database in
            try Task.checkCancellation()
            let publishedPages = try Self.publishStagedMembership(
                candidate: candidate,
                accountID: accountID,
                organizationID: organizationID,
                in: database
            )
            try Self.replace(
                events,
                candidate: candidate,
                accountID: accountID,
                organizationID: organizationID,
                observedAt: observedAt,
                in: database
            )
            try TimelineCandidateRepository.completeDownloadedTimeline(
                for: candidate,
                accountID: accountID,
                organizationID: organizationID,
                completedAt: observedAt,
                in: database
            )
            switch relationReconciliation {
            case .unavailable:
                break
            case let .complete(scope, pageProvenances, eventPageProvenances):
                guard pageProvenances == publishedPages,
                      Set(eventPageProvenances.values.map(\.snapshotID))
                        .isSubset(of: Set(publishedPages.map(\.snapshotID)))
                else {
                    throw WorkRelationRepositoryError.rawSnapshotScopeMismatch
                }
                let streamID = SyncStreamID(rawValue: "timeline:\(candidate.nodeID.rawValue)")!
                try CoverageRepository.save(
                    CoverageRecord(
                        accountID: accountID,
                        organizationID: organizationID,
                        repositoryID: candidate.repositoryID,
                        feature: .timelines,
                        streamID: streamID,
                        intervalStart: nil,
                        intervalEnd: nil,
                        credentialRevision: scope.credentialRevision,
                        capabilityRevision: scope.capabilityRevision,
                        status: .complete,
                        lastSuccessfulAt: observedAt,
                        failureDetail: nil
                    ),
                    attemptedAt: observedAt,
                    expectedAccountID: accountID,
                    in: database
                )
                let replacements = try Self.pageBoundRelationReplacements(
                    from: events,
                    candidate: candidate,
                    scope: scope,
                    pageProvenances: pageProvenances,
                    eventPageProvenances: eventPageProvenances
                )
                try WorkRelationRepository.replaceCompletePages(
                    replacements,
                    accountID: accountID,
                    subjectNodeID: candidate.nodeID,
                    scope: scope,
                    source: .restTimeline,
                    feature: .timelines,
                    streamID: streamID,
                    repositoryID: candidate.repositoryID,
                    sourceRevision: candidate.sourceRevision,
                    observedAt: observedAt,
                    in: database
                )
            }
            try Task.checkCancellation()
            switch conditionalRequestCacheMutation {
            case let .save(validator):
                guard let replayReceipt, replayReceipt.validator == validator else {
                    throw TimelineEventRepositoryError.invalidPersistedPage(nil)
                }
                try ConditionalRequestCacheRepository.save(
                    validator,
                    expectedAccountID: accountID,
                    in: database
                )
                try Self.saveReplayReceipt(
                    replayReceipt,
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    completedAt: observedAt,
                    in: database
                )
            case let .remove(identity):
                guard replayReceipt == nil else {
                    throw TimelineEventRepositoryError.invalidPersistedPage(nil)
                }
                try ConditionalRequestCacheRepository.remove(
                    for: identity,
                    expectedAccountID: accountID,
                    in: database
                )
                try Self.removeReplayReceipt(
                    for: identity,
                    githubNodeID: candidate.nodeID,
                    in: database
                )
            case nil:
                guard replayReceipt == nil else {
                    throw TimelineEventRepositoryError.invalidPersistedPage(nil)
                }
                break
            }
        }
    }

    func completeNotModifiedReplay(
        candidate: TimelineCandidate,
        validator: ConditionalRequestValidator,
        observedAt: Date
    ) async throws -> Bool {
        let identity = validator.identity
        let accountID = identity.scope.accountID
        let organizationID = identity.scope.organizationID
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard identity == Self.requestIdentity(
            scope: identity.scope,
            candidate: candidate,
            requestKey: identity.requestKey
        ),
              Self.isValidRequestKey(identity.requestKey, candidate: candidate, pageIndex: 1)
        else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        return try await vault.writeTransaction { database in
            try Self.requireCandidateScope(
                candidate,
                accountID: accountID,
                organizationID: organizationID,
                in: database
            )
            guard let currentValidator = try ConditionalRequestCacheRepository.validator(
                for: identity,
                expectedAccountID: accountID,
                in: database
            ), currentValidator == validator,
                  let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, account_id, organization_id, github_node_id, feature,
                               stream_id, request_key, credential_revision, capability_revision,
                               normalized_source_revision, raw_source_revision, etag, last_modified,
                               validator_observed_at_ms, first_raw_snapshot_id, parser_version,
                               page_count, normalized_event_count, normalized_digest, completed_at_ms
                        FROM timeline_replay_receipts
                        WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
                          AND feature = ? AND stream_id = ? AND request_key = ?
                          AND credential_revision = ? AND capability_revision = ?
                        """,
                    arguments: [
                        accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                        CoverageFeature.timelines.rawValue, identity.streamID.rawValue,
                        identity.requestKey, identity.scope.credentialRevision.rawValue,
                        identity.scope.capabilityRevision.rawValue
                    ]
                  )
            else {
                return false
            }
            guard let receiptID: String = row["id"],
                  receiptID == Self.replayReceiptID(for: identity, nodeID: candidate.nodeID),
                  (row["account_id"] as String?) == accountID.rawValue,
                  (row["organization_id"] as String?) == organizationID.rawValue,
                  (row["github_node_id"] as String?) == candidate.nodeID.rawValue,
                  (row["feature"] as String?) == CoverageFeature.timelines.rawValue,
                  (row["stream_id"] as String?) == identity.streamID.rawValue,
                  (row["request_key"] as String?) == identity.requestKey,
                  (row["credential_revision"] as String?) == identity.scope.credentialRevision.rawValue,
                  (row["capability_revision"] as String?) == identity.scope.capabilityRevision.rawValue,
                  let normalizedSourceRevision: String = row["normalized_source_revision"],
                  !normalizedSourceRevision.isEmpty,
                  normalizedSourceRevision.count <= 500,
                  let rawSourceRevision: String = row["raw_source_revision"],
                  !rawSourceRevision.isEmpty,
                  rawSourceRevision.count <= 500,
                  let validatorObservedAtMilliseconds: Int64 = row["validator_observed_at_ms"],
                  validatorObservedAtMilliseconds == Self.milliseconds(validator.observedAt),
                  let firstRawSnapshotID = RawAPISnapshotID(rawValue: row["first_raw_snapshot_id"]),
                  let parserVersion: Int = row["parser_version"],
                  parserVersion == 1,
                  let pageCount: Int = row["page_count"],
                  pageCount > 0,
                  pageCount <= 100,
                  let normalizedEventCount: Int = row["normalized_event_count"],
                  normalizedEventCount >= 0,
                  let normalizedDigest: Data = row["normalized_digest"],
                  normalizedDigest.count == SHA256.Digest.byteCount,
                  let completedAtMilliseconds: Int64 = row["completed_at_ms"],
                  completedAtMilliseconds >= 0
            else {
                return false
            }
            let receiptETag: String? = row["etag"]
            let receiptLastModified: String? = row["last_modified"]
            guard Self.validHeaderValidator(receiptETag),
                  Self.validHeaderValidator(receiptLastModified),
                  receiptETag != nil || receiptLastModified != nil,
                  receiptETag == validator.eTag,
                  receiptLastModified == validator.lastModified
            else {
                return false
            }
            let pageRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT page_index, raw_snapshot_id
                    FROM timeline_replay_receipt_pages
                    WHERE receipt_id = ?
                    ORDER BY page_index
                    """,
                arguments: [receiptID]
            )
            guard pageRows.count == pageCount else { return false }
            var pageSnapshotIDs = [RawAPISnapshotID]()
            pageSnapshotIDs.reserveCapacity(pageCount)
            for (offset, pageRow) in pageRows.enumerated() {
                try Task.checkCancellation()
                guard let pageIndex: Int = pageRow["page_index"],
                      pageIndex == offset + 1,
                      let snapshotID = RawAPISnapshotID(rawValue: pageRow["raw_snapshot_id"])
                else {
                    return false
                }
                pageSnapshotIDs.append(snapshotID)
            }
            guard pageSnapshotIDs.first == firstRawSnapshotID,
                  try Self.rawPagesAreValid(
                    pageSnapshotIDs,
                    rawSourceRevision: rawSourceRevision,
                    validator: validator,
                    candidate: candidate,
                    in: database
                  ),
                  try Self.completedShardExists(
                    streamID: identity.streamID,
                    sourceRevision: normalizedSourceRevision,
                    in: database
                  ),
                  let normalizedState = try Self.normalizedStateDigest(
                    nodeID: candidate.nodeID,
                    expectedSourceRevision: normalizedSourceRevision,
                    in: database
                  ),
                  normalizedState.count == normalizedEventCount,
                  normalizedState.digest == normalizedDigest
            else {
                return false
            }
            try Task.checkCancellation()
            try database.execute(
                sql: """
                    UPDATE timeline_events
                    SET source_revision = ?
                    WHERE subject_node_id = ? AND source_revision = ?
                    """,
                arguments: [
                    candidate.sourceRevision, candidate.nodeID.rawValue, normalizedSourceRevision
                ]
            )
            try TimelineCandidateRepository.completeDownloadedTimeline(
                for: candidate,
                accountID: accountID,
                organizationID: organizationID,
                completedAt: observedAt,
                in: database
            )
            let refreshedValidator = ConditionalRequestValidator(
                identity: identity,
                eTag: validator.eTag,
                lastModified: validator.lastModified,
                observedAt: observedAt
            )
            try ConditionalRequestCacheRepository.save(
                refreshedValidator,
                expectedAccountID: accountID,
                in: database
            )
            try database.execute(
                sql: """
                    UPDATE timeline_replay_receipts
                    SET normalized_source_revision = ?, validator_observed_at_ms = ?,
                        completed_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    candidate.sourceRevision, Self.milliseconds(observedAt),
                    Self.milliseconds(observedAt), receiptID
                ]
            )
            guard database.changesCount == 1 else {
                throw TimelineEventRepositoryError.invalidPersistedPage(nil)
            }
            return true
        }
    }

    /// Makes a complete staged traversal visible as the one current page set.
    /// The caller's surrounding database write also contains normalized rows,
    /// coverage, relation reconciliation, cursor completion, and replay state.
    private nonisolated static func publishStagedMembership(
        candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws -> [TimelineRawPageProvenance] {
        let streamID = SyncStreamID(rawValue: "timeline:\(candidate.nodeID.rawValue)")!
        let stagedCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM timeline_staged_pages
                WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
                  AND feature = ? AND stream_id = ?
                """,
            arguments: [
                accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                CoverageFeature.timelines.rawValue, streamID.rawValue
            ]
        ) ?? 0
        let source = stagedCount > 0 ? "timeline_staged_pages" : "timeline_current_pages"
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT raw_api_snapshots.id, raw_api_snapshots.account_id, raw_api_snapshots.github_node_id,
                       raw_api_snapshots.endpoint, raw_api_snapshots.etag, raw_api_snapshots.last_modified,
                       raw_api_snapshots.authority_organization_id, raw_api_snapshots.authority_feature,
                       raw_api_snapshots.authority_stream_id, raw_api_snapshots.authority_request_key,
                       raw_api_snapshots.authority_credential_revision,
                       raw_api_snapshots.authority_capability_revision, raw_api_snapshots.parser_version,
                       raw_api_snapshots.observed_at_ms, raw_api_snapshots.payload,
                       \(source).page_index AS page_index, \(source).request_key AS request_key,
                       \(source).credential_revision AS membership_credential_revision,
                       \(source).capability_revision AS membership_capability_revision,
                       \(source).observed_at_ms AS membership_observed_at_ms,
                       \(source).is_terminal AS is_terminal
                FROM \(source)
                JOIN raw_api_snapshots ON raw_api_snapshots.id = \(source).raw_snapshot_id
                WHERE \(source).account_id = ? AND \(source).organization_id = ?
                  AND \(source).github_node_id = ? AND \(source).feature = ?
                  AND \(source).stream_id = ? AND \(source).source_revision = ?
                ORDER BY \(source).page_index
                """,
            arguments: [
                accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                CoverageFeature.timelines.rawValue, streamID.rawValue, candidate.sourceRevision
            ]
        )
        guard !rows.isEmpty, rows.count <= 100 else {
            throw TimelineEventRepositoryError.invalidPersistedPage(nil)
        }
        var provenances = [TimelineRawPageProvenance]()
        provenances.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() {
            try Task.checkCancellation()
            let snapshot = try RawAPISnapshotRepository.snapshot(from: row)
            guard let pageIndex: Int = row["page_index"],
                  let requestKey: String = row["request_key"],
                  let membershipCredentialRevision: String = row["membership_credential_revision"],
                  let membershipCapabilityRevision: String = row["membership_capability_revision"],
                  let membershipObservedAt: Int64 = row["membership_observed_at_ms"],
                  let terminal: Int = row["is_terminal"],
                  let identity = snapshot.requestIdentity,
                  pageIndex == offset + 1,
                  terminal == (offset == rows.count - 1 ? 1 : 0),
                  snapshot.githubNodeID == candidate.nodeID,
                  snapshot.endpoint == snapshotEndpoint(for: candidate, pageIndex: pageIndex),
                  snapshot.parserVersion == 1,
                  snapshot.payload.count <= maximumRawPageBytes,
                  membershipObservedAt == milliseconds(snapshot.observedAt),
                  identity.scope.accountID == accountID,
                  identity.scope.organizationID == organizationID,
                  identity.scope.credentialRevision.rawValue == membershipCredentialRevision,
                  identity.scope.capabilityRevision.rawValue == membershipCapabilityRevision,
                  identity == requestIdentity(scope: identity.scope, candidate: candidate, requestKey: requestKey),
                  isValidRequestKey(requestKey, candidate: candidate, pageIndex: pageIndex)
            else {
                throw TimelineEventRepositoryError.invalidPersistedPage(nil)
            }
            let failureCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM normalization_failures WHERE raw_snapshot_id = ?",
                arguments: [snapshot.id.rawValue]
            ) ?? 0
            guard failureCount == 0 else { throw TimelineEventRepositoryError.invalidPersistedPage(nil) }
            provenances.append(.init(
                snapshotID: snapshot.id, endpoint: snapshot.endpoint, requestKey: requestKey,
                parserVersion: snapshot.parserVersion, observedAt: snapshot.observedAt
            ))
        }
        guard source == "timeline_staged_pages" else { return provenances }
        try database.execute(
            sql: """
                DELETE FROM timeline_current_pages
                WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
                  AND feature = ? AND stream_id = ?
                """,
            arguments: [accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                        CoverageFeature.timelines.rawValue, streamID.rawValue]
        )
        try database.execute(sql: """
            INSERT INTO timeline_current_pages (
                account_id, organization_id, github_node_id, feature, stream_id,
                credential_revision, capability_revision, source_revision, page_index,
                raw_snapshot_id, request_key, observed_at_ms, is_terminal
            )
            SELECT account_id, organization_id, github_node_id, feature, stream_id,
                   credential_revision, capability_revision, source_revision, page_index,
                   raw_snapshot_id, request_key, observed_at_ms, is_terminal
            FROM timeline_staged_pages
            WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
              AND feature = ? AND stream_id = ? AND source_revision = ?
            """, arguments: [accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                               CoverageFeature.timelines.rawValue, streamID.rawValue, candidate.sourceRevision])
        guard database.changesCount == rows.count else {
            throw TimelineEventRepositoryError.invalidPersistedPage(nil)
        }
        try database.execute(
            sql: """
                DELETE FROM timeline_staged_pages
                WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
                  AND feature = ? AND stream_id = ?
                """,
            arguments: [accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                        CoverageFeature.timelines.rawValue, streamID.rawValue]
        )
        return provenances
    }

    private nonisolated static func saveReplayReceipt(
        _ input: TimelineReplayReceiptInput,
        candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        completedAt: Date,
        in database: Database
    ) throws {
        let identity = input.validator.identity
        guard input.rawSourceRevision == candidate.sourceRevision,
              identity.scope.accountID == accountID,
              identity.scope.organizationID == organizationID,
              identity.feature == .timelines,
              identity.streamID == SyncStreamID(rawValue: "timeline:\(candidate.nodeID.rawValue)"),
              isValidRequestKey(identity.requestKey, candidate: candidate, pageIndex: 1),
              !input.pages.isEmpty,
              input.pages.count <= 100,
              input.pages.enumerated().allSatisfy({ offset, page in
                  page.parserVersion == 1
                      && page.endpoint == snapshotEndpoint(
                        for: candidate,
                        pageIndex: offset + 1
                      )
              }),
              try rawPagesAreValid(
                input.pages.map(\.snapshotID),
                rawSourceRevision: input.rawSourceRevision,
                validator: input.validator,
                candidate: candidate,
                in: database
              ),
              try completedShardExists(
                streamID: identity.streamID,
                sourceRevision: candidate.sourceRevision,
                in: database
              ),
              let normalizedState = try normalizedStateDigest(
                nodeID: candidate.nodeID,
                expectedSourceRevision: candidate.sourceRevision,
                in: database
              )
        else {
            throw TimelineEventRepositoryError.invalidPersistedPage(nil)
        }
        let receiptID = replayReceiptID(for: identity, nodeID: candidate.nodeID)
        try database.execute(
            sql: """
                DELETE FROM timeline_replay_receipts
                WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
                  AND feature = ? AND stream_id = ? AND request_key = ?
                """,
            arguments: [
                accountID.rawValue, organizationID.rawValue, candidate.nodeID.rawValue,
                CoverageFeature.timelines.rawValue, identity.streamID.rawValue,
                identity.requestKey
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO timeline_replay_receipts (
                    id, account_id, organization_id, github_node_id, feature, stream_id,
                    request_key, credential_revision, capability_revision,
                    normalized_source_revision, raw_source_revision, etag, last_modified,
                    validator_observed_at_ms, first_raw_snapshot_id, parser_version,
                    page_count, normalized_event_count, normalized_digest, completed_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                receiptID, accountID.rawValue, organizationID.rawValue,
                candidate.nodeID.rawValue, CoverageFeature.timelines.rawValue,
                identity.streamID.rawValue, identity.requestKey,
                identity.scope.credentialRevision.rawValue,
                identity.scope.capabilityRevision.rawValue, candidate.sourceRevision,
                input.rawSourceRevision, input.validator.eTag, input.validator.lastModified,
                milliseconds(input.validator.observedAt), input.pages[0].snapshotID.rawValue,
                1, input.pages.count, normalizedState.count, normalizedState.digest,
                milliseconds(completedAt)
            ]
        )
        for (offset, page) in input.pages.enumerated() {
            try database.execute(
                sql: """
                    INSERT INTO timeline_replay_receipt_pages (
                        receipt_id, page_index, raw_snapshot_id
                    ) VALUES (?, ?, ?)
                    """,
                arguments: [receiptID, offset + 1, page.snapshotID.rawValue]
            )
        }
    }

    private nonisolated static func removeReplayReceipt(
        for identity: ConditionalRequestIdentity,
        githubNodeID: GitHubNodeID,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                DELETE FROM timeline_replay_receipts
                WHERE account_id = ? AND organization_id = ? AND github_node_id = ?
                  AND feature = ? AND stream_id = ? AND request_key = ?
                """,
            arguments: [
                identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue,
                githubNodeID.rawValue, identity.feature.rawValue, identity.streamID.rawValue,
                identity.requestKey
            ]
        )
    }

    private nonisolated static func rawPagesAreValid(
        _ expectedSnapshotIDs: [RawAPISnapshotID],
        rawSourceRevision: String,
        validator: ConditionalRequestValidator,
        candidate: TimelineCandidate,
        in database: Database
    ) throws -> Bool {
        guard !expectedSnapshotIDs.isEmpty,
              expectedSnapshotIDs.count <= 100,
              Set(expectedSnapshotIDs).count == expectedSnapshotIDs.count,
              rawSourceRevision.count <= 500
        else {
            return false
        }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT raw_api_snapshots.id, raw_api_snapshots.account_id,
                       raw_api_snapshots.github_node_id, raw_api_snapshots.endpoint,
                       raw_api_snapshots.etag, raw_api_snapshots.last_modified,
                       raw_api_snapshots.authority_organization_id,
                       raw_api_snapshots.authority_feature,
                       raw_api_snapshots.authority_stream_id,
                       raw_api_snapshots.authority_request_key,
                       raw_api_snapshots.authority_credential_revision,
                       raw_api_snapshots.authority_capability_revision,
                       raw_api_snapshots.parser_version,
                       raw_api_snapshots.observed_at_ms, raw_api_snapshots.payload
                       , timeline_current_pages.page_index AS page_index,
                         timeline_current_pages.is_terminal AS is_terminal
                FROM timeline_current_pages
                JOIN raw_api_snapshots
                  ON raw_api_snapshots.id = timeline_current_pages.raw_snapshot_id
                WHERE timeline_current_pages.account_id = ?
                  AND timeline_current_pages.organization_id = ?
                  AND timeline_current_pages.github_node_id = ?
                  AND timeline_current_pages.feature = ?
                  AND timeline_current_pages.stream_id = ?
                  AND timeline_current_pages.credential_revision = ?
                  AND timeline_current_pages.capability_revision = ?
                  AND timeline_current_pages.source_revision = ?
                  AND NOT EXISTS (
                      SELECT 1
                      FROM normalization_failures
                      WHERE normalization_failures.raw_snapshot_id = raw_api_snapshots.id
                  )
                ORDER BY timeline_current_pages.page_index
                """,
            arguments: [
                validator.identity.scope.accountID.rawValue,
                validator.identity.scope.organizationID.rawValue,
                candidate.nodeID.rawValue, CoverageFeature.timelines.rawValue,
                validator.identity.streamID.rawValue,
                validator.identity.scope.credentialRevision.rawValue,
                validator.identity.scope.capabilityRevision.rawValue,
                rawSourceRevision
            ]
        )
        var decoded = [RawAPISnapshot]()
        decoded.reserveCapacity(rows.count)
        do {
            for row in rows {
                try Task.checkCancellation()
                decoded.append(try RawAPISnapshotRepository.snapshot(from: row))
            }
        } catch is RawAPISnapshotRepositoryError {
            return false
        }
        guard decoded.count == expectedSnapshotIDs.count else { return false }
        let prefix = snapshotEndpointPrefix(
            nodeID: candidate.nodeID, sourceRevision: rawSourceRevision,
            repository: candidate.repository, number: candidate.number
        )
        for (offset, snapshot) in decoded.enumerated() {
            try Task.checkCancellation()
            let pageIndex = offset + 1
            guard (rows[offset]["page_index"] as Int?) == pageIndex,
                  (rows[offset]["is_terminal"] as Int?) == (offset == decoded.count - 1 ? 1 : 0),
                  snapshot.id == expectedSnapshotIDs[offset],
                  snapshot.githubNodeID == candidate.nodeID,
                  snapshot.endpoint == prefix + "pending:" + String(format: "%03d", pageIndex),
                  snapshot.parserVersion == 1,
                  snapshot.payload.count <= maximumRawPageBytes,
                  snapshot.requestIdentity == requestIdentity(
                    scope: validator.identity.scope,
                    candidate: candidate,
                    requestKey: snapshot.requestIdentity?.requestKey ?? ""
                  ),
                  isValidRequestKey(
                    snapshot.requestIdentity?.requestKey ?? "",
                    candidate: candidate,
                    pageIndex: pageIndex
                  )
            else {
                return false
            }
            if pageIndex == 1 {
                guard snapshot.requestIdentity == validator.identity,
                      snapshot.eTag == validator.eTag,
                      snapshot.lastModified == validator.lastModified
                else {
                    return false
                }
            }
            let failureCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM normalization_failures WHERE raw_snapshot_id = ?",
                arguments: [snapshot.id.rawValue]
            ) ?? 0
            guard failureCount == 0 else { return false }
        }
        return true
    }

    private nonisolated static func completedShardExists(
        streamID: SyncStreamID,
        sourceRevision: String,
        in database: Database
    ) throws -> Bool {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM sync_shards
                WHERE stream_id = ? AND query_kind = ? AND state = ?
                  AND page_cursor IS NULL AND completed_at_ms IS NOT NULL
                """,
            arguments: [
                streamID.rawValue, "timeline:\(sourceRevision)",
                SyncShardState.completed.rawValue
            ]
        ) ?? 0
        return count == 1
    }

    private nonisolated static func normalizedStateDigest(
        nodeID: GitHubNodeID,
        expectedSourceRevision: String,
        in database: Database
    ) throws -> (count: Int, digest: Data)? {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT github_event_id, actor_id, kind, occurred_at_ms, payload_json,
                       source_revision
                FROM timeline_events
                WHERE subject_node_id = ?
                ORDER BY github_event_id
                """,
            arguments: [nodeID.rawValue]
        )
        var material = Data("triage.timeline.normalized.v1".utf8)
        for row in rows {
            try Task.checkCancellation()
            guard let eventID: String = row["github_event_id"],
                  let kind: String = row["kind"],
                  let occurredAtMilliseconds: Int64 = row["occurred_at_ms"],
                  let payload: Data = row["payload_json"],
                  (row["source_revision"] as String?) == expectedSourceRevision
            else {
                return nil
            }
            appendLengthPrefixed(Data(eventID.utf8), to: &material)
            if let actorID: String = row["actor_id"] {
                material.append(1)
                appendLengthPrefixed(Data(actorID.utf8), to: &material)
            } else {
                material.append(0)
            }
            appendLengthPrefixed(Data(kind.utf8), to: &material)
            appendLengthPrefixed(Data(String(occurredAtMilliseconds).utf8), to: &material)
            appendLengthPrefixed(payload, to: &material)
        }
        return (rows.count, Data(SHA256.hash(data: material)))
    }

    private nonisolated static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    private nonisolated static func replayReceiptID(
        for identity: ConditionalRequestIdentity,
        nodeID: GitHubNodeID
    ) -> String {
        let material = [
            identity.scope.accountID.rawValue,
            identity.scope.organizationID.rawValue,
            nodeID.rawValue,
            identity.feature.rawValue,
            identity.streamID.rawValue,
            identity.requestKey,
            identity.scope.credentialRevision.rawValue,
            identity.scope.capabilityRevision.rawValue
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "timeline-replay:\(digest)"
    }

    private nonisolated static func validHeaderValidator(_ value: String?) -> Bool {
        guard let value else { return true }
        guard !value.isEmpty, value.count <= 2_048 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    private nonisolated static func replace(
        _ events: [NormalizedGitHubTimelineEvent],
        candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        observedAt: Date,
        in database: Database
    ) throws {
        try requireCandidateScope(
            candidate,
            accountID: accountID,
            organizationID: organizationID,
            in: database
        )
        for event in events {
            if let subjectNodeID: String = try String.fetchOne(
                database,
                sql: "SELECT subject_node_id FROM timeline_events WHERE github_event_id = ?",
                arguments: [event.id.rawValue]
            ), subjectNodeID != candidate.nodeID.rawValue {
                throw TimelineEventRepositoryError.eventBelongsToAnotherSubject
            }
        }
        try database.execute(
            sql: "DELETE FROM timeline_events WHERE subject_node_id = ?",
            arguments: [candidate.nodeID.rawValue]
        )
        let observedAtMilliseconds = milliseconds(observedAt)
        for event in events {
            if let actor = event.actor {
                try ActorRepository.save(actor, observedAtMilliseconds: observedAtMilliseconds, in: database)
            }
            try database.execute(
                sql: """
                    INSERT INTO timeline_events (
                        github_event_id, subject_node_id, actor_id, kind, occurred_at_ms, payload_json,
                        source_revision
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    event.id.rawValue,
                    candidate.nodeID.rawValue,
                    event.actor?.id.rawValue,
                    event.kind.rawValue,
                    milliseconds(event.occurredAt),
                    event.payload,
                    candidate.sourceRevision
                ]
            )
        }
    }

    private nonisolated static func pageBoundRelationReplacements(
        from events: [NormalizedGitHubTimelineEvent],
        candidate: TimelineCandidate,
        scope: SynchronizationScope,
        pageProvenances: [TimelineRawPageProvenance],
        eventPageProvenances: [GitHubEventID: TimelineRawPageProvenance]
    ) throws -> [PageBoundRelationReplacement] {
        typealias RelationDraft = (kind: WorkRelationKind, objectNodeID: GitHubNodeID, evidence: [EvidenceReference], observedAt: Date)
        var drafts = [RawAPISnapshotID: (provenance: TimelineRawPageProvenance, relations: [String: RelationDraft])]()
        let streamID = SyncStreamID(rawValue: "timeline:\(candidate.nodeID.rawValue)")!
        guard !pageProvenances.isEmpty,
              Set(pageProvenances.map(\.snapshotID)).count == pageProvenances.count,
              Set(pageProvenances.map(\.requestKey)).count == pageProvenances.count
        else {
            throw TimelineEventRepositoryError.invalidPersistedPage(nil)
        }
        for provenance in pageProvenances {
            drafts[provenance.snapshotID] = (provenance, [:])
        }

        for event in events {
            let relationKind: WorkRelationKind
            switch event.kind {
            case .commented:
                relationKind = .commented
            case .reviewed:
                relationKind = .reviewed
            default:
                // The timeline event actor is not necessarily an assignee,
                // mentioned user, or requested reviewer. Do not infer those
                // relationships from an event that does not name its target.
                continue
            }
            guard let actor = event.actor,
                  let provenance = eventPageProvenances[event.id],
                  drafts[provenance.snapshotID] != nil
            else {
                throw TimelineEventRepositoryError.invalidPersistedPage(nil)
            }
            let evidence = EvidenceReference(
                id: EvidenceID(rawValue: "timeline-\(event.id.rawValue)")!,
                source: .restTimeline,
                locator: .query(provenance.requestKey),
                authority: .github(scope: scope, feature: .timelines, streamID: streamID),
                nodeID: candidate.nodeID,
                eventID: event.id,
                sourceRevision: candidate.sourceRevision,
                rawSnapshotID: provenance.snapshotID,
                confidence: .confirmed,
                confirmation: .confirmed,
                observedAt: event.occurredAt
            )
            let key = relationKind.rawValue + "\u{0}" + actor.nodeID.rawValue
            var pageDrafts = drafts[provenance.snapshotID] ?? (provenance, [:])
            if var draft = pageDrafts.relations[key] {
                draft.evidence.append(evidence)
                draft.observedAt = max(draft.observedAt, event.occurredAt)
                pageDrafts.relations[key] = draft
            } else {
                pageDrafts.relations[key] = (relationKind, actor.nodeID, [evidence], event.occurredAt)
            }
            drafts[provenance.snapshotID] = pageDrafts
        }

        return drafts.values
            .sorted { lhs, rhs in lhs.provenance.requestKey < rhs.provenance.requestKey }
            .map { group in
                PageBoundRelationReplacement(
                    relations: group.relations.values
                        .map { draft in
                            WorkRelation(
                                kind: draft.kind,
                                subjectNodeID: candidate.nodeID,
                                objectNodeID: draft.objectNodeID,
                                confidence: .confirmed,
                                evidence: draft.evidence.sorted { $0.id.rawValue < $1.id.rawValue },
                                observedAt: draft.observedAt
                            )
                        }
                        .sorted { lhs, rhs in
                            let lhsKey = lhs.kind.rawValue + "\u{0}" + (lhs.objectNodeID?.rawValue ?? "")
                            let rhsKey = rhs.kind.rawValue + "\u{0}" + (rhs.objectNodeID?.rawValue ?? "")
                            return lhsKey < rhsKey
                        }
                    ,
                    authority: RelationReplacementAuthority(
                        source: .restTimeline,
                        locator: .query(group.provenance.requestKey),
                        scope: scope,
                        feature: .timelines,
                        streamID: streamID,
                        repositoryID: candidate.repositoryID,
                        sourceRevision: candidate.sourceRevision,
                        rawSnapshotID: group.provenance.snapshotID,
                        observedAt: group.provenance.observedAt,
                        mode: .completeReconciliation
                    )
                )
            }
    }

    private nonisolated static func validate(_ events: [NormalizedGitHubTimelineEvent]) throws {
        var eventIDs = Set<GitHubEventID>()
        for event in events {
            guard event.payload.count <= GitHubTimelineNormalizer.maximumEventPayloadBytes else {
                throw TimelineEventRepositoryError.invalidEventPayload
            }
            guard eventIDs.insert(event.id).inserted else {
                throw TimelineEventRepositoryError.duplicateEventID
            }
        }
    }

    private nonisolated static func requireCandidateScope(
        _ candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws {
        let matchingCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM github_nodes
                JOIN repositories ON repositories.id = github_nodes.repository_id
                WHERE github_nodes.github_node_id = ?
                  AND github_nodes.account_id = ?
                  AND github_nodes.organization_id = ?
                  AND github_nodes.accessibility_state = ?
                  AND github_nodes.number = ?
                  AND github_nodes.source_revision = ?
                  AND repositories.id = ?
                  AND repositories.owner_login = ?
                  AND repositories.name = ?
                  AND (
                      EXISTS (SELECT 1 FROM issues WHERE issues.github_node_id = github_nodes.github_node_id)
                      OR EXISTS (
                          SELECT 1 FROM pull_requests
                          WHERE pull_requests.github_node_id = github_nodes.github_node_id
                      )
                  )
                """,
            arguments: [
                candidate.nodeID.rawValue, accountID.rawValue, organizationID.rawValue,
                GitHubNodeAccessibility.accessible.rawValue, candidate.number, candidate.sourceRevision,
                candidate.repositoryID.rawValue, candidate.repository.owner, candidate.repository.repository
            ]
        ) ?? 0
        guard matchingCount == 1 else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
    }

    private nonisolated static func snapshotID(
        for candidate: TimelineCandidate,
        pageIndex: Int,
        requestIdentity: ConditionalRequestIdentity,
        observedAt: Date,
        payload: Data
    ) -> RawAPISnapshotID {
        let payloadDigest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let material = [
            candidate.nodeID.rawValue,
            candidate.sourceRevision,
            String(pageIndex),
            requestIdentity.scope.credentialRevision.rawValue,
            requestIdentity.scope.capabilityRevision.rawValue,
            requestIdentity.requestKey,
            String(milliseconds(observedAt)),
            payloadDigest
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return RawAPISnapshotID(rawValue: "timeline:\(digest)")!
    }

    private nonisolated static func snapshotEndpoint(
        for candidate: TimelineCandidate,
        pageIndex: Int
    ) -> String {
        pendingSnapshotEndpoint(for: candidate, pageIndex: pageIndex)
    }

    private nonisolated static func pendingSnapshotEndpoint(
        for candidate: TimelineCandidate,
        pageIndex: Int
    ) -> String {
        snapshotEndpointPrefix(for: candidate) + "pending:" + String(format: "%03d", pageIndex)
    }

    private nonisolated static func committedSnapshotEndpoint(
        for candidate: TimelineCandidate,
        pageIndex: Int
    ) -> String {
        snapshotEndpointPrefix(for: candidate) + String(format: "%03d", pageIndex)
    }

    private nonisolated static func snapshotEndpointPrefix(for candidate: TimelineCandidate) -> String {
        snapshotEndpointPrefix(
            nodeID: candidate.nodeID,
            sourceRevision: candidate.sourceRevision,
            repository: candidate.repository,
            number: candidate.number
        )
    }

    private nonisolated static func snapshotEndpointPrefix(
        nodeID: GitHubNodeID,
        sourceRevision: String,
        repository: GitHubRepositoryPath,
        number: Int
    ) -> String {
        let material = "\(nodeID.rawValue)|\(sourceRevision)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "GET \(repository.path)/issues/\(number)/timeline#\(digest):"
    }

    private nonisolated static func requestIdentity(
        scope: SynchronizationScope,
        candidate: TimelineCandidate,
        requestKey: String
    ) -> ConditionalRequestIdentity {
        ConditionalRequestIdentity(
            scope: scope,
            feature: .timelines,
            streamID: SyncStreamID(rawValue: "timeline:\(candidate.nodeID.rawValue)")!,
            requestKey: requestKey
        )
    }

    private nonisolated static func isValidRequestKey(
        _ requestKey: String,
        candidate: TimelineCandidate,
        pageIndex: Int
    ) -> Bool {
        let prefix = "GET "
        guard requestKey.hasPrefix(prefix),
              let components = URLComponents(
                string: "https://api.github.com" + String(requestKey.dropFirst(prefix.count))
              ),
              components.scheme == "https",
              components.host == "api.github.com",
              components.path == "\(candidate.repository.path)/issues/\(candidate.number)/timeline",
              components.fragment == nil
        else {
            return false
        }
        let items = components.queryItems ?? []
        let allowedNames: Set<String> = ["page", "per_page"]
        let perPage = items.first(where: { $0.name == "per_page" })?.value.flatMap(Int.init) ?? 100
        guard !items.isEmpty,
              Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ allowedNames.contains($0.name) }),
              let page = items.first(where: { $0.name == "page" })?.value.flatMap(Int.init),
              page == pageIndex,
              perPage > 0,
              perPage <= 100
        else {
            return false
        }
        return true
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
