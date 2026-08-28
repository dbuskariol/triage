import Foundation
import GRDB

actor RateLimitRepository: GitHubRateLimitPersisting {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func rateLimits(for accountID: AccountID) async throws -> [GitHubRateLimit] {
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT resource, rate_limit, remaining, reset_at_ms, retry_after_ms, updated_at_ms
                    FROM rate_limit_buckets
                    WHERE account_id = ?
                """,
                arguments: [accountID.rawValue]
            ).compactMap { row in
                guard let resource = GitHubRateLimitResource(rawValue: row["resource"]) else {
                    return nil
                }
                let retryAfterMilliseconds: Int64? = row["retry_after_ms"]
                return GitHubRateLimit(
                    resource: resource,
                    limit: row["rate_limit"],
                    remaining: row["remaining"],
                    resetAt: Self.date(milliseconds: row["reset_at_ms"]),
                    retryAfter: retryAfterMilliseconds.map { TimeInterval($0) / 1_000 },
                    observedAt: Self.date(milliseconds: row["updated_at_ms"]) ?? .distantPast
                )
            }
        }
    }

    func save(_ rateLimit: GitHubRateLimit, for accountID: AccountID) async throws {
        try ensureAccountScope(accountID)
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO rate_limit_buckets (
                        account_id, resource, rate_limit, remaining, reset_at_ms, retry_after_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, resource) DO UPDATE SET
                        rate_limit = excluded.rate_limit,
                        remaining = excluded.remaining,
                        reset_at_ms = excluded.reset_at_ms,
                        retry_after_ms = excluded.retry_after_ms,
                        updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    accountID.rawValue,
                    rateLimit.resource.rawValue,
                    rateLimit.limit,
                    rateLimit.remaining,
                    rateLimit.resetAt.map(Self.milliseconds),
                    rateLimit.retryAfter.map(Self.milliseconds),
                    Self.milliseconds(rateLimit.observedAt)
                ]
            )
        }
    }

    func secondaryPause(for accountID: AccountID) async throws -> Date? {
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT pause_until_ms FROM rate_limit_secondary_cooldowns WHERE account_id = ?",
                arguments: [accountID.rawValue]
            ).map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
        }
    }

    func saveSecondaryPause(until: Date, for accountID: AccountID) async throws {
        try ensureAccountScope(accountID)
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO rate_limit_secondary_cooldowns (account_id, pause_until_ms)
                    VALUES (?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET pause_until_ms = excluded.pause_until_ms
                """,
                arguments: [accountID.rawValue, Self.milliseconds(until)]
            )
        }
    }

    private func ensureAccountScope(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw RateLimitRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func milliseconds(_ interval: TimeInterval) -> Int64 {
        Int64((interval * 1_000).rounded())
    }

    private nonisolated static func date(milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }
}

enum RateLimitRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
}
