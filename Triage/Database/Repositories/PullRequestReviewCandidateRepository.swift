import CryptoKit
import Foundation
import GRDB

enum PullRequestReviewCandidateRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case invalidLimit
    case invalidPersistedCandidate
    case invalidScheduleScope
    case missingScheduleStream
    case invalidScheduleCursor
}

struct PullRequestReviewCandidate: Sendable {
    let nodeID: GitHubNodeID
    let repositoryID: RepositoryID
    let repository: GitHubRepositoryPath
    let number: Int
}

struct PullRequestReviewCandidateInventory: Sendable {
    let candidates: [PullRequestReviewCandidate]
    let hasRemainingCandidates: Bool
    /// Known pull requests retained in this scoped vault but currently unsafe
    /// to request because their node or repository authority is unavailable.
    /// This is intentionally independent from the runnable batch, so an empty
    /// eligible selection cannot be mistaken for complete source coverage.
    let hasBlockedKnownCandidates: Bool
}

actor PullRequestReviewCandidateRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func candidates(
        accountID: AccountID,
        organizationID: OrganizationID,
        limit: Int
    ) async throws -> PullRequestReviewCandidateInventory {
        guard accountID == vault.accountID else {
            throw PullRequestReviewCandidateRepositoryError.accountScopeMismatch
        }
        guard limit > 0, limit < .max else {
            throw PullRequestReviewCandidateRepositoryError.invalidLimit
        }
        return try await vault.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT github_nodes.github_node_id, repositories.id AS repository_id,
                           repositories.owner_login, repositories.name, github_nodes.number
                    FROM pull_requests
                    JOIN github_nodes
                      ON github_nodes.github_node_id = pull_requests.github_node_id
                    JOIN repositories ON repositories.id = github_nodes.repository_id
                    JOIN account_repository_access
                      ON account_repository_access.repository_id = repositories.id
                    WHERE github_nodes.account_id = ?
                      AND github_nodes.organization_id = ?
                      AND github_nodes.accessibility_state = ?
                      AND account_repository_access.account_id = ?
                      AND account_repository_access.access_state = 'available'
                      AND github_nodes.number > 0
                    ORDER BY github_nodes.last_observed_at_ms ASC, github_nodes.github_node_id ASC
                    LIMIT ?
                    """,
                arguments: [
                    accountID.rawValue,
                    organizationID.rawValue,
                    GitHubNodeAccessibility.accessible.rawValue,
                    accountID.rawValue,
                    limit + 1
                ]
            )
            let candidates = try rows.prefix(limit).map(Self.candidate)
            return PullRequestReviewCandidateInventory(
                candidates: candidates,
                hasRemainingCandidates: rows.count > limit,
                hasBlockedKnownCandidates: try Self.hasBlockedKnownCandidates(
                    accountID: accountID,
                    organizationID: organizationID,
                    in: database
                )
            )
        }
    }

    /// Selects a bounded, deterministic round-robin batch.  The cursor for
    /// each repository is independent, and the root cursor rotates the
    /// repository that gets first position on the next invocation.  Therefore
    /// an organization with a large or frequently updated pull request set in
    /// one repository cannot indefinitely postpone every other repository.
    ///
    /// This is deliberately a scheduling cursor, not source coverage.  The
    /// caller must advance it in the same transaction as either the completed
    /// normalized write or an explicitly classified attempt.  Cancellation and
    /// authority rotation do not advance it.
    func fairCandidates(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        feature: CoverageFeature,
        limit: Int
    ) async throws -> PullRequestReviewCandidateInventory {
        guard scope.accountID == vault.accountID else {
            throw PullRequestReviewCandidateRepositoryError.accountScopeMismatch
        }
        guard Self.isReviewFeature(feature), limit > 0, limit < .max else {
            throw PullRequestReviewCandidateRepositoryError.invalidLimit
        }
        return try await vault.writeTransaction { database in
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
            try Self.requireScheduleStream(
                streamID: streamID,
                scope: scope,
                feature: feature,
                in: database
            )
            let candidates = try Self.eligibleCandidates(scope: scope, in: database)
            let hasBlockedKnownCandidates = try Self.hasBlockedKnownCandidates(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                in: database
            )
            guard !candidates.isEmpty else {
                return PullRequestReviewCandidateInventory(
                    candidates: [],
                    hasRemainingCandidates: false,
                    hasBlockedKnownCandidates: hasBlockedKnownCandidates
                )
            }
            let rootCursor = try Self.rootCursor(
                streamID: streamID,
                feature: feature,
                in: database
            )
            let repositoryOrder = Self.rotatedRepositoryOrder(
                candidates: candidates,
                after: rootCursor
            )
            let cursors = try Dictionary(
                uniqueKeysWithValues: repositoryOrder.map { repositoryID in
                    (
                        repositoryID,
                        try Self.repositoryCursor(
                            repositoryID: repositoryID,
                            streamID: streamID,
                            feature: feature,
                            accountID: scope.accountID,
                            in: database
                        )
                    )
                }
            )
            let selected = Self.roundRobinCandidates(
                candidates: candidates,
                repositoryOrder: repositoryOrder,
                cursors: cursors,
                limit: limit
            )
            return PullRequestReviewCandidateInventory(
                candidates: selected,
                hasRemainingCandidates: candidates.count > selected.count,
                hasBlockedKnownCandidates: hasBlockedKnownCandidates
            )
        }
    }

    /// Advances the durable fair-scheduling pointers. Call this inside the
    /// same transaction as a successful source write or a classified failed
    /// attempt; never call it for cancellation or obsolete authority.
    nonisolated static func advanceFairSchedule(
        after candidate: PullRequestReviewCandidate,
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        feature: CoverageFeature,
        at attemptedAt: Date,
        in database: Database
    ) throws {
        guard isReviewFeature(feature) else {
            throw PullRequestReviewCandidateRepositoryError.invalidScheduleScope
        }
        try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        try requireScheduleStream(
            streamID: streamID,
            scope: scope,
            feature: feature,
            in: database
        )
        try requireCandidate(candidate, scope: scope, in: database)
        try SyncShardRepository.save(
            SyncShard(
                id: repositoryShardID(
                    repositoryID: candidate.repositoryID,
                    streamID: streamID,
                    feature: feature
                ),
                streamID: streamID,
                queryKind: repositoryQueryKind(feature: feature),
                intervalStart: nil,
                intervalEnd: nil,
                pageCursor: candidate.nodeID.rawValue,
                state: .running,
                completedAt: nil
            ),
            accountID: scope.accountID,
            in: database
        )
        try SyncShardRepository.save(
            SyncShard(
                id: rootShardID(streamID: streamID, feature: feature),
                streamID: streamID,
                queryKind: rootQueryKind(feature: feature),
                intervalStart: nil,
                intervalEnd: nil,
                pageCursor: candidate.repositoryID.rawValue,
                state: .running,
                completedAt: nil
            ),
            accountID: scope.accountID,
            in: database
        )
        try database.execute(
            sql: """
                UPDATE sync_streams
                SET last_attempt_at_ms = ?, state = ?, failure_detail = NULL
                WHERE id = ?
                """,
            arguments: [
                milliseconds(attemptedAt),
                CoverageStatus.partial.rawValue,
                streamID.rawValue
            ]
        )
    }

    func writeTransaction<Value: Sendable>(
        accountID: AccountID,
        _ operation: @Sendable (Database) throws -> Value
    ) async throws -> Value {
        guard accountID == vault.accountID else {
            throw PullRequestReviewCandidateRepositoryError.accountScopeMismatch
        }
        return try await vault.writeTransaction(operation)
    }

    private nonisolated static func candidate(_ row: Row) throws -> PullRequestReviewCandidate {
        guard let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
              let repositoryID = RepositoryID(rawValue: row["repository_id"]),
              let number: Int = row["number"]
        else {
            throw PullRequestReviewCandidateRepositoryError.invalidPersistedCandidate
        }
        return PullRequestReviewCandidate(
            nodeID: nodeID,
            repositoryID: repositoryID,
            repository: try GitHubRepositoryPath(
                owner: row["owner_login"],
                repository: row["name"]
            ),
            number: number
        )
    }

    private nonisolated static func eligibleCandidates(
        scope: SynchronizationScope,
        in database: Database
    ) throws -> [PullRequestReviewCandidate] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT github_nodes.github_node_id, repositories.id AS repository_id,
                       repositories.owner_login, repositories.name, github_nodes.number
                FROM pull_requests
                JOIN github_nodes
                  ON github_nodes.github_node_id = pull_requests.github_node_id
                JOIN repositories ON repositories.id = github_nodes.repository_id
                JOIN account_repository_access
                  ON account_repository_access.repository_id = repositories.id
                WHERE github_nodes.account_id = ?
                  AND github_nodes.organization_id = ?
                  AND github_nodes.accessibility_state = ?
                  AND account_repository_access.account_id = ?
                  AND account_repository_access.access_state = 'available'
                  AND github_nodes.number > 0
                ORDER BY repositories.id COLLATE BINARY ASC,
                         github_nodes.github_node_id COLLATE BINARY ASC
                """,
            arguments: [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                GitHubNodeAccessibility.accessible.rawValue,
                scope.accountID.rawValue
            ]
        ).map(candidate)
    }

    private nonisolated static func hasBlockedKnownCandidates(
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws -> Bool {
        (try Int.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM pull_requests
                    JOIN github_nodes
                      ON github_nodes.github_node_id = pull_requests.github_node_id
                    JOIN repositories ON repositories.id = github_nodes.repository_id
                    LEFT JOIN account_repository_access
                      ON account_repository_access.repository_id = repositories.id
                     AND account_repository_access.account_id = ?
                    WHERE github_nodes.account_id = ?
                      AND github_nodes.organization_id = ?
                      AND github_nodes.number > 0
                      AND (
                          github_nodes.accessibility_state != ?
                          OR account_repository_access.access_state IS NULL
                          OR account_repository_access.access_state != 'available'
                      )
                )
                """,
            arguments: [
                accountID.rawValue,
                accountID.rawValue,
                organizationID.rawValue,
                GitHubNodeAccessibility.accessible.rawValue
            ]
        ) ?? 0) != 0
    }

    private nonisolated static func rotatedRepositoryOrder(
        candidates: [PullRequestReviewCandidate],
        after cursor: RepositoryID?
    ) -> [RepositoryID] {
        let repositoryIDs = Array(Set(candidates.map(\.repositoryID))).sorted {
            $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }
        guard let cursor,
              let index = repositoryIDs.firstIndex(of: cursor)
        else {
            return repositoryIDs
        }
        return Array(repositoryIDs.dropFirst(index + 1)) + Array(repositoryIDs.prefix(index + 1))
    }

    private nonisolated static func roundRobinCandidates(
        candidates: [PullRequestReviewCandidate],
        repositoryOrder: [RepositoryID],
        cursors: [RepositoryID: GitHubNodeID?],
        limit: Int
    ) -> [PullRequestReviewCandidate] {
        let grouped = Dictionary(grouping: candidates, by: \.repositoryID)
        var nextIndices = [RepositoryID: Int]()
        for repositoryID in repositoryOrder {
            guard let repositoryCandidates = grouped[repositoryID], !repositoryCandidates.isEmpty else {
                continue
            }
            if let cursor = cursors[repositoryID] ?? nil,
               let after = repositoryCandidates.firstIndex(where: {
                   cursor.rawValue.utf8.lexicographicallyPrecedes($0.nodeID.rawValue.utf8)
               }) {
                nextIndices[repositoryID] = after
            } else {
                nextIndices[repositoryID] = 0
            }
        }

        var selected = [PullRequestReviewCandidate]()
        while selected.count < limit {
            var selectedAny = false
            for repositoryID in repositoryOrder where selected.count < limit {
                guard let repositoryCandidates = grouped[repositoryID],
                      let index = nextIndices[repositoryID],
                      index < repositoryCandidates.count
                else {
                    continue
                }
                selected.append(repositoryCandidates[index])
                nextIndices[repositoryID] = index + 1
                selectedAny = true
            }
            guard selectedAny else { break }
        }
        return selected
    }

    private nonisolated static func rootCursor(
        streamID: SyncStreamID,
        feature: CoverageFeature,
        in database: Database
    ) throws -> RepositoryID? {
        guard let value = try String.fetchOne(
            database,
            sql: """
                SELECT page_cursor FROM sync_shards
                WHERE id = ? AND stream_id = ? AND query_kind = ? AND state = ?
                """,
            arguments: [
                rootShardID(streamID: streamID, feature: feature).rawValue,
                streamID.rawValue,
                rootQueryKind(feature: feature),
                SyncShardState.running.rawValue
            ]
        ) else {
            return nil
        }
        guard let cursor = RepositoryID(rawValue: value) else {
            throw PullRequestReviewCandidateRepositoryError.invalidScheduleCursor
        }
        return cursor
    }

    private nonisolated static func repositoryCursor(
        repositoryID: RepositoryID,
        streamID: SyncStreamID,
        feature: CoverageFeature,
        accountID: AccountID,
        in database: Database
    ) throws -> GitHubNodeID? {
        _ = accountID
        guard let value = try String.fetchOne(
            database,
            sql: """
                SELECT page_cursor FROM sync_shards
                WHERE id = ? AND stream_id = ? AND query_kind = ? AND state = ?
                """,
            arguments: [
                repositoryShardID(repositoryID: repositoryID, streamID: streamID, feature: feature).rawValue,
                streamID.rawValue,
                repositoryQueryKind(feature: feature),
                SyncShardState.running.rawValue
            ]
        ) else {
            return nil
        }
        guard let cursor = GitHubNodeID(rawValue: value) else {
            throw PullRequestReviewCandidateRepositoryError.invalidScheduleCursor
        }
        return cursor
    }

    private nonisolated static func requireScheduleStream(
        streamID: SyncStreamID,
        scope: SynchronizationScope,
        feature: CoverageFeature,
        in database: Database
    ) throws {
        if let row = try Row.fetchOne(
            database,
            sql: "SELECT account_id, organization_id, feature FROM sync_streams WHERE id = ?",
            arguments: [streamID.rawValue]
        ) {
            guard (row["account_id"] as String?) == scope.accountID.rawValue,
                  (row["organization_id"] as String?) == scope.organizationID.rawValue,
                  (row["feature"] as String?) == feature.rawValue
            else {
                throw PullRequestReviewCandidateRepositoryError.invalidScheduleScope
            }
            return
        }
        throw PullRequestReviewCandidateRepositoryError.missingScheduleStream
    }

    private nonisolated static func requireCandidate(
        _ candidate: PullRequestReviewCandidate,
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM pull_requests
                JOIN github_nodes
                  ON github_nodes.github_node_id = pull_requests.github_node_id
                JOIN repositories ON repositories.id = github_nodes.repository_id
                JOIN account_repository_access
                  ON account_repository_access.repository_id = repositories.id
                WHERE github_nodes.github_node_id = ?
                  AND github_nodes.account_id = ?
                  AND github_nodes.organization_id = ?
                  AND repositories.id = ?
                  AND repositories.owner_login = ?
                  AND repositories.name = ?
                  AND github_nodes.number = ?
                  AND github_nodes.accessibility_state = ?
                  AND account_repository_access.account_id = ?
                  AND account_repository_access.access_state = 'available'
                """,
            arguments: [
                candidate.nodeID.rawValue,
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                candidate.repositoryID.rawValue,
                candidate.repository.owner,
                candidate.repository.repository,
                candidate.number,
                GitHubNodeAccessibility.accessible.rawValue,
                scope.accountID.rawValue
            ]
        ) ?? 0
        guard count == 1 else {
            throw PullRequestReviewCandidateRepositoryError.invalidPersistedCandidate
        }
    }

    private nonisolated static func isReviewFeature(_ feature: CoverageFeature) -> Bool {
        feature == .reviews || feature == .reviewThreads
    }

    private nonisolated static func rootShardID(
        streamID: SyncStreamID,
        feature: CoverageFeature
    ) -> SyncShardID {
        shardID(prefix: "review-fair-root", material: "\(feature.rawValue)|\(streamID.rawValue)")
    }

    private nonisolated static func repositoryShardID(
        repositoryID: RepositoryID,
        streamID: SyncStreamID,
        feature: CoverageFeature
    ) -> SyncShardID {
        shardID(
            prefix: "review-fair-repository",
            material: "\(feature.rawValue)|\(streamID.rawValue)|\(repositoryID.rawValue)"
        )
    }

    private nonisolated static func shardID(prefix: String, material: String) -> SyncShardID {
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return SyncShardID(rawValue: "\(prefix):\(digest)")!
    }

    private nonisolated static func rootQueryKind(feature: CoverageFeature) -> String {
        "\(feature.rawValue)-fair-root-v1"
    }

    private nonisolated static func repositoryQueryKind(feature: CoverageFeature) -> String {
        "\(feature.rawValue)-fair-repository-v1"
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
