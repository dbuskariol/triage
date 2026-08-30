import CryptoKit
import Foundation
import GRDB

enum TimelineCandidateRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case invalidLimit
    case invalidCandidate
    case invalidPersistedCandidate
    case invalidCheckpoint
    case checkpointScopeMismatch
}

struct TimelineCandidate: Sendable {
    let nodeID: GitHubNodeID
    let repositoryID: RepositoryID
    let repository: GitHubRepositoryPath
    let number: Int
    let sourceRevision: String
}

extension TimelineCandidate: Equatable {
    static func == (lhs: TimelineCandidate, rhs: TimelineCandidate) -> Bool {
        lhs.nodeID == rhs.nodeID
            && lhs.repositoryID == rhs.repositoryID
            && lhs.repository.owner == rhs.repository.owner
            && lhs.repository.repository == rhs.repository.repository
            && lhs.number == rhs.number
            && lhs.sourceRevision == rhs.sourceRevision
    }
}

struct TimelineCandidateInventory: Sendable {
    let candidates: [TimelineCandidate]
    let hasRemainingCandidates: Bool
}

struct TimelineCheckpoint: Sendable {
    let nextPageURL: URL?
    let isDownloadComplete: Bool
}

actor TimelineCandidateRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func candidates(
        accountID: AccountID,
        organizationID: OrganizationID,
        limit: Int
    ) async throws -> TimelineCandidateInventory {
        try validateAccount(accountID)
        guard limit > 0, limit < .max else {
            throw TimelineCandidateRepositoryError.invalidLimit
        }
        return try await vault.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    WITH hydrated_candidates AS (
                        SELECT github_nodes.github_node_id, repositories.id AS repository_id,
                               repositories.owner_login, repositories.name, github_nodes.number,
                               github_nodes.source_revision, github_nodes.last_observed_at_ms
                        FROM issues
                        JOIN github_nodes ON github_nodes.github_node_id = issues.github_node_id
                        JOIN repositories ON repositories.id = github_nodes.repository_id
                        WHERE github_nodes.account_id = ?
                          AND github_nodes.organization_id = ?
                          AND github_nodes.accessibility_state = ?
                          AND github_nodes.number > 0
                        UNION ALL
                        SELECT github_nodes.github_node_id, repositories.id AS repository_id,
                               repositories.owner_login, repositories.name, github_nodes.number,
                               github_nodes.source_revision, github_nodes.last_observed_at_ms
                        FROM pull_requests
                        JOIN github_nodes ON github_nodes.github_node_id = pull_requests.github_node_id
                        JOIN repositories ON repositories.id = github_nodes.repository_id
                        WHERE github_nodes.account_id = ?
                          AND github_nodes.organization_id = ?
                          AND github_nodes.accessibility_state = ?
                          AND github_nodes.number > 0
                    )
                    SELECT hydrated_candidates.github_node_id, hydrated_candidates.repository_id,
                           hydrated_candidates.owner_login, hydrated_candidates.name,
                           hydrated_candidates.number, hydrated_candidates.source_revision
                    FROM hydrated_candidates
                    LEFT JOIN sync_shards AS completed_timeline
                      ON completed_timeline.stream_id = 'timeline:' || hydrated_candidates.github_node_id
                     AND completed_timeline.query_kind = 'timeline:' || hydrated_candidates.source_revision
                     AND completed_timeline.state = ?
                    WHERE completed_timeline.id IS NULL
                    ORDER BY hydrated_candidates.last_observed_at_ms ASC,
                             hydrated_candidates.github_node_id ASC
                    LIMIT ?
                    """,
                arguments: [
                    accountID.rawValue, organizationID.rawValue, GitHubNodeAccessibility.accessible.rawValue,
                    accountID.rawValue, organizationID.rawValue, GitHubNodeAccessibility.accessible.rawValue,
                    SyncShardState.completed.rawValue, limit + 1
                ]
            )
            let candidates = try rows.prefix(limit).map(Self.candidate)
            return TimelineCandidateInventory(
                candidates: candidates,
                hasRemainingCandidates: rows.count > limit
            )
        }
    }

    func validatedCandidates(
        _ candidates: [TimelineCandidate],
        accountID: AccountID,
        organizationID: OrganizationID,
        limit: Int
    ) async throws -> TimelineCandidateInventory {
        try validateAccount(accountID)
        guard limit > 0, limit < .max, candidates.count <= limit,
              Set(candidates.map(\.nodeID)).count == candidates.count
        else {
            throw TimelineCandidateRepositoryError.invalidLimit
        }
        let validated = try await vault.read { database in
            try candidates.map { candidate in
                let persisted = try Self.persistedCandidate(
                    nodeID: candidate.nodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    in: database
                )
                guard persisted == candidate else {
                    throw TimelineCandidateRepositoryError.invalidCandidate
                }
                return persisted
            }
        }
        return TimelineCandidateInventory(candidates: validated, hasRemainingCandidates: false)
    }

    func checkpoint(
        for candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> TimelineCheckpoint? {
        try validateAccount(accountID)
        return try await vault.read { database in
            let persisted = try Self.persistedCandidate(
                nodeID: candidate.nodeID,
                accountID: accountID,
                organizationID: organizationID,
                in: database
            )
            guard persisted == candidate else {
                throw TimelineCandidateRepositoryError.invalidCandidate
            }
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT page_cursor, state
                    FROM sync_shards
                    WHERE id = ? AND stream_id = ? AND query_kind = ?
                    """,
                arguments: [
                    Self.shardID(for: candidate).rawValue,
                    Self.streamID(for: candidate).rawValue,
                    Self.queryKind(for: candidate)
                ]
            ) else {
                return nil
            }
            guard let stateValue: String = row["state"],
                  stateValue == SyncShardState.running.rawValue || stateValue == SyncShardState.failed.rawValue
            else {
                return nil
            }
            guard let cursor: String = row["page_cursor"] else {
                if stateValue == SyncShardState.running.rawValue {
                    return TimelineCheckpoint(nextPageURL: nil, isDownloadComplete: true)
                }
                if stateValue == SyncShardState.failed.rawValue {
                    return nil
                }
                throw TimelineCandidateRepositoryError.invalidCheckpoint
            }
            guard let url = Self.validTimelineURL(cursor, candidate: candidate) else {
                throw TimelineCandidateRepositoryError.invalidCheckpoint
            }
            return TimelineCheckpoint(nextPageURL: url, isDownloadComplete: false)
        }
    }

    func saveCheckpoint(
        for candidate: TimelineCandidate,
        nextPageURL: URL,
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws {
        try validateAccount(accountID)
        guard Self.validTimelineURL(nextPageURL.absoluteString, candidate: candidate) != nil else {
            throw TimelineCandidateRepositoryError.invalidCheckpoint
        }
        try await vault.write { database in
            try Self.requireCandidate(candidate, accountID: accountID, organizationID: organizationID, in: database)
            try Self.ensureStream(for: candidate, accountID: accountID, organizationID: organizationID, in: database)
            try SyncShardRepository.save(
                SyncShard(
                    id: Self.shardID(for: candidate),
                    streamID: Self.streamID(for: candidate),
                    queryKind: Self.queryKind(for: candidate),
                    intervalStart: nil,
                    intervalEnd: nil,
                    pageCursor: nextPageURL.absoluteString,
                    state: .running,
                    completedAt: nil
                ),
                accountID: accountID,
                in: database
            )
            try Self.updateStream(
                for: candidate,
                state: .partial,
                successfulAt: nil,
                attemptedAt: Date.now,
                in: database
            )
        }
    }

    func complete(
        candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        at completedAt: Date
    ) async throws {
        try await saveState(
            .completed,
            candidate: candidate,
            cursor: nil,
            accountID: accountID,
            organizationID: organizationID,
            at: completedAt
        )
    }

    func markDownloadComplete(
        candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        at completedAt: Date
    ) async throws {
        try await saveState(
            .running,
            candidate: candidate,
            cursor: nil,
            accountID: accountID,
            organizationID: organizationID,
            at: completedAt
        )
    }

    func fail(
        candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        at failedAt: Date
    ) async throws {
        try await saveState(
            .failed,
            candidate: candidate,
            cursor: nil,
            accountID: accountID,
            organizationID: organizationID,
            at: failedAt
        )
    }

    private func saveState(
        _ state: SyncShardState,
        candidate: TimelineCandidate,
        cursor: String?,
        accountID: AccountID,
        organizationID: OrganizationID,
        at: Date
    ) async throws {
        try validateAccount(accountID)
        try await vault.write { database in
            try Self.requireCandidate(candidate, accountID: accountID, organizationID: organizationID, in: database)
            try Self.ensureStream(for: candidate, accountID: accountID, organizationID: organizationID, in: database)
            let effectiveCursor: String?
            if state == .failed {
                effectiveCursor = try String.fetchOne(
                    database,
                    sql: "SELECT page_cursor FROM sync_shards WHERE id = ?",
                    arguments: [Self.shardID(for: candidate).rawValue]
                )
            } else {
                effectiveCursor = cursor
            }
            try SyncShardRepository.save(
                SyncShard(
                    id: Self.shardID(for: candidate),
                    streamID: Self.streamID(for: candidate),
                    queryKind: Self.queryKind(for: candidate),
                    intervalStart: nil,
                    intervalEnd: nil,
                    pageCursor: effectiveCursor,
                    state: state,
                    completedAt: state == .completed ? at : nil
                ),
                accountID: accountID,
                in: database
            )
            try Self.updateStream(
                for: candidate,
                state: state == .completed ? .complete : .partial,
                successfulAt: state == .completed ? at : nil,
                attemptedAt: at,
                in: database
            )
        }
    }

    private func validateAccount(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw TimelineCandidateRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func candidate(_ row: Row) throws -> TimelineCandidate {
        guard let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
              let repositoryID = RepositoryID(rawValue: row["repository_id"]),
              let number: Int = row["number"],
              number > 0,
              let sourceRevision: String = row["source_revision"],
              !sourceRevision.isEmpty,
              sourceRevision.count <= 500
        else {
            throw TimelineCandidateRepositoryError.invalidPersistedCandidate
        }
        return TimelineCandidate(
            nodeID: nodeID,
            repositoryID: repositoryID,
            repository: try GitHubRepositoryPath(owner: row["owner_login"], repository: row["name"]),
            number: number,
            sourceRevision: sourceRevision
        )
    }

    private nonisolated static func persistedCandidate(
        nodeID: GitHubNodeID,
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws -> TimelineCandidate {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT github_nodes.github_node_id, repositories.id AS repository_id, repositories.owner_login,
                       repositories.name, github_nodes.number, github_nodes.source_revision
                FROM github_nodes
                JOIN repositories ON repositories.id = github_nodes.repository_id
                WHERE github_nodes.github_node_id = ?
                  AND github_nodes.account_id = ?
                  AND github_nodes.organization_id = ?
                  AND github_nodes.accessibility_state = ?
                  AND github_nodes.number > 0
                  AND (
                      EXISTS (SELECT 1 FROM issues WHERE issues.github_node_id = github_nodes.github_node_id)
                      OR EXISTS (
                          SELECT 1 FROM pull_requests
                          WHERE pull_requests.github_node_id = github_nodes.github_node_id
                      )
                  )
                """,
            arguments: [
                nodeID.rawValue, accountID.rawValue, organizationID.rawValue,
                GitHubNodeAccessibility.accessible.rawValue
            ]
        ) else {
            throw TimelineCandidateRepositoryError.invalidCandidate
        }
        return try candidate(row)
    }

    private nonisolated static func requireCandidate(
        _ candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws {
        guard try persistedCandidate(
            nodeID: candidate.nodeID,
            accountID: accountID,
            organizationID: organizationID,
            in: database
        ) == candidate else {
            throw TimelineCandidateRepositoryError.invalidCandidate
        }
    }

    private nonisolated static func ensureStream(
        for candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws {
        let streamID = streamID(for: candidate)
        if let row = try Row.fetchOne(
            database,
            sql: "SELECT account_id, organization_id, feature FROM sync_streams WHERE id = ?",
            arguments: [streamID.rawValue]
        ) {
            guard (row["account_id"] as String?) == accountID.rawValue,
                  (row["organization_id"] as String?) == organizationID.rawValue,
                  (row["feature"] as String?) == CoverageFeature.timelines.rawValue
            else {
                throw TimelineCandidateRepositoryError.checkpointScopeMismatch
            }
            return
        }
        try database.execute(
            sql: """
                INSERT INTO sync_streams (
                    id, account_id, organization_id, feature, high_water_ms,
                    last_successful_at_ms, last_attempt_at_ms, state, failure_detail
                ) VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, NULL)
                """,
            arguments: [
                streamID.rawValue, accountID.rawValue, organizationID.rawValue,
                CoverageFeature.timelines.rawValue, CoverageStatus.partial.rawValue
            ]
        )
    }

    private nonisolated static func updateStream(
        for candidate: TimelineCandidate,
        state: CoverageStatus,
        successfulAt: Date?,
        attemptedAt: Date,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                UPDATE sync_streams
                SET state = ?, last_successful_at_ms = COALESCE(?, last_successful_at_ms),
                    last_attempt_at_ms = ?, failure_detail = NULL
                WHERE id = ?
                """,
            arguments: [
                state.rawValue,
                successfulAt.map(milliseconds),
                milliseconds(attemptedAt),
                streamID(for: candidate).rawValue
            ]
        )
    }

    private nonisolated static func streamID(for candidate: TimelineCandidate) -> SyncStreamID {
        SyncStreamID(rawValue: "timeline:\(candidate.nodeID.rawValue)")!
    }

    private nonisolated static func shardID(for candidate: TimelineCandidate) -> SyncShardID {
        let material = "\(candidate.nodeID.rawValue)|\(candidate.sourceRevision)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return SyncShardID(rawValue: "timeline:\(digest)")!
    }

    private nonisolated static func queryKind(for candidate: TimelineCandidate) -> String {
        "timeline:\(candidate.sourceRevision)"
    }

    private nonisolated static func validTimelineURL(
        _ value: String,
        candidate: TimelineCandidate
    ) -> URL? {
        guard let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host?.caseInsensitiveCompare("api.github.com") == .orderedSame,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.path == "\(candidate.repository.path)/issues/\(candidate.number)/timeline"
        else {
            return nil
        }
        let items = components.queryItems ?? []
        let allowedNames: Set<String> = ["page", "per_page"]
        let perPage = items.first(where: { $0.name == "per_page" })?.value.flatMap(Int.init) ?? 100
        guard !items.isEmpty,
              Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ allowedNames.contains($0.name) }),
              let page = items.first(where: { $0.name == "page" })?.value.flatMap(Int.init),
              page > 0,
              perPage > 0,
              perPage <= 100
        else {
            return nil
        }
        return url
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
