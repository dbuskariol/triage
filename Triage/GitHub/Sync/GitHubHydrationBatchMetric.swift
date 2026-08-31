import Foundation

struct GitHubHydrationBatchMetric: Equatable, Sendable {
    let accountID: AccountID
    let requestedNodeCount: Int
    let responseBytes: Int
    let queryCost: Int
    let rateLimitRemaining: Int
    let rateLimitResetAt: Date
    let observedAt: Date
}

enum GitHubHydrationBatchPlanner {
    static let initialBatchSize = 25
    static let maximumBatchSize = 50
    static let maximumQueryCost = 500
    static let maximumResponseBytes = 4 * 1_024 * 1_024

    static func nextBatchSize(
        after batchSize: Int,
        queryCost: Int,
        responseBytes: Int
    ) -> Int {
        precondition((initialBatchSize ... maximumBatchSize).contains(batchSize))
        // The service validates untrusted GraphQL cost/size before reaching
        // the planner. Keep this defensive fallback non-trapping so a future
        // caller cannot turn hostile telemetry into a process crash.
        guard queryCost >= 0, responseBytes > 0 else { return initialBatchSize }

        if queryCost >= maximumQueryCost * 3 / 4 ||
            responseBytes >= maximumResponseBytes * 3 / 4 {
            return max(initialBatchSize, batchSize - 5)
        }
        if queryCost <= maximumQueryCost / 4 &&
            responseBytes <= maximumResponseBytes / 4 {
            return min(maximumBatchSize, batchSize + 5)
        }
        return batchSize
    }

    static func retryBatchSize(for failingBatchCount: Int) -> Int? {
        guard failingBatchCount > initialBatchSize else {
            return nil
        }
        return max(initialBatchSize, failingBatchCount - 5)
    }
}
