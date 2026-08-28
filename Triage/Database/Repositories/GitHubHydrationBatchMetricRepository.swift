import Foundation
import GRDB

enum GitHubHydrationBatchMetricRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case invalidRequestedNodeCount
    case invalidResponseBytes
    case invalidQueryCost
    case invalidRateLimitRemaining
    case invalidLimit
}

actor GitHubHydrationBatchMetricRepository {
    private static let retentionLimit = 500

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func record(_ metric: GitHubHydrationBatchMetric) async throws {
        guard metric.accountID == vault.accountID else {
            throw GitHubHydrationBatchMetricRepositoryError.accountScopeMismatch
        }
        guard (1 ... GitHubHydrationBatchPlanner.maximumBatchSize)
            .contains(metric.requestedNodeCount)
        else {
            throw GitHubHydrationBatchMetricRepositoryError.invalidRequestedNodeCount
        }
        guard (1 ... GitHubHydrationBatchPlanner.maximumResponseBytes).contains(metric.responseBytes) else {
            throw GitHubHydrationBatchMetricRepositoryError.invalidResponseBytes
        }
        guard metric.queryCost >= 0 else {
            throw GitHubHydrationBatchMetricRepositoryError.invalidQueryCost
        }
        guard metric.rateLimitRemaining >= 0 else {
            throw GitHubHydrationBatchMetricRepositoryError.invalidRateLimitRemaining
        }

        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO github_hydration_batch_metrics (
                        account_id, requested_node_count, response_bytes, query_cost,
                        rate_limit_remaining, rate_limit_reset_at_ms, observed_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    metric.accountID.rawValue,
                    metric.requestedNodeCount,
                    metric.responseBytes,
                    metric.queryCost,
                    metric.rateLimitRemaining,
                    Self.milliseconds(metric.rateLimitResetAt),
                    Self.milliseconds(metric.observedAt)
                ]
            )
            try database.execute(
                sql: """
                    DELETE FROM github_hydration_batch_metrics
                    WHERE account_id = ?
                      AND id NOT IN (
                          SELECT id
                          FROM github_hydration_batch_metrics
                          WHERE account_id = ?
                          ORDER BY observed_at_ms DESC, id DESC
                          LIMIT ?
                      )
                """,
                arguments: [metric.accountID.rawValue, metric.accountID.rawValue, Self.retentionLimit]
            )
        }
    }

    func recentMetrics(for accountID: AccountID, limit: Int = 100) async throws -> [GitHubHydrationBatchMetric] {
        guard accountID == vault.accountID else {
            throw GitHubHydrationBatchMetricRepositoryError.accountScopeMismatch
        }
        guard limit >= 0 else {
            throw GitHubHydrationBatchMetricRepositoryError.invalidLimit
        }
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT requested_node_count, response_bytes, query_cost, rate_limit_remaining,
                           rate_limit_reset_at_ms, observed_at_ms
                    FROM github_hydration_batch_metrics
                    WHERE account_id = ?
                    ORDER BY observed_at_ms DESC, id DESC
                    LIMIT ?
                """,
                arguments: [accountID.rawValue, limit]
            ).map {
                GitHubHydrationBatchMetric(
                    accountID: accountID,
                    requestedNodeCount: $0["requested_node_count"],
                    responseBytes: $0["response_bytes"],
                    queryCost: $0["query_cost"],
                    rateLimitRemaining: $0["rate_limit_remaining"],
                    rateLimitResetAt: Self.date(milliseconds: $0["rate_limit_reset_at_ms"]),
                    observedAt: Self.date(milliseconds: $0["observed_at_ms"])
                )
            }
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}
