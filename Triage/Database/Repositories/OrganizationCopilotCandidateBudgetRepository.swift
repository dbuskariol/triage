import Foundation
import GRDB

enum OrganizationCopilotCandidateBudgetRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case invalidCandidate
    case invalidSourceFingerprint
    case invalidDate
    case invalidPolicy
    case invalidPersistedData
}

/// The persisted part of Copilot scheduling.  The rows contain only opaque
/// candidate/fingerprint identifiers and timestamps; prompts, model output,
/// account credentials, and diagnostic payloads never enter this table.
actor OrganizationCopilotCandidateBudgetRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func availability(
        for scope: SynchronizationScope,
        policy: OrganizationCopilotCandidateBudgetPolicy,
        sourceFingerprint: String? = nil,
        at date: Date
    ) async throws -> OrganizationCopilotCandidateBudgetAvailability {
        try validate(scope: scope, policy: policy, date: date)
        if let sourceFingerprint {
            try Self.validateSourceFingerprint(sourceFingerprint)
        }
        return try await vault.read { database in
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
            return try Self.availability(
                scope: scope,
                policy: policy,
                sourceFingerprint: sourceFingerprint,
                at: date,
                in: database
            )
        }
    }

    func reserve(
        _ candidate: OrganizationCopilotBudgetCandidate,
        sourceFingerprint: String,
        for scope: SynchronizationScope,
        policy: OrganizationCopilotCandidateBudgetPolicy,
        at date: Date
    ) async throws -> OrganizationCopilotCandidateBudgetReservation? {
        try validate(scope: scope, policy: policy, date: date)
        try Self.validate(candidate: candidate, sourceFingerprint: sourceFingerprint)
        return try await vault.writeTransaction { database in
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
            // Counters have no diagnostic value after their enforcement
            // window. Keep only the current and two preceding UTC days so
            // local private state remains bounded.
            try database.execute(
                sql: "DELETE FROM ai_candidate_budget_attempts WHERE utc_day < ?",
                arguments: [Self.retentionCutoffDay(for: date)]
            )
            let availability = try Self.availability(
                scope: scope,
                policy: policy,
                sourceFingerprint: sourceFingerprint,
                at: date,
                in: database
            )
            guard availability.isAvailable else { return nil }

            let day = Self.dayKey(for: date)
            if let existing = try Row.fetchOne(
                database,
                sql: """
                    SELECT state, lease_id, started_at_ms
                    FROM ai_candidate_budget_attempts
                    WHERE account_id = ? AND organization_id = ? AND utc_day = ?
                      AND candidate_id = ? AND source_fingerprint = ?
                    """,
                arguments: [
                    scope.accountID.rawValue, scope.organizationID.rawValue, day,
                    candidate.id.rawValue, sourceFingerprint
                ]
            ) {
                let state: String = existing["state"]
                let startedAt: Int64 = existing["started_at_ms"]
                let leaseExpiresAt = startedAt + Self.milliseconds(policy.maximumLeaseDuration)
                // A completed/cancelled source fingerprint is intentionally
                // idempotent for the UTC day.  An abandoned process lease may
                // be reclaimed without increasing the durable daily counter.
                guard state == "leased", leaseExpiresAt <= Self.milliseconds(date) else {
                    return nil
                }
            }

            let leaseID = UUID().uuidString.lowercased()
            try database.execute(
                sql: """
                    INSERT INTO ai_candidate_budget_attempts (
                        account_id, organization_id, utc_day, candidate_id,
                        source_fingerprint, priority, state, lease_id,
                        started_at_ms, finished_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, 'leased', ?, ?, NULL)
                    ON CONFLICT(account_id, organization_id, utc_day, candidate_id, source_fingerprint)
                    DO UPDATE SET priority = excluded.priority, state = 'leased',
                                  lease_id = excluded.lease_id,
                                  started_at_ms = excluded.started_at_ms,
                                  finished_at_ms = NULL
                    """,
                arguments: [
                    scope.accountID.rawValue, scope.organizationID.rawValue, day,
                    candidate.id.rawValue, sourceFingerprint, candidate.priority,
                    leaseID, Self.milliseconds(date)
                ]
            )
            return OrganizationCopilotCandidateBudgetReservation(
                scope: scope,
                utcDay: day,
                candidate: candidate,
                sourceFingerprint: sourceFingerprint,
                leaseID: leaseID
            )
        }
    }

    func finish(
        _ reservation: OrganizationCopilotCandidateBudgetReservation,
        disposition: OrganizationCopilotCandidateBudgetCompletion,
        at date: Date
    ) async throws {
        try validate(scope: reservation.scope, policy: .production, date: date)
        try await vault.writeTransaction { database in
            try OrganizationSchedulerStateRepository.validateCurrentScope(reservation.scope, in: database)
            try database.execute(
                sql: """
                    UPDATE ai_candidate_budget_attempts
                    SET state = ?, finished_at_ms = ?
                    WHERE account_id = ? AND organization_id = ? AND utc_day = ?
                      AND candidate_id = ? AND source_fingerprint = ?
                      AND state = 'leased' AND lease_id = ?
                    """,
                arguments: [
                    disposition.persistedState, Self.milliseconds(date),
                    reservation.scope.accountID.rawValue, reservation.scope.organizationID.rawValue,
                    reservation.utcDay, reservation.candidate.id.rawValue,
                    reservation.sourceFingerprint, reservation.leaseID
                ]
            )
        }
    }

    private func validate(
        scope: SynchronizationScope,
        policy: OrganizationCopilotCandidateBudgetPolicy,
        date: Date
    ) throws {
        guard scope.accountID == vault.accountID else {
            throw OrganizationCopilotCandidateBudgetRepositoryError.accountScopeMismatch
        }
        guard policy.isValid else { throw OrganizationCopilotCandidateBudgetRepositoryError.invalidPolicy }
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw OrganizationCopilotCandidateBudgetRepositoryError.invalidDate
        }
    }

    private nonisolated static func availability(
        scope: SynchronizationScope,
        policy: OrganizationCopilotCandidateBudgetPolicy,
        sourceFingerprint: String?,
        at date: Date,
        in database: Database
    ) throws -> OrganizationCopilotCandidateBudgetAvailability {
        let day = dayKey(for: date)
        let now = milliseconds(date)
        let activeThreshold = now - milliseconds(policy.maximumLeaseDuration)
        let dailyCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM ai_candidate_budget_attempts
                WHERE account_id = ? AND organization_id = ? AND utc_day = ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, day]
        ) ?? 0
        let activeCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM ai_candidate_budget_attempts
                WHERE account_id = ? AND organization_id = ? AND state = 'leased'
                  AND started_at_ms > ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, activeThreshold]
        ) ?? 0
        let sourceCount: Int
        if let sourceFingerprint {
            sourceCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM ai_candidate_budget_attempts
                    WHERE account_id = ? AND organization_id = ? AND utc_day = ?
                      AND source_fingerprint = ?
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, day, sourceFingerprint]
            ) ?? 0
        } else {
            sourceCount = 0
        }
        let latestStart = try Int64.fetchOne(
            database,
            sql: """
                SELECT MAX(started_at_ms) FROM ai_candidate_budget_attempts
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        )
        let nextAllowedAt = latestStart.map { $0 + milliseconds(policy.minimumStartInterval) }
        let remoteRateLimitedUntil = try Int64.fetchOne(
            database,
            sql: """
                SELECT rate_limited_until_ms
                FROM organization_scheduler_states
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                """,
            arguments: [
                scope.accountID.rawValue, scope.organizationID.rawValue,
                scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue
            ]
        )
        return OrganizationCopilotCandidateBudgetAvailability(
            dailyRemaining: max(0, policy.maximumCandidatesPerUTCDate - dailyCount),
            sourceRemaining: max(0, policy.maximumCandidatesPerSourceFingerprint - sourceCount),
            concurrentRemaining: max(0, policy.maximumConcurrentCandidates - activeCount),
            isRateLimited: (nextAllowedAt.map { $0 > now } ?? false)
                || (remoteRateLimitedUntil.map { $0 > now } ?? false)
        )
    }

    private nonisolated static func validate(
        candidate: OrganizationCopilotBudgetCandidate,
        sourceFingerprint: String
    ) throws {
        guard !candidate.id.rawValue.isEmpty,
              candidate.id.rawValue.utf8.count <= 512
        else { throw OrganizationCopilotCandidateBudgetRepositoryError.invalidCandidate }
        try validateSourceFingerprint(sourceFingerprint)
    }

    private nonisolated static func validateSourceFingerprint(_ sourceFingerprint: String) throws {
        guard sourceFingerprint.count == 64,
              sourceFingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw OrganizationCopilotCandidateBudgetRepositoryError.invalidSourceFingerprint }
    }

    private nonisolated static func dayKey(for date: Date) -> String {
        let calendar = utcCalendar
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }

    private nonisolated static func retentionCutoffDay(for date: Date) -> String {
        let cutoff = utcCalendar.date(byAdding: .day, value: -2, to: date) ?? date
        return dayKey(for: cutoff)
    }

    private nonisolated static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private nonisolated static func milliseconds(_ interval: TimeInterval) -> Int64 {
        Int64((interval * 1_000).rounded(.down))
    }
}
