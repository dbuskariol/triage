import Foundation
import GRDB

enum OrganizationSchedulerStateRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case staleSynchronizationScope
    case invalidFailureCount
    case invalidGeneration
    case invalidTimestampOrder
    case invalidTimestamp
    case staleGeneration
    case invalidPersistedData
}

actor OrganizationSchedulerStateRepository {
    static let maximumConsecutiveFailureCount = 20

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func state(for scope: SynchronizationScope) async throws -> OrganizationSchedulerState? {
        guard scope.accountID == vault.accountID else {
            throw OrganizationSchedulerStateRepositoryError.accountScopeMismatch
        }
        return try await vault.write { database in
            try Self.validateCurrentScope(scope, in: database)
            guard let state = try Self.fetch(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                in: database
            ) else {
                return nil
            }
            guard state.credentialRevision == scope.credentialRevision,
                  state.capabilityRevision == scope.capabilityRevision
            else {
                try Self.remove(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    expectedAccountID: vault.accountID,
                    in: database
                )
                return nil
            }
            return state
        }
    }

    func states(for accountID: AccountID) async throws -> [OrganizationSchedulerState] {
        guard accountID == vault.accountID else {
            throw OrganizationSchedulerStateRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT scheduler.account_id, scheduler.organization_id,
                           scheduler.credential_revision, scheduler.capability_revision,
                           scheduler.next_incremental_refresh_at_ms,
                           scheduler.next_full_reconciliation_at_ms,
                           scheduler.rate_limited_until_ms, scheduler.blocked_reason,
                           scheduler.consecutive_transient_failure_count,
                           scheduler.active_attempt_id, scheduler.last_attempt_at_ms,
                           scheduler.last_completed_at_ms, scheduler.generation,
                           scheduler.updated_at_ms
                    FROM organization_scheduler_states AS scheduler
                    JOIN accounts
                      ON accounts.id = scheduler.account_id
                     AND accounts.credential_revision = scheduler.credential_revision
                    JOIN account_organizations
                      ON account_organizations.account_id = scheduler.account_id
                     AND account_organizations.organization_id = scheduler.organization_id
                     AND account_organizations.capability_revision = scheduler.capability_revision
                    WHERE scheduler.account_id = ?
                    ORDER BY scheduler.next_incremental_refresh_at_ms,
                             scheduler.organization_id
                    """,
                arguments: [accountID.rawValue]
            ).map(Self.state(from:))
        }
    }

    func save(_ state: OrganizationSchedulerState) async throws {
        try await vault.write { database in
            try Self.save(state, expectedAccountID: vault.accountID, in: database)
        }
    }

    /// Returns the current schedule for `initial`'s account-organization scope,
    /// creating it only when no current-revision schedule has won initialization.
    ///
    /// The read, revision-authority check, and optional write share one vault
    /// transaction so a later initializer cannot overwrite an existing current
    /// schedule. A persisted schedule from an old credential or capability
    /// revision is reset only after `initial` is proven current against the
    /// account and organization authority records in that same transaction.
    func createIfAbsent(_ initial: OrganizationSchedulerState) async throws -> OrganizationSchedulerState {
        try await vault.writeTransaction { database in
            try Self.createIfAbsent(
                initial,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    func claim(
        _ state: OrganizationSchedulerState,
        replacingIdleGeneration expectedGeneration: UInt64
    ) async throws -> Bool {
        try await vault.write { database in
            try Self.claim(
                state,
                replacingIdleGeneration: expectedGeneration,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    nonisolated static func claim(
        _ state: OrganizationSchedulerState,
        replacingIdleGeneration expectedGeneration: UInt64,
        expectedAccountID: AccountID,
        in database: Database
    ) throws -> Bool {
        try validate(state, expectedAccountID: expectedAccountID, in: database)
        let (expectedNextGeneration, overflow) = expectedGeneration.addingReportingOverflow(1)
        guard !overflow,
              state.generation == expectedNextGeneration,
              state.activeAttemptID != nil
        else {
            throw OrganizationSchedulerStateRepositoryError.staleGeneration
        }
        try database.execute(
            sql: """
                UPDATE organization_scheduler_states SET
                    next_incremental_refresh_at_ms = ?,
                    next_full_reconciliation_at_ms = ?, rate_limited_until_ms = ?,
                    blocked_reason = ?, consecutive_transient_failure_count = ?,
                    active_attempt_id = ?, last_attempt_at_ms = ?, last_completed_at_ms = ?,
                    generation = ?, updated_at_ms = ?
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                  AND active_attempt_id IS NULL AND generation = ?
                """,
            arguments: [
                try milliseconds(state.nextIncrementalRefreshAt),
                try milliseconds(state.nextFullReconciliationAt),
                try state.rateLimitedUntil.map(milliseconds),
                state.blockedReason?.rawValue,
                state.consecutiveTransientFailureCount,
                state.activeAttemptID?.uuidString.lowercased(),
                try state.lastAttemptAt.map(milliseconds),
                try state.lastCompletedAt.map(milliseconds),
                try persistedGeneration(state.generation),
                try milliseconds(state.updatedAt),
                state.accountID.rawValue,
                state.organizationID.rawValue,
                state.credentialRevision.rawValue,
                state.capabilityRevision.rawValue,
                try persistedGeneration(expectedGeneration)
            ]
        )
        return database.changesCount == 1
    }

    nonisolated static func save(
        _ state: OrganizationSchedulerState,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        try validate(state, expectedAccountID: expectedAccountID, in: database)
        if let existing = try fetch(
            accountID: state.accountID,
            organizationID: state.organizationID,
            in: database
        ) {
            guard state.generation >= existing.generation else {
                throw OrganizationSchedulerStateRepositoryError.staleGeneration
            }
            if state.generation == existing.generation,
               existing.activeAttemptID != state.activeAttemptID {
                throw OrganizationSchedulerStateRepositoryError.staleGeneration
            }
        }
        try upsert(state, in: database)
    }

    nonisolated static func createIfAbsent(
        _ initial: OrganizationSchedulerState,
        expectedAccountID: AccountID,
        in database: Database
    ) throws -> OrganizationSchedulerState {
        // This validates both the vault boundary and the candidate revisions
        // against the current account/organization authority rows before an
        // existing stale row is eligible for replacement.
        try validate(initial, expectedAccountID: expectedAccountID, in: database)

        guard let existing = try fetch(
            accountID: initial.accountID,
            organizationID: initial.organizationID,
            in: database
        ) else {
            try upsert(initial, in: database)
            return initial
        }

        guard existing.credentialRevision != initial.credentialRevision
            || existing.capabilityRevision != initial.capabilityRevision
        else {
            // An initializer that reached this transaction second must retain
            // the already-current schedule byte-for-byte, including attempt
            // ownership, generation, deadlines, and backoff state.
            return existing
        }

        // `initial` has already been proven current in this transaction;
        // therefore this is a stale-revision reset, not an overwrite of a
        // concurrently installed current schedule.
        try upsert(initial, in: database)
        return initial
    }

    func replace(
        _ state: OrganizationSchedulerState,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) async throws -> Bool {
        try await vault.write { database in
            try Self.replace(
                state,
                ifOwnedBy: expectedAttemptID,
                generation: expectedGeneration,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    nonisolated static func replace(
        _ state: OrganizationSchedulerState,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64,
        expectedAccountID: AccountID,
        in database: Database
    ) throws -> Bool {
        try validate(state, expectedAccountID: expectedAccountID, in: database)
        guard state.generation == expectedGeneration else {
            throw OrganizationSchedulerStateRepositoryError.staleGeneration
        }
        try database.execute(
            sql: """
                UPDATE organization_scheduler_states SET
                    credential_revision = ?, capability_revision = ?,
                    next_incremental_refresh_at_ms = ?,
                    next_full_reconciliation_at_ms = ?, rate_limited_until_ms = ?,
                    blocked_reason = ?, consecutive_transient_failure_count = ?,
                    active_attempt_id = ?, last_attempt_at_ms = ?, last_completed_at_ms = ?,
                    generation = ?, updated_at_ms = ?
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                  AND active_attempt_id = ? AND generation = ?
                """,
            arguments: [
                state.credentialRevision.rawValue,
                state.capabilityRevision.rawValue,
                try milliseconds(state.nextIncrementalRefreshAt),
                try milliseconds(state.nextFullReconciliationAt),
                try state.rateLimitedUntil.map(milliseconds),
                state.blockedReason?.rawValue,
                state.consecutiveTransientFailureCount,
                state.activeAttemptID?.uuidString.lowercased(),
                try state.lastAttemptAt.map(milliseconds),
                try state.lastCompletedAt.map(milliseconds),
                try persistedGeneration(state.generation),
                try milliseconds(state.updatedAt),
                state.accountID.rawValue,
                state.organizationID.rawValue,
                state.credentialRevision.rawValue,
                state.capabilityRevision.rawValue,
                expectedAttemptID.uuidString.lowercased(),
                try persistedGeneration(expectedGeneration)
            ]
        )
        return database.changesCount == 1
    }

    func remove(accountID: AccountID, organizationID: OrganizationID) async throws {
        guard accountID == vault.accountID else {
            throw OrganizationSchedulerStateRepositoryError.accountScopeMismatch
        }
        try await vault.write { database in
            try Self.remove(
                accountID: accountID,
                organizationID: organizationID,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    nonisolated static func remove(
        accountID: AccountID,
        organizationID: OrganizationID,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        guard accountID == expectedAccountID else {
            throw OrganizationSchedulerStateRepositoryError.accountScopeMismatch
        }
        try database.execute(
            sql: """
                DELETE FROM organization_scheduler_states
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [accountID.rawValue, organizationID.rawValue]
        )
    }

    private nonisolated static func validate(
        _ state: OrganizationSchedulerState,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        guard state.accountID == expectedAccountID else {
            throw OrganizationSchedulerStateRepositoryError.accountScopeMismatch
        }
        try validateCurrentScope(
            SynchronizationScope(
                accountID: state.accountID,
                organizationID: state.organizationID,
                credentialRevision: state.credentialRevision,
                capabilityRevision: state.capabilityRevision
            ),
            in: database
        )
        guard (0...maximumConsecutiveFailureCount).contains(
            state.consecutiveTransientFailureCount
        ) else {
            throw OrganizationSchedulerStateRepositoryError.invalidFailureCount
        }
        _ = try persistedGeneration(state.generation)
        if state.activeAttemptID != nil, state.lastAttemptAt == nil {
            throw OrganizationSchedulerStateRepositoryError.invalidTimestampOrder
        }
        if state.activeAttemptID != nil,
           let lastAttemptAt = state.lastAttemptAt,
           let lastCompletedAt = state.lastCompletedAt,
           lastCompletedAt > lastAttemptAt {
            throw OrganizationSchedulerStateRepositoryError.invalidTimestampOrder
        }
        let latestObservation = [state.lastAttemptAt, state.lastCompletedAt].compactMap { $0 }.max()
        if let latestObservation, state.updatedAt < latestObservation {
            throw OrganizationSchedulerStateRepositoryError.invalidTimestampOrder
        }
        _ = try milliseconds(state.nextIncrementalRefreshAt)
        _ = try milliseconds(state.nextFullReconciliationAt)
        _ = try state.rateLimitedUntil.map(milliseconds)
        _ = try state.lastAttemptAt.map(milliseconds)
        _ = try state.lastCompletedAt.map(milliseconds)
        _ = try milliseconds(state.updatedAt)

        let hasOrganizationScope = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM account_organizations
                    WHERE account_id = ? AND organization_id = ?
                )
                """,
            arguments: [state.accountID.rawValue, state.organizationID.rawValue]
        ) ?? false
        guard hasOrganizationScope else {
            throw OrganizationSchedulerStateRepositoryError.organizationScopeMismatch
        }
    }

    private nonisolated static func validateCurrentScope(
        _ scope: SynchronizationScope,
        in database: Database
    ) throws {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT accounts.credential_revision,
                       account_organizations.capability_revision
                FROM accounts
                JOIN account_organizations
                  ON account_organizations.account_id = accounts.id
                WHERE accounts.id = ? AND account_organizations.organization_id = ?
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        ) else {
            throw OrganizationSchedulerStateRepositoryError.organizationScopeMismatch
        }
        let credentialRevision: String = row["credential_revision"]
        let capabilityRevision: String = row["capability_revision"]
        guard credentialRevision == scope.credentialRevision.rawValue,
              capabilityRevision == scope.capabilityRevision.rawValue
        else {
            throw OrganizationSchedulerStateRepositoryError.staleSynchronizationScope
        }
    }

    private nonisolated static func upsert(
        _ state: OrganizationSchedulerState,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO organization_scheduler_states (
                    account_id, organization_id, credential_revision,
                    capability_revision, next_incremental_refresh_at_ms,
                    next_full_reconciliation_at_ms, rate_limited_until_ms,
                    blocked_reason, consecutive_transient_failure_count,
                    active_attempt_id, last_attempt_at_ms, last_completed_at_ms,
                    generation, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id, organization_id) DO UPDATE SET
                    credential_revision = excluded.credential_revision,
                    capability_revision = excluded.capability_revision,
                    next_incremental_refresh_at_ms = excluded.next_incremental_refresh_at_ms,
                    next_full_reconciliation_at_ms = excluded.next_full_reconciliation_at_ms,
                    rate_limited_until_ms = excluded.rate_limited_until_ms,
                    blocked_reason = excluded.blocked_reason,
                    consecutive_transient_failure_count = excluded.consecutive_transient_failure_count,
                    active_attempt_id = excluded.active_attempt_id,
                    last_attempt_at_ms = excluded.last_attempt_at_ms,
                    last_completed_at_ms = excluded.last_completed_at_ms,
                    generation = excluded.generation,
                    updated_at_ms = excluded.updated_at_ms
                """,
            arguments: [
                state.accountID.rawValue,
                state.organizationID.rawValue,
                state.credentialRevision.rawValue,
                state.capabilityRevision.rawValue,
                try milliseconds(state.nextIncrementalRefreshAt),
                try milliseconds(state.nextFullReconciliationAt),
                try state.rateLimitedUntil.map(milliseconds),
                state.blockedReason?.rawValue,
                state.consecutiveTransientFailureCount,
                state.activeAttemptID?.uuidString.lowercased(),
                try state.lastAttemptAt.map(milliseconds),
                try state.lastCompletedAt.map(milliseconds),
                try persistedGeneration(state.generation),
                try milliseconds(state.updatedAt)
            ]
        )
    }

    private nonisolated static func fetch(
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws -> OrganizationSchedulerState? {
        try Row.fetchOne(
            database,
            sql: """
                SELECT account_id, organization_id, credential_revision,
                       capability_revision, next_incremental_refresh_at_ms,
                       next_full_reconciliation_at_ms, rate_limited_until_ms,
                       blocked_reason, consecutive_transient_failure_count,
                       active_attempt_id, last_attempt_at_ms, last_completed_at_ms,
                       generation, updated_at_ms
                FROM organization_scheduler_states
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [accountID.rawValue, organizationID.rawValue]
        ).map(state(from:))
    }

    private nonisolated static func state(from row: Row) throws -> OrganizationSchedulerState {
        let blockedReasonValue: String? = row["blocked_reason"]
        let activeAttemptValue: String? = row["active_attempt_id"]
        let generationValue: Int64? = row["generation"]
        guard let accountID = AccountID(rawValue: row["account_id"]),
              let organizationID = OrganizationID(rawValue: row["organization_id"]),
              let credentialRevision = CredentialRevision(rawValue: row["credential_revision"]),
              let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"]),
              let nextIncrementalRefreshAt = date(milliseconds: row["next_incremental_refresh_at_ms"]),
              let nextFullReconciliationAt = date(milliseconds: row["next_full_reconciliation_at_ms"]),
              let consecutiveFailureCount: Int = row["consecutive_transient_failure_count"],
              let generationValue,
              generationValue >= 0,
              let updatedAt = date(milliseconds: row["updated_at_ms"]),
              blockedReasonValue == nil || OrganizationRefreshBlockReason(rawValue: blockedReasonValue!) != nil,
              activeAttemptValue == nil || UUID(uuidString: activeAttemptValue!) != nil
        else {
            throw OrganizationSchedulerStateRepositoryError.invalidPersistedData
        }
        let state = OrganizationSchedulerState(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            nextIncrementalRefreshAt: nextIncrementalRefreshAt,
            nextFullReconciliationAt: nextFullReconciliationAt,
            rateLimitedUntil: date(milliseconds: row["rate_limited_until_ms"]),
            blockedReason: blockedReasonValue.flatMap(OrganizationRefreshBlockReason.init(rawValue:)),
            consecutiveTransientFailureCount: consecutiveFailureCount,
            activeAttemptID: activeAttemptValue.flatMap(UUID.init(uuidString:)),
            lastAttemptAt: date(milliseconds: row["last_attempt_at_ms"]),
            lastCompletedAt: date(milliseconds: row["last_completed_at_ms"]),
            generation: UInt64(generationValue),
            updatedAt: updatedAt
        )
        guard (0...maximumConsecutiveFailureCount).contains(
            state.consecutiveTransientFailureCount
        ) else {
            throw OrganizationSchedulerStateRepositoryError.invalidPersistedData
        }
        if state.activeAttemptID != nil, state.lastAttemptAt == nil {
            throw OrganizationSchedulerStateRepositoryError.invalidPersistedData
        }
        if state.activeAttemptID != nil,
           let lastAttemptAt = state.lastAttemptAt,
           let lastCompletedAt = state.lastCompletedAt,
           lastCompletedAt > lastAttemptAt {
            throw OrganizationSchedulerStateRepositoryError.invalidPersistedData
        }
        let latestObservation = [state.lastAttemptAt, state.lastCompletedAt].compactMap { $0 }.max()
        if let latestObservation, state.updatedAt < latestObservation {
            throw OrganizationSchedulerStateRepositoryError.invalidPersistedData
        }
        return state
    }

    private nonisolated static func persistedGeneration(_ generation: UInt64) throws -> Int64 {
        guard generation <= UInt64(Int64.max) else {
            throw OrganizationSchedulerStateRepositoryError.invalidGeneration
        }
        return Int64(generation)
    }

    private nonisolated static func milliseconds(_ date: Date) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max)
        else {
            throw OrganizationSchedulerStateRepositoryError.invalidTimestamp
        }
        return Int64(milliseconds.rounded())
    }

    private nonisolated static func date(milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }
}

extension OrganizationSchedulerStateRepository: OrganizationSchedulerStateStoring {}
