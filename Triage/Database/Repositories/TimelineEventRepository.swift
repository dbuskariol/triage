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
    let parserVersion: Int
}

struct TimelineSavedPageInventory: Sendable {
    let events: [GitHubTimelineEventDTO]
    let pageCount: Int
    let firstPageETag: String?
    let firstPageLastModified: String?
    let pageProvenances: [TimelineRawPageProvenance]
    let latestPageProvenance: TimelineRawPageProvenance
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
            let snapshots = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, account_id, github_node_id, endpoint, etag, last_modified,
                           authority_organization_id, authority_feature, authority_stream_id,
                           authority_request_key, authority_credential_revision,
                           authority_capability_revision, parser_version, observed_at_ms, payload
                    FROM raw_api_snapshots
                    WHERE account_id = ? AND github_node_id = ? AND endpoint LIKE ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM normalization_failures
                          WHERE normalization_failures.raw_snapshot_id = raw_api_snapshots.id
                      )
                    ORDER BY endpoint ASC
                    """,
                arguments: [
                    accountID.rawValue,
                    candidate.nodeID.rawValue,
                    Self.snapshotEndpointPrefix(for: candidate) + "%"
                ]
            )
            let prefix = Self.snapshotEndpointPrefix(for: candidate)
            let matching = try snapshots.compactMap { row -> RawAPISnapshot? in
                let snapshot = try RawAPISnapshotRepository.snapshot(from: row)
                guard snapshot.endpoint.hasPrefix(prefix) else {
                    return nil
                }
                let pageIndex = snapshot.endpoint.dropFirst(prefix.count)
                return pageIndex.count == 3 && Int(pageIndex) != nil ? snapshot : nil
            }
            guard !matching.isEmpty, matching.count <= 100 else {
                throw TimelineEventRepositoryError.invalidPersistedPage(nil)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persistedPages = try matching.enumerated().map {
                offset, snapshot -> (TimelineRawPageProvenance, Data) in
                let pageIndex = offset + 1
                guard snapshot.endpoint == Self.committedSnapshotEndpoint(
                    for: candidate,
                    pageIndex: pageIndex
                ),
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
                        parserVersion: snapshot.parserVersion
                    ),
                    snapshot.payload
                )
            }
            let events = try persistedPages.flatMap { provenance, payload in
                do {
                    return try decoder.decode([GitHubTimelineEventDTO].self, from: payload)
                } catch is DecodingError {
                    throw TimelineEventRepositoryError.invalidPersistedPage(provenance)
                }
            }
            return TimelineSavedPageInventory(
                events: events,
                pageCount: matching.count,
                firstPageETag: matching.first?.eTag,
                firstPageLastModified: matching.first?.lastModified,
                pageProvenances: persistedPages.map(\.0),
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
                  snapshot.endpoint == Self.pendingSnapshotEndpoint(
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
            try database.execute(
                sql: """
                    DELETE FROM raw_api_snapshots
                    WHERE account_id = ?
                      AND github_node_id = ?
                      AND endpoint = ?
                      AND id <> ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM normalization_failures
                          WHERE normalization_failures.raw_snapshot_id = raw_api_snapshots.id
                      )
                    """,
                arguments: [
                    accountID.rawValue,
                    candidate.nodeID.rawValue,
                    Self.committedSnapshotEndpoint(for: candidate, pageIndex: pageIndex),
                    snapshotID.rawValue
                ]
            )
            try database.execute(
                sql: """
                    UPDATE raw_api_snapshots
                    SET endpoint = ?
                    WHERE id = ? AND account_id = ? AND endpoint = ?
                    """,
                arguments: [
                    Self.committedSnapshotEndpoint(for: candidate, pageIndex: pageIndex),
                    snapshotID.rawValue,
                    accountID.rawValue,
                    Self.pendingSnapshotEndpoint(for: candidate, pageIndex: pageIndex)
                ]
            )
            guard database.changesCount == 1 else {
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
        conditionalRequestCacheMutation: ConditionalRequestCacheMutation? = nil,
        replayReceipt: TimelineReplayReceiptInput? = nil
    ) async throws {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500 else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        try Self.validate(events)
        try await vault.writeTransaction { database in
            try Task.checkCancellation()
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
                      && page.endpoint == committedSnapshotEndpoint(
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
        let prefix = snapshotEndpointPrefix(
            nodeID: candidate.nodeID,
            sourceRevision: rawSourceRevision,
            repository: candidate.repository,
            number: candidate.number
        )
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, account_id, github_node_id, endpoint, etag, last_modified,
                       authority_organization_id, authority_feature, authority_stream_id,
                       authority_request_key, authority_credential_revision,
                       authority_capability_revision, parser_version, observed_at_ms, payload
                FROM raw_api_snapshots
                WHERE account_id = ? AND github_node_id = ? AND endpoint LIKE ?
                  AND NOT EXISTS (
                      SELECT 1
                      FROM normalization_failures
                      WHERE normalization_failures.raw_snapshot_id = raw_api_snapshots.id
                  )
                ORDER BY endpoint
                """,
            arguments: [
                validator.identity.scope.accountID.rawValue,
                candidate.nodeID.rawValue,
                prefix + "%"
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
        let committed = decoded.filter { snapshot in
            guard snapshot.endpoint.hasPrefix(prefix) else { return false }
            let suffix = snapshot.endpoint.dropFirst(prefix.count)
            return suffix.count == 3 && suffix.allSatisfy(\.isNumber)
        }
        guard committed.count == expectedSnapshotIDs.count else { return false }
        for (offset, snapshot) in committed.enumerated() {
            try Task.checkCancellation()
            let pageIndex = offset + 1
            guard snapshot.id == expectedSnapshotIDs[offset],
                  snapshot.githubNodeID == candidate.nodeID,
                  snapshot.endpoint == prefix + String(format: "%03d", pageIndex),
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
