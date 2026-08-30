import Foundation
import GRDB

enum AccountOrganizationDurableStateRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case staleSynchronizationScope
    case scheduleScopeMismatch
    case invalidGeneration
    case staleGeneration
    case invalidProjection
    case invalidPersistedData
    case payloadTooLarge
}

/// Persists the coordinator's revision-qualified cached/freshness projection
/// inside the selected account's encrypted SQLCipher vault.
actor AccountOrganizationDurableStateRepository {
    static let formatVersion = 1
    static let maximumCoverageRecordCount = 20_000
    static let maximumPayloadBytes = 4 * 1_024 * 1_024
    static let maximumDetailBytes = 4_096

    private struct Envelope: Codable, Sendable {
        let formatVersion: Int
        let scope: SynchronizationScope
        let durableState: AccountOrganizationDurableState
    }

    private let vault: AccountVault

    private enum CoverageProjectionMode: Sendable {
        case requireCandidateMatch
        case snapshotPersistedFailure
    }

    init(vault: AccountVault) {
        self.vault = vault
    }

    func loadState(
        for scope: SynchronizationScope
    ) async throws -> AccountOrganizationDurableState? {
        guard scope.accountID == vault.accountID else {
            throw AccountOrganizationDurableStateRepositoryError.accountScopeMismatch
        }
        return try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            guard let row = try Self.fetch(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                in: database
            ) else {
                return nil
            }
            guard row.scope == scope else {
                try Self.remove(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    in: database
                )
                return nil
            }
            let envelope = try Self.decode(row.payload)
            guard envelope.formatVersion == Self.formatVersion,
                  envelope.scope == scope
            else {
                throw AccountOrganizationDurableStateRepositoryError.invalidPersistedData
            }
            do {
                try Self.validate(envelope.durableState, for: scope)
            } catch {
                throw AccountOrganizationDurableStateRepositoryError.invalidPersistedData
            }
            guard let schedule = try OrganizationSchedulerStateRepository.fetch(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                in: database
            ) else {
                throw AccountOrganizationDurableStateRepositoryError.invalidPersistedData
            }
            guard schedule.credentialRevision == scope.credentialRevision,
                  schedule.capabilityRevision == scope.capabilityRevision
            else {
                try Self.remove(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    in: database
                )
                return nil
            }
            guard schedule.generation >= row.schedulerGeneration else {
                throw AccountOrganizationDurableStateRepositoryError.invalidPersistedData
            }
            guard schedule.generation == row.schedulerGeneration,
                  schedule.activeAttemptID == nil
            else {
                return Self.interrupted(envelope.durableState)
            }
            return envelope.durableState
        }
    }

    func finalize(
        _ state: AccountOrganizationDurableState,
        schedule: OrganizationSchedulerState,
        for scope: SynchronizationScope,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) async throws -> Bool {
        try await finalizeProjection(
            state,
            schedule: schedule,
            for: scope,
            ifOwnedBy: expectedAttemptID,
            generation: expectedGeneration,
            coverageMode: .requireCandidateMatch
        ) != nil
    }

    func finalizeFailure(
        _ state: AccountOrganizationDurableState,
        schedule: OrganizationSchedulerState,
        for scope: SynchronizationScope,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) async throws -> AccountOrganizationDurableState? {
        try await finalizeProjection(
            state,
            schedule: schedule,
            for: scope,
            ifOwnedBy: expectedAttemptID,
            generation: expectedGeneration,
            coverageMode: .snapshotPersistedFailure
        )
    }

    func finalizeInterruption(
        _ state: AccountOrganizationDurableState,
        schedule: OrganizationSchedulerState,
        for scope: SynchronizationScope,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) async throws -> AccountOrganizationDurableState? {
        try await finalizeProjection(
            state,
            schedule: schedule,
            for: scope,
            ifOwnedBy: expectedAttemptID,
            generation: expectedGeneration,
            coverageMode: .snapshotPersistedFailure
        )
    }

    private func finalizeProjection(
        _ state: AccountOrganizationDurableState,
        schedule: OrganizationSchedulerState,
        for scope: SynchronizationScope,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64,
        coverageMode: CoverageProjectionMode
    ) async throws -> AccountOrganizationDurableState? {
        guard scope.accountID == vault.accountID else {
            throw AccountOrganizationDurableStateRepositoryError.accountScopeMismatch
        }
        guard schedule.accountID == scope.accountID,
              schedule.organizationID == scope.organizationID,
              schedule.credentialRevision == scope.credentialRevision,
              schedule.capabilityRevision == scope.capabilityRevision,
              schedule.generation == expectedGeneration,
              schedule.activeAttemptID == nil
        else {
            throw AccountOrganizationDurableStateRepositoryError.scheduleScopeMismatch
        }
        guard expectedGeneration <= UInt64(Int64.max) else {
            throw AccountOrganizationDurableStateRepositoryError.invalidGeneration
        }
        let candidateState = try Self.canonicalized(state, for: scope)

        return try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            let persistedCoverage = try CoverageRepository.currentRecords(
                for: scope,
                in: database
            )
            let stateToPersist: AccountOrganizationDurableState
            switch coverageMode {
            case .requireCandidateMatch:
                let projectedCoverage = candidateState.cachedState?.coverage ?? []
                guard Self.coverageSignatures(persistedCoverage)
                    == Self.coverageSignatures(projectedCoverage)
                else {
                    throw AccountOrganizationDurableStateRepositoryError.invalidProjection
                }
                stateToPersist = candidateState
            case .snapshotPersistedFailure:
                stateToPersist = try Self.failureProjection(
                    from: candidateState,
                    persistedCoverage: persistedCoverage,
                    for: scope
                )
            }
            let payload = try Self.encode(
                Envelope(
                    formatVersion: Self.formatVersion,
                    scope: scope,
                    durableState: stateToPersist
                )
            )
            guard try OrganizationSchedulerStateRepository.replace(
                schedule,
                ifOwnedBy: expectedAttemptID,
                generation: expectedGeneration,
                expectedAccountID: vault.accountID,
                in: database
            ) else {
                return nil
            }
            try Self.save(
                payload,
                scope: scope,
                schedulerGeneration: expectedGeneration,
                updatedAt: schedule.updatedAt,
                in: database
            )
            return stateToPersist
        }
    }

    private struct PersistedRow: Sendable {
        let scope: SynchronizationScope
        let schedulerGeneration: UInt64
        let payload: Data
    }

    private nonisolated static func fetch(
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws -> PersistedRow? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT account_id, organization_id, credential_revision,
                       capability_revision, scheduler_generation, format_version,
                       state_payload, updated_at_ms
                FROM account_organization_durable_states
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [accountID.rawValue, organizationID.rawValue]
        ) else {
            return nil
        }
        let schedulerGeneration: Int64? = row["scheduler_generation"]
        let persistedFormatVersion: Int? = row["format_version"]
        let updatedAtMilliseconds: Int64? = row["updated_at_ms"]
        guard let persistedAccountID = AccountID(rawValue: row["account_id"]),
              let persistedOrganizationID = OrganizationID(rawValue: row["organization_id"]),
              let credentialRevision = CredentialRevision(rawValue: row["credential_revision"]),
              let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"]),
              let schedulerGeneration,
              schedulerGeneration >= 0,
              persistedFormatVersion == Self.formatVersion,
              let payload: Data = row["state_payload"],
              payload.count <= maximumPayloadBytes,
              let updatedAtMilliseconds,
              date(milliseconds: updatedAtMilliseconds) != nil
        else {
            throw AccountOrganizationDurableStateRepositoryError.invalidPersistedData
        }
        return PersistedRow(
            scope: SynchronizationScope(
                accountID: persistedAccountID,
                organizationID: persistedOrganizationID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision
            ),
            schedulerGeneration: UInt64(schedulerGeneration),
            payload: payload
        )
    }

    private nonisolated static func save(
        _ payload: Data,
        scope: SynchronizationScope,
        schedulerGeneration: UInt64,
        updatedAt: Date,
        in database: Database
    ) throws {
        guard payload.count <= maximumPayloadBytes else {
            throw AccountOrganizationDurableStateRepositoryError.payloadTooLarge
        }
        guard schedulerGeneration <= UInt64(Int64.max) else {
            throw AccountOrganizationDurableStateRepositoryError.invalidGeneration
        }
        if let existingGeneration = try Int64.fetchOne(
            database,
            sql: """
                SELECT scheduler_generation
                FROM account_organization_durable_states
                WHERE account_id = ? AND organization_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                """,
            arguments: [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue
            ]
        ), existingGeneration > Int64(schedulerGeneration) {
            throw AccountOrganizationDurableStateRepositoryError.staleGeneration
        }
        try database.execute(
            sql: """
                INSERT INTO account_organization_durable_states (
                    account_id, organization_id, credential_revision,
                    capability_revision, scheduler_generation, format_version,
                    state_payload, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id, organization_id) DO UPDATE SET
                    credential_revision = excluded.credential_revision,
                    capability_revision = excluded.capability_revision,
                    scheduler_generation = excluded.scheduler_generation,
                    format_version = excluded.format_version,
                    state_payload = excluded.state_payload,
                    updated_at_ms = excluded.updated_at_ms
                """,
            arguments: [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue,
                Int64(schedulerGeneration),
                formatVersion,
                payload,
                try milliseconds(updatedAt)
            ]
        )
    }

    private nonisolated static func remove(
        accountID: AccountID,
        organizationID: OrganizationID,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                DELETE FROM account_organization_durable_states
                WHERE account_id = ? AND organization_id = ?
                """,
            arguments: [accountID.rawValue, organizationID.rawValue]
        )
    }

    private nonisolated static func validateCurrentScope(
        _ scope: SynchronizationScope,
        in database: Database
    ) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(
                scope,
                in: database
            )
        } catch OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw AccountOrganizationDurableStateRepositoryError.organizationScopeMismatch
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope {
            throw AccountOrganizationDurableStateRepositoryError.staleSynchronizationScope
        }
    }

    private nonisolated static func canonicalized(
        _ state: AccountOrganizationDurableState,
        for scope: SynchronizationScope
    ) throws -> AccountOrganizationDurableState {
        try validate(state, for: scope)
        let canonicalFreshness = FreshnessState(
            status: state.freshness.status,
            lastSuccessfulSyncAt: canonicalDate(state.freshness.lastSuccessfulSyncAt),
            nextRetryAt: canonicalDate(state.freshness.nextRetryAt),
            detail: state.freshness.detail
        )
        guard let cachedState = state.cachedState else {
            return AccountOrganizationDurableState(
                cachedState: nil,
                freshness: canonicalFreshness
            )
        }
        let sortedCoverage = cachedState.coverage.map { record in
            CoverageRecord(
                accountID: record.accountID,
                organizationID: record.organizationID,
                repositoryID: record.repositoryID,
                feature: record.feature,
                streamID: record.streamID,
                intervalStart: canonicalDate(record.intervalStart),
                intervalEnd: canonicalDate(record.intervalEnd),
                credentialRevision: record.credentialRevision,
                capabilityRevision: record.capabilityRevision,
                status: record.status,
                lastSuccessfulAt: canonicalDate(record.lastSuccessfulAt),
                failureDetail: record.failureDetail
            )
        }.sorted {
            coverageSignature($0) < coverageSignature($1)
        }
        let sortedRequirements = cachedState.coverageRequirements?.map { requirement in
            CoverageRequirement(
                feature: requirement.feature,
                repositoryID: requirement.repositoryID,
                streamID: requirement.streamID,
                intervalStart: canonicalDate(requirement.intervalStart),
                intervalEnd: canonicalDate(requirement.intervalEnd)
            )
        }.sorted {
            coverageRequirementIdentity($0) < coverageRequirementIdentity($1)
        }
        let canonicalState = AccountOrganizationDurableState(
            cachedState: AccountOrganizationCachedState(
                coverage: sortedCoverage,
                coverageRequirements: sortedRequirements,
                lastSuccessfulSyncAt: canonicalDate(cachedState.lastSuccessfulSyncAt)
            ),
            freshness: canonicalFreshness
        )
        try validate(canonicalState, for: scope)
        return canonicalState
    }

    private nonisolated static func failureProjection(
        from candidate: AccountOrganizationDurableState,
        persistedCoverage: [CoverageRecord],
        for scope: SynchronizationScope
    ) throws -> AccountOrganizationDurableState {
        guard candidate.freshness.status != .fresh,
              candidate.freshness.status != .refreshing
        else {
            throw AccountOrganizationDurableStateRepositoryError.invalidProjection
        }
        guard !persistedCoverage.isEmpty else {
            guard candidate.cachedState?.coverage.isEmpty != false else {
                throw AccountOrganizationDurableStateRepositoryError.invalidProjection
            }
            return try canonicalized(
                AccountOrganizationDurableState(
                    cachedState: nil,
                    freshness: FreshnessState(
                        status: candidate.freshness.status,
                        lastSuccessfulSyncAt: nil,
                        nextRetryAt: candidate.freshness.nextRetryAt,
                        detail: candidate.freshness.detail
                    )
                ),
                for: scope
            )
        }
        let latestSuccessfulAt = persistedCoverage
            .compactMap(\.lastSuccessfulAt)
            .compactMap(canonicalMilliseconds)
            .max()
            .flatMap { date(milliseconds: $0) }
        return try canonicalized(
            AccountOrganizationDurableState(
                cachedState: AccountOrganizationCachedState(
                    coverage: persistedCoverage,
                    coverageRequirements: candidate.cachedState?.coverageRequirements,
                    lastSuccessfulSyncAt: latestSuccessfulAt
                ),
                freshness: FreshnessState(
                    status: candidate.freshness.status,
                    lastSuccessfulSyncAt: latestSuccessfulAt,
                    nextRetryAt: candidate.freshness.nextRetryAt,
                    detail: candidate.freshness.detail
                )
            ),
            for: scope
        )
    }

    private nonisolated static func validate(
        _ state: AccountOrganizationDurableState,
        for scope: SynchronizationScope
    ) throws {
        guard state.freshness.status != .refreshing,
              Self.valid(state.freshness.lastSuccessfulSyncAt),
              Self.valid(state.freshness.nextRetryAt),
              Self.validDetail(state.freshness.detail)
        else {
            throw AccountOrganizationDurableStateRepositoryError.invalidProjection
        }
        guard let cachedState = state.cachedState else {
            guard state.freshness.status != .fresh,
                  state.freshness.lastSuccessfulSyncAt == nil
            else {
                throw AccountOrganizationDurableStateRepositoryError.invalidProjection
            }
            return
        }
        guard cachedState.coverage.count <= maximumCoverageRecordCount,
              (cachedState.coverageRequirements?.count ?? 0) <= maximumCoverageRecordCount,
              valid(cachedState.lastSuccessfulSyncAt)
        else {
            throw AccountOrganizationDurableStateRepositoryError.invalidProjection
        }
        guard !cachedState.coverage.isEmpty else {
            guard cachedState.lastSuccessfulSyncAt == nil,
                  state.freshness.status == .stale,
                  state.freshness.lastSuccessfulSyncAt == nil,
                  state.freshness.nextRetryAt == nil
            else {
                throw AccountOrganizationDurableStateRepositoryError.invalidProjection
            }
            return
        }
        for record in cachedState.coverage {
            guard record.accountID == scope.accountID,
                  record.organizationID == scope.organizationID,
                  record.credentialRevision == scope.credentialRevision,
                  record.capabilityRevision == scope.capabilityRevision,
                  (record.intervalStart == nil) == (record.intervalEnd == nil),
                  record.intervalStart.map({ $0 <= record.intervalEnd! }) ?? true,
                  valid(record.intervalStart),
                  valid(record.intervalEnd),
                  valid(record.lastSuccessfulAt),
                  validDetail(record.failureDetail)
            else {
                throw AccountOrganizationDurableStateRepositoryError.invalidProjection
            }
        }
        let identities = cachedState.coverage.map(coverageIdentity)
        guard Set(identities).count == identities.count else {
            throw AccountOrganizationDurableStateRepositoryError.invalidProjection
        }
        if let requirements = cachedState.coverageRequirements {
            for requirement in requirements {
                guard (requirement.intervalStart == nil) == (requirement.intervalEnd == nil),
                      requirement.intervalStart.map({ $0 <= requirement.intervalEnd! }) ?? true,
                      valid(requirement.intervalStart),
                      valid(requirement.intervalEnd)
                else {
                    throw AccountOrganizationDurableStateRepositoryError.invalidProjection
                }
            }
            let requirementIdentities = requirements.map(coverageRequirementIdentity)
            guard Set(requirementIdentities).count == requirementIdentities.count else {
                throw AccountOrganizationDurableStateRepositoryError.invalidProjection
            }
        }
        let latestCoverageSuccess = cachedState.coverage
            .compactMap(\.lastSuccessfulAt)
            .compactMap(canonicalMilliseconds)
            .max()
        guard cachedState.lastSuccessfulSyncAt.flatMap(canonicalMilliseconds)
            == latestCoverageSuccess,
              state.freshness.lastSuccessfulSyncAt.flatMap(canonicalMilliseconds)
                == latestCoverageSuccess
        else {
            throw AccountOrganizationDurableStateRepositoryError.invalidProjection
        }
        if state.freshness.status == .fresh,
           cachedState.freshness.status != .fresh {
            throw AccountOrganizationDurableStateRepositoryError.invalidProjection
        }
    }

    private nonisolated static func encode(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload: Data
        do {
            payload = try encoder.encode(envelope)
        } catch {
            throw AccountOrganizationDurableStateRepositoryError.invalidProjection
        }
        guard payload.count <= maximumPayloadBytes else {
            throw AccountOrganizationDurableStateRepositoryError.payloadTooLarge
        }
        return payload
    }

    private nonisolated static func decode(_ payload: Data) throws -> Envelope {
        guard payload.count <= maximumPayloadBytes else {
            throw AccountOrganizationDurableStateRepositoryError.invalidPersistedData
        }
        do {
            return try JSONDecoder().decode(Envelope.self, from: payload)
        } catch {
            throw AccountOrganizationDurableStateRepositoryError.invalidPersistedData
        }
    }

    private nonisolated static func valid(_ date: Date?) -> Bool {
        guard let date else { return true }
        return canonicalMilliseconds(date) != nil
    }

    private nonisolated static func validDetail(_ detail: String?) -> Bool {
        guard let detail else { return true }
        guard detail.utf8.count <= maximumDetailBytes else { return false }
        let lowercase = detail.lowercased()
        let forbiddenFragments = [
            "authorization:", "authorization=", "proxy-authorization",
            "cookie:", "set-cookie:", "bearer ", "basic ", "password",
            "passwd", "client_secret", "access_token", "refresh_token",
            "api_key", "apikey", "private key", "ghp_", "gho_", "ghu_",
            "ghs_", "ghr_", "github_pat_", "glpat-", "xoxb-", "xoxp-"
        ]
        guard !forbiddenFragments.contains(where: lowercase.contains) else {
            return false
        }
        let range = NSRange(detail.startIndex..<detail.endIndex, in: detail)
        let urlLikePatterns = [
            #"(?i)\b[a-z][a-z0-9+.-]*:(?://)?[^\s]+"#,
            #"(?i)(?:^|[^a-z0-9-])(?:[a-z0-9-]+\.)+[a-z]{2,63}(?:[/?:#][^\s]*)?"#
        ]
        for pattern in urlLikePatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return false
            }
            if expression.firstMatch(in: detail, options: [], range: range) != nil {
                return false
            }
        }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return false
        }
        return detector.firstMatch(in: detail, options: [], range: range) == nil
    }

    private nonisolated static func coverageSignatures(
        _ records: [CoverageRecord]
    ) -> [String] {
        records.map(coverageSignature).sorted()
    }

    private nonisolated static func coverageIdentity(
        _ record: CoverageRecord
    ) -> String {
        canonicalFields([
            record.accountID.rawValue,
            record.organizationID.rawValue,
            record.repositoryID?.rawValue ?? "",
            record.feature.rawValue,
            record.streamID.rawValue,
            record.intervalStart.flatMap(canonicalMilliseconds).map(String.init) ?? "",
            record.intervalEnd.flatMap(canonicalMilliseconds).map(String.init) ?? "",
            record.credentialRevision.rawValue,
            record.capabilityRevision.rawValue
        ])
    }

    private nonisolated static func coverageSignature(
        _ record: CoverageRecord
    ) -> String {
        canonicalFields([
            coverageIdentity(record),
            record.status.rawValue,
            record.lastSuccessfulAt.flatMap(canonicalMilliseconds).map(String.init) ?? "",
            record.failureDetail ?? ""
        ])
    }

    private nonisolated static func coverageRequirementIdentity(
        _ requirement: CoverageRequirement
    ) -> String {
        canonicalFields([
            requirement.repositoryID?.rawValue ?? "",
            requirement.feature.rawValue,
            requirement.streamID.rawValue,
            requirement.intervalStart.flatMap(canonicalMilliseconds).map(String.init) ?? "",
            requirement.intervalEnd.flatMap(canonicalMilliseconds).map(String.init) ?? ""
        ])
    }

    private nonisolated static func canonicalFields(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private nonisolated static func interrupted(
        _ state: AccountOrganizationDurableState
    ) -> AccountOrganizationDurableState {
        AccountOrganizationDurableState(
            cachedState: state.cachedState,
            freshness: FreshnessState(
                status: .stale,
                lastSuccessfulSyncAt: state.freshness.lastSuccessfulSyncAt,
                detail: "A previous synchronization did not complete. Cached data is retained."
            )
        )
    }

    private nonisolated static func canonicalMilliseconds(_ date: Date) -> Int64? {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        let roundedMilliseconds = milliseconds.rounded()
        guard roundedMilliseconds.isFinite,
              roundedMilliseconds >= -0x1p63,
              roundedMilliseconds < 0x1p63
        else {
            return nil
        }
        return Int64(roundedMilliseconds)
    }

    private nonisolated static func canonicalDate(_ date: Date?) -> Date? {
        guard let date,
              let milliseconds = canonicalMilliseconds(date)
        else {
            return nil
        }
        return Self.date(milliseconds: milliseconds)
    }

    private nonisolated static func milliseconds(_ date: Date) throws -> Int64 {
        guard let milliseconds = canonicalMilliseconds(date) else {
            throw AccountOrganizationDurableStateRepositoryError.invalidProjection
        }
        return milliseconds
    }

    private nonisolated static func date(milliseconds: Int64) -> Date? {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        return date.timeIntervalSince1970.isFinite ? date : nil
    }
}

extension AccountOrganizationDurableStateRepository: AccountOrganizationCachedStateStoring {}
extension AccountOrganizationDurableStateRepository: AccountOrganizationRefreshFinalizing {}
