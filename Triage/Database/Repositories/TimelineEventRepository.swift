import CryptoKit
import Foundation
import GRDB

enum TimelineEventRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case candidateScopeMismatch
    case invalidRawPage
    case invalidPersistedPage
    case invalidEventPayload
    case duplicateEventID
    case eventBelongsToAnotherSubject
}

struct TimelineSavedPageInventory: Sendable {
    let events: [GitHubTimelineEventDTO]
    let pageCount: Int
    let firstPageETag: String?
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
    ) async throws {
        guard accountID == vault.accountID else {
            throw TimelineEventRepositoryError.accountScopeMismatch
        }
        guard candidate.sourceRevision.count <= 500 else {
            throw TimelineEventRepositoryError.candidateScopeMismatch
        }
        guard pageIndex > 0, pageIndex <= 100, page.payload.count <= Self.maximumRawPageBytes else {
            throw TimelineEventRepositoryError.invalidRawPage
        }
        try await vault.write { database in
            try Self.requireCandidateScope(
                candidate,
                accountID: accountID,
                organizationID: organizationID,
                in: database
            )
            try RawAPISnapshotRepository.save(
                RawAPISnapshot(
                    id: Self.snapshotID(for: candidate, pageIndex: pageIndex),
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
                    SELECT endpoint, etag, payload
                    FROM raw_api_snapshots
                    WHERE account_id = ? AND github_node_id = ? AND endpoint LIKE ?
                    ORDER BY endpoint ASC
                    """,
                arguments: [
                    accountID.rawValue,
                    candidate.nodeID.rawValue,
                    Self.snapshotEndpointPrefix(for: candidate) + "%"
                ]
            )
            let prefix = Self.snapshotEndpointPrefix(for: candidate)
            let matching = snapshots.filter { ($0["endpoint"] as String?)?.hasPrefix(prefix) == true }
            guard !matching.isEmpty, matching.count <= 100 else {
                throw TimelineEventRepositoryError.invalidPersistedPage
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let events = try matching.flatMap { row in
                guard let payload: Data = row["payload"], payload.count <= Self.maximumRawPageBytes else {
                    throw TimelineEventRepositoryError.invalidPersistedPage
                }
                do {
                    return try decoder.decode([GitHubTimelineEventDTO].self, from: payload)
                } catch is DecodingError {
                    throw TimelineEventRepositoryError.invalidPersistedPage
                }
            }
            return TimelineSavedPageInventory(
                events: events,
                pageCount: matching.count,
                firstPageETag: matching.first?["etag"]
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
            try Self.requireCandidateScope(
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
            let observedAtMilliseconds = Self.milliseconds(observedAt)
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
                        Self.milliseconds(event.occurredAt),
                        event.payload,
                        candidate.sourceRevision
                    ]
                )
            }
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
        pageIndex: Int
    ) -> RawAPISnapshotID {
        let material = "\(candidate.nodeID.rawValue)|\(candidate.sourceRevision)|\(pageIndex)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return RawAPISnapshotID(rawValue: "timeline:\(digest)")!
    }

    private nonisolated static func snapshotEndpoint(
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
