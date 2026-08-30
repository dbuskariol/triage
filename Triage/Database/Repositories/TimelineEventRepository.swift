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
    let latestPageProvenance: TimelineRawPageProvenance
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
        accountID: AccountID,
        organizationID: OrganizationID,
        observedAt: Date
    ) async throws -> RawAPISnapshotID {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500 else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        guard pageIndex > 0, pageIndex <= 100, page.payload.count <= Self.maximumRawPageBytes else {
            throw TimelineEventRepositoryError.invalidRawPage
        }
        let snapshotID = Self.snapshotID(
            for: candidate,
            pageIndex: pageIndex,
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
                    parserVersion: 1,
                    observedAt: observedAt,
                    payload: page.payload
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
        accountID: AccountID,
        organizationID: OrganizationID,
        observedAt: Date,
        redactedDiagnostic: String
    ) async throws -> RawAPISnapshotID {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500 else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        guard pageIndex > 0, pageIndex <= 100, page.payload.count <= Self.maximumRawPageBytes else {
            throw TimelineEventRepositoryError.invalidRawPage
        }
        let snapshotID = Self.snapshotID(
            for: candidate,
            pageIndex: pageIndex,
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
                    parserVersion: 1,
                    observedAt: observedAt,
                    payload: page.payload
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
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> TimelineSavedPageInventory {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500 else {
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
                    SELECT id, endpoint, etag, parser_version, payload
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
            let matching = snapshots.filter { row in
                guard let endpoint: String = row["endpoint"], endpoint.hasPrefix(prefix) else {
                    return false
                }
                let pageIndex = endpoint.dropFirst(prefix.count)
                return pageIndex.count == 3 && Int(pageIndex) != nil
            }
            guard !matching.isEmpty, matching.count <= 100 else {
                throw TimelineEventRepositoryError.invalidPersistedPage(nil)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persistedPages = try matching.map { row -> (TimelineRawPageProvenance, Data) in
                guard let rawSnapshotID: String = row["id"],
                      let snapshotID = RawAPISnapshotID(rawValue: rawSnapshotID),
                      let endpoint: String = row["endpoint"],
                      let parserVersion: Int = row["parser_version"],
                      parserVersion > 0,
                      let payload: Data = row["payload"],
                      payload.count <= Self.maximumRawPageBytes
                else {
                    throw TimelineEventRepositoryError.invalidPersistedPage(nil)
                }
                return (
                    TimelineRawPageProvenance(
                        snapshotID: snapshotID,
                        endpoint: endpoint,
                        parserVersion: parserVersion
                    ),
                    payload
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
                firstPageETag: matching.first?["etag"],
                latestPageProvenance: persistedPages[persistedPages.count - 1].0
            )
        }
    }

    func commitValidatedRawPage(
        _ snapshotID: RawAPISnapshotID,
        candidate: TimelineCandidate,
        pageIndex: Int,
        nextPageURL: URL?,
        accountID: AccountID,
        organizationID: OrganizationID,
        attemptedAt: Date
    ) async throws {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500 else {
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
        conditionalRequestCacheMutation: ConditionalRequestCacheMutation? = nil
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
            try TimelineCandidateRepository.completeDownloadedTimeline(
                for: candidate,
                accountID: accountID,
                organizationID: organizationID,
                completedAt: observedAt,
                in: database
            )
            switch conditionalRequestCacheMutation {
            case let .save(validator):
                try ConditionalRequestCacheRepository.save(
                    validator,
                    expectedAccountID: accountID,
                    in: database
                )
            case let .remove(identity):
                try ConditionalRequestCacheRepository.remove(
                    for: identity,
                    expectedAccountID: accountID,
                    in: database
                )
            case nil:
                break
            }
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
        payload: Data
    ) -> RawAPISnapshotID {
        let payloadDigest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let material = "\(candidate.nodeID.rawValue)|\(candidate.sourceRevision)|\(pageIndex)|\(payloadDigest)"
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
        let material = "\(candidate.nodeID.rawValue)|\(candidate.sourceRevision)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "GET \(candidate.repository.path)/issues/\(candidate.number)/timeline#\(digest):"
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
