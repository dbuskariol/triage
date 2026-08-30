import Foundation
import GRDB

enum SourceAccessObservationRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleSynchronizationScope
    case streamScopeMismatch
    case targetScopeMismatch
    case sourceProvenanceScopeMismatch
    case rawSnapshotScopeMismatch
    case invalidIdentifier
    case invalidSourceLocator
    case invalidSourceRevision
    case invalidTimestamp
    case invalidResultReason
    case invalidDeletionAuthority
    case missingAuthoritativeDeletionCoverage
    case missingAuthoritativeDeletionReceipt
    case staleObservation
    case conflictingObservation
    case invalidLimit
    case invalidPersistedData
}

actor SourceAccessObservationRepository {
    static let maximumHistoryCount = 1_000

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    @discardableResult
    func record(_ observation: SourceAccessObservation) async throws -> SourceAccessProjection {
        try await vault.writeTransaction { database in
            try Self.record(
                observation,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    func projection(
        for target: SourceAccessTarget,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        scope: SynchronizationScope
    ) async throws -> SourceAccessProjection? {
        guard scope.accountID == vault.accountID else {
            throw SourceAccessObservationRepositoryError.accountScopeMismatch
        }
        guard Self.boundedIdentifier(streamID.rawValue) else {
            throw SourceAccessObservationRepositoryError.invalidIdentifier
        }
        return try await vault.read { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validate(target: target, scope: scope, in: database)
            return try Self.fetchProjection(
                target: target,
                feature: feature,
                streamID: streamID,
                scope: scope,
                in: database
            )
        }
    }

    func history(
        for target: SourceAccessTarget,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        scope: SynchronizationScope,
        limit: Int = 100
    ) async throws -> [SourceAccessObservation] {
        guard scope.accountID == vault.accountID else {
            throw SourceAccessObservationRepositoryError.accountScopeMismatch
        }
        guard Self.boundedIdentifier(streamID.rawValue) else {
            throw SourceAccessObservationRepositoryError.invalidIdentifier
        }
        guard (0...Self.maximumHistoryCount).contains(limit) else {
            throw SourceAccessObservationRepositoryError.invalidLimit
        }
        return try await vault.read { database in
            try Self.validateCurrentScope(scope, in: database)
            try Self.validate(target: target, scope: scope, in: database)
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT id, account_id, organization_id, credential_revision,
                           capability_revision, feature, stream_id, target_kind, target_id,
                           source_locator_kind, source_locator, source_node_id,
                           source_event_id, source_revision, raw_snapshot_id, result, reason,
                           authority, confirmation, observed_at_ms
                    FROM source_access_observations
                    WHERE account_id = ? AND organization_id = ?
                      AND credential_revision = ? AND capability_revision = ?
                      AND feature = ? AND stream_id = ?
                      AND target_kind = ? AND target_id = ?
                    ORDER BY observed_at_ms DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [
                    scope.accountID.rawValue,
                    scope.organizationID.rawValue,
                    scope.credentialRevision.rawValue,
                    scope.capabilityRevision.rawValue,
                    feature.rawValue,
                    streamID.rawValue,
                    target.kind.rawValue,
                    target.rawValue,
                    limit
                ]
            ).map(Self.observation(from:))
        }
    }

    nonisolated static func record(
        _ observation: SourceAccessObservation,
        expectedAccountID: AccountID,
        in database: Database
    ) throws -> SourceAccessProjection {
        let canonicalObservation = try canonicalized(observation)
        guard canonicalObservation.scope.accountID == expectedAccountID else {
            throw SourceAccessObservationRepositoryError.accountScopeMismatch
        }
        try validate(canonicalObservation)
        try validateCurrentScope(canonicalObservation.scope, in: database)
        try validateStream(canonicalObservation, in: database)
        try validate(
            target: canonicalObservation.target,
            scope: canonicalObservation.scope,
            in: database
        )
        try validateSourceProvenance(canonicalObservation, in: database)
        try validateRawSnapshot(canonicalObservation, in: database)
        try validateAuthoritativeDeletionCoverage(canonicalObservation, in: database)
        let observedAtMilliseconds = try milliseconds(canonicalObservation.observedAt)

        if let existing = try fetchObservation(id: canonicalObservation.id, in: database) {
            guard existing == canonicalObservation else {
                throw SourceAccessObservationRepositoryError.conflictingObservation
            }
            guard let currentProjection = try fetchProjection(
                target: canonicalObservation.target,
                feature: canonicalObservation.feature,
                streamID: canonicalObservation.streamID,
                scope: canonicalObservation.scope,
                includeAnyRevision: true,
                in: database
            ) else {
                throw SourceAccessObservationRepositoryError.invalidPersistedData
            }
            return currentProjection
        }

        if let current = try fetchProjection(
            target: canonicalObservation.target,
            feature: canonicalObservation.feature,
            streamID: canonicalObservation.streamID,
            scope: canonicalObservation.scope,
            includeAnyRevision: true,
            in: database
        ) {
            if canonicalObservation.observedAt < current.observedAt {
                throw SourceAccessObservationRepositoryError.staleObservation
            }
            if canonicalObservation.observedAt == current.observedAt,
               canonicalObservation.scope.credentialRevision
                == current.scope.credentialRevision,
               canonicalObservation.scope.capabilityRevision
                == current.scope.capabilityRevision {
                throw SourceAccessObservationRepositoryError.conflictingObservation
            }
        }

        try database.execute(
            sql: """
                INSERT INTO source_access_observations (
                    id, account_id, organization_id, credential_revision,
                    capability_revision, feature, stream_id, target_kind, target_id,
                    source_locator_kind, source_locator, source_node_id, source_event_id,
                    source_revision, raw_snapshot_id, result, reason, authority,
                    confirmation, observed_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: canonicalObservation.arguments(
                observedAtMilliseconds: observedAtMilliseconds
            )
        )
        try database.execute(
            sql: """
                INSERT INTO source_access_projections (
                    account_id, organization_id, credential_revision, capability_revision,
                    feature, stream_id, target_kind, target_id, result,
                    winning_observation_id, observed_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(
                    account_id, organization_id, feature, stream_id, target_kind, target_id
                ) DO UPDATE SET
                    credential_revision = excluded.credential_revision,
                    capability_revision = excluded.capability_revision,
                    result = excluded.result,
                    winning_observation_id = excluded.winning_observation_id,
                    observed_at_ms = excluded.observed_at_ms
                WHERE source_access_projections.observed_at_ms < excluded.observed_at_ms
                   OR (
                       source_access_projections.observed_at_ms = excluded.observed_at_ms
                       AND (
                           source_access_projections.credential_revision
                               != excluded.credential_revision
                           OR source_access_projections.capability_revision
                               != excluded.capability_revision
                       )
                   )
                """,
            arguments: [
                canonicalObservation.scope.accountID.rawValue,
                canonicalObservation.scope.organizationID.rawValue,
                canonicalObservation.scope.credentialRevision.rawValue,
                canonicalObservation.scope.capabilityRevision.rawValue,
                canonicalObservation.feature.rawValue,
                canonicalObservation.streamID.rawValue,
                canonicalObservation.target.kind.rawValue,
                canonicalObservation.target.rawValue,
                canonicalObservation.result.rawValue,
                canonicalObservation.id.rawValue,
                observedAtMilliseconds
            ]
        )
        guard database.changesCount == 1 else {
            throw SourceAccessObservationRepositoryError.staleObservation
        }
        return canonicalObservation.projection
    }

    private nonisolated static func validate(_ observation: SourceAccessObservation) throws {
        guard boundedIdentifier(observation.scope.accountID.rawValue),
              boundedIdentifier(observation.scope.organizationID.rawValue),
              boundedIdentifier(observation.scope.credentialRevision.rawValue),
              boundedIdentifier(observation.scope.capabilityRevision.rawValue),
              boundedIdentifier(observation.streamID.rawValue),
              boundedIdentifier(observation.target.rawValue),
              observation.sourceNodeID.map({ boundedIdentifier($0.rawValue) }) ?? true,
              observation.sourceEventID.map({ boundedIdentifier($0.rawValue) }) ?? true,
              observation.rawSnapshotID.map({ boundedIdentifier($0.rawValue) }) ?? true
        else {
            throw SourceAccessObservationRepositoryError.invalidIdentifier
        }
        guard boundedSource(observation.source.value, maximumCount: 2_048) else {
            throw SourceAccessObservationRepositoryError.invalidSourceLocator
        }
        guard boundedSource(observation.sourceRevision, maximumCount: 500) else {
            throw SourceAccessObservationRepositoryError.invalidSourceRevision
        }
        _ = try milliseconds(observation.observedAt)

        switch (observation.result, observation.reason) {
        case (.accessible, .directResponse),
             (.inaccessible, .privateNotFound),
             (.inaccessible, .forbidden),
             (.inaccessible, .ssoRequired),
             (.inaccessible, .approvalRequired),
             (.unknown, .inventoryOmission),
             (.authoritativelyDeleted, .authoritativeOmission),
             (.authoritativelyDeleted, .immutableIdentityReplacement):
            break
        default:
            throw SourceAccessObservationRepositoryError.invalidResultReason
        }
        if observation.result == .authoritativelyDeleted,
           observation.authority != .fullReconciliation
            || observation.confirmation != .confirmed {
            throw SourceAccessObservationRepositoryError.invalidDeletionAuthority
        }
        if observation.result == .unknown,
           observation.confirmation != .provisional {
            throw SourceAccessObservationRepositoryError.invalidResultReason
        }
    }

    private nonisolated static func validateCurrentScope(
        _ scope: SynchronizationScope,
        in database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM accounts
                JOIN account_organizations
                  ON account_organizations.account_id = accounts.id
                WHERE accounts.id = ?
                  AND account_organizations.organization_id = ?
                  AND accounts.credential_revision = ?
                  AND account_organizations.capability_revision = ?
                """,
            arguments: [
                scope.accountID.rawValue,
                scope.organizationID.rawValue,
                scope.credentialRevision.rawValue,
                scope.capabilityRevision.rawValue
            ]
        ) ?? 0
        guard count == 1 else {
            throw SourceAccessObservationRepositoryError.staleSynchronizationScope
        }
    }

    private nonisolated static func validateStream(
        _ observation: SourceAccessObservation,
        in database: Database
    ) throws {
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM sync_streams
                WHERE id = ? AND account_id = ? AND organization_id = ? AND feature = ?
                """,
            arguments: [
                observation.streamID.rawValue,
                observation.scope.accountID.rawValue,
                observation.scope.organizationID.rawValue,
                observation.feature.rawValue
            ]
        ) ?? 0
        guard count == 1 else {
            throw SourceAccessObservationRepositoryError.streamScopeMismatch
        }
    }

    private nonisolated static func validateAuthoritativeDeletionCoverage(
        _ observation: SourceAccessObservation,
        in database: Database
    ) throws {
        guard observation.result == .authoritativelyDeleted else { return }
        let count = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM coverage_records
                WHERE account_id = ? AND organization_id = ?
                  AND feature = ? AND stream_id = ?
                  AND credential_revision = ? AND capability_revision = ?
                  AND status = ? AND last_successful_at_ms = ?
                  AND repository_id IS NULL
                  AND interval_start_ms IS NULL AND interval_end_ms IS NULL
                """,
            arguments: [
                observation.scope.accountID.rawValue,
                observation.scope.organizationID.rawValue,
                observation.feature.rawValue,
                observation.streamID.rawValue,
                observation.scope.credentialRevision.rawValue,
                observation.scope.capabilityRevision.rawValue,
                CoverageStatus.complete.rawValue,
                try milliseconds(observation.observedAt)
            ]
        ) ?? 0
        guard count > 0 else {
            throw SourceAccessObservationRepositoryError.missingAuthoritativeDeletionCoverage
        }
    }

    private nonisolated static func validate(
        target: SourceAccessTarget,
        scope: SynchronizationScope,
        in database: Database
    ) throws {
        let count: Int
        switch target {
        case let .repository(repositoryID):
            count = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM repositories
                    JOIN account_repository_access
                      ON account_repository_access.repository_id = repositories.id
                    WHERE repositories.id = ? AND repositories.organization_id = ?
                      AND account_repository_access.account_id = ?
                    """,
                arguments: [
                    repositoryID.rawValue,
                    scope.organizationID.rawValue,
                    scope.accountID.rawValue
                ]
            ) ?? 0
        case let .githubNode(nodeID):
            count = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM github_nodes
                    WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                    """,
                arguments: [
                    nodeID.rawValue,
                    scope.accountID.rawValue,
                    scope.organizationID.rawValue
                ]
            ) ?? 0
        case let .team(teamID):
            count = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM teams
                    WHERE id = ? AND organization_id = ?
                    """,
                arguments: [teamID.rawValue, scope.organizationID.rawValue]
            ) ?? 0
        }
        guard count == 1 else {
            throw SourceAccessObservationRepositoryError.targetScopeMismatch
        }
    }

    private nonisolated static func validateRawSnapshot(
        _ observation: SourceAccessObservation,
        in database: Database
    ) throws {
        guard let rawSnapshotID = observation.rawSnapshotID else {
            if observation.result == .authoritativelyDeleted {
                throw SourceAccessObservationRepositoryError
                    .missingAuthoritativeDeletionReceipt
            }
            return
        }
        let locatorClause: String
        switch observation.source.kind {
        case .endpoint:
            locatorClause = "endpoint = ?"
        case .query:
            locatorClause = "authority_request_key = ?"
        }
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT github_node_id
                FROM raw_api_snapshots
                WHERE id = ? AND account_id = ?
                  AND authority_organization_id = ?
                  AND authority_feature = ? AND authority_stream_id = ?
                  AND authority_credential_revision = ?
                  AND authority_capability_revision = ?
                  AND observed_at_ms = ? AND \(locatorClause)
                """,
            arguments: [
                rawSnapshotID.rawValue,
                observation.scope.accountID.rawValue,
                observation.scope.organizationID.rawValue,
                observation.feature.rawValue,
                observation.streamID.rawValue,
                observation.scope.credentialRevision.rawValue,
                observation.scope.capabilityRevision.rawValue,
                try milliseconds(observation.observedAt),
                observation.source.value
            ]
        ) else {
            throw SourceAccessObservationRepositoryError.rawSnapshotScopeMismatch
        }
        let snapshotNodeValue: String? = row["github_node_id"]
        if let snapshotNodeValue,
           snapshotNodeValue != observation.sourceNodeID?.rawValue {
            throw SourceAccessObservationRepositoryError.rawSnapshotScopeMismatch
        }
    }

    private nonisolated static func validateSourceProvenance(
        _ observation: SourceAccessObservation,
        in database: Database
    ) throws {
        if let sourceNodeID = observation.sourceNodeID {
            let count = try Int.fetchOne(
                database,
                sql: """
                    SELECT (
                        EXISTS (
                            SELECT 1 FROM github_nodes
                            WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                        )
                        OR EXISTS (
                            SELECT 1
                            FROM repositories
                            JOIN account_repository_access
                              ON account_repository_access.repository_id = repositories.id
                            WHERE repositories.github_node_id = ?
                              AND repositories.organization_id = ?
                              AND account_repository_access.account_id = ?
                        )
                        OR EXISTS (
                            SELECT 1 FROM teams
                            WHERE github_node_id = ? AND organization_id = ?
                        )
                    )
                    """,
                arguments: [
                    sourceNodeID.rawValue,
                    observation.scope.accountID.rawValue,
                    observation.scope.organizationID.rawValue,
                    sourceNodeID.rawValue,
                    observation.scope.organizationID.rawValue,
                    observation.scope.accountID.rawValue,
                    sourceNodeID.rawValue,
                    observation.scope.organizationID.rawValue
                ]
            ) ?? 0
            guard count == 1 else {
                throw SourceAccessObservationRepositoryError.sourceProvenanceScopeMismatch
            }
        }

        if let sourceEventID = observation.sourceEventID {
            guard let subjectNodeValue = try String.fetchOne(
                database,
                sql: """
                    SELECT timeline_events.subject_node_id
                    FROM timeline_events
                    JOIN github_nodes
                      ON github_nodes.github_node_id = timeline_events.subject_node_id
                    WHERE timeline_events.github_event_id = ?
                      AND github_nodes.account_id = ? AND github_nodes.organization_id = ?
                    """,
                arguments: [
                    sourceEventID.rawValue,
                    observation.scope.accountID.rawValue,
                    observation.scope.organizationID.rawValue
                ]
            ) else {
                throw SourceAccessObservationRepositoryError.sourceProvenanceScopeMismatch
            }
            if let sourceNodeID = observation.sourceNodeID,
               sourceNodeID.rawValue != subjectNodeValue {
                throw SourceAccessObservationRepositoryError.sourceProvenanceScopeMismatch
            }
        }
    }

    private nonisolated static func fetchObservation(
        id: SourceAccessObservationID,
        in database: Database
    ) throws -> SourceAccessObservation? {
        try Row.fetchOne(
            database,
            sql: """
                SELECT id, account_id, organization_id, credential_revision,
                       capability_revision, feature, stream_id, target_kind, target_id,
                       source_locator_kind, source_locator, source_node_id, source_event_id,
                       source_revision, raw_snapshot_id, result, reason, authority,
                       confirmation, observed_at_ms
                FROM source_access_observations WHERE id = ?
                """,
            arguments: [id.rawValue]
        ).map { try observation(from: $0) }
    }

    private nonisolated static func fetchProjection(
        target: SourceAccessTarget,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        scope: SynchronizationScope,
        includeAnyRevision: Bool = false,
        in database: Database
    ) throws -> SourceAccessProjection? {
        let revisionClause = includeAnyRevision ? "" : """
            AND credential_revision = ? AND capability_revision = ?
            """
        var arguments: [DatabaseValueConvertible?] = [
            scope.accountID.rawValue,
            scope.organizationID.rawValue,
            feature.rawValue,
            streamID.rawValue,
            target.kind.rawValue,
            target.rawValue
        ]
        if !includeAnyRevision {
            arguments.append(scope.credentialRevision.rawValue)
            arguments.append(scope.capabilityRevision.rawValue)
        }
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT account_id, organization_id, credential_revision, capability_revision,
                       feature, stream_id, target_kind, target_id, result,
                       winning_observation_id, observed_at_ms
                FROM source_access_projections
                WHERE account_id = ? AND organization_id = ?
                  AND feature = ? AND stream_id = ?
                  AND target_kind = ? AND target_id = ?
                  \(revisionClause)
                """,
            arguments: StatementArguments(arguments)
        ) else {
            return nil
        }
        let projection = try projection(from: row)
        guard let winningObservation = try fetchObservation(
            id: projection.winningObservationID,
            in: database
        ),
        winningObservation.projection == projection
        else {
            throw SourceAccessObservationRepositoryError.invalidPersistedData
        }
        return projection
    }

    private nonisolated static func observation(from row: Row) throws -> SourceAccessObservation {
        guard let id = SourceAccessObservationID(rawValue: row["id"]),
              let accountID = AccountID(rawValue: row["account_id"]),
              let organizationID = OrganizationID(rawValue: row["organization_id"]),
              let credentialRevision = CredentialRevision(rawValue: row["credential_revision"]),
              let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"]),
              let feature = CoverageFeature(rawValue: row["feature"]),
              let streamID = SyncStreamID(rawValue: row["stream_id"]),
              let targetKind = SourceAccessTargetKind(rawValue: row["target_kind"]),
              let target = SourceAccessTarget(kind: targetKind, rawValue: row["target_id"]),
              let locatorKind = SourceAccessLocatorKind(rawValue: row["source_locator_kind"]),
              let locatorValue: String = row["source_locator"],
              let sourceRevision: String = row["source_revision"],
              let result = SourceAccessResult(rawValue: row["result"]),
              let reason = SourceAccessReason(rawValue: row["reason"]),
              let authority = SourceAccessAuthority(rawValue: row["authority"]),
              let confirmation = SourceAccessConfirmation(rawValue: row["confirmation"]),
              let observedAtMilliseconds: Int64 = row["observed_at_ms"]
        else {
            throw SourceAccessObservationRepositoryError.invalidPersistedData
        }
        let sourceNodeValue: String? = row["source_node_id"]
        let sourceEventValue: String? = row["source_event_id"]
        let rawSnapshotValue: String? = row["raw_snapshot_id"]
        let sourceNodeID = sourceNodeValue.flatMap(GitHubNodeID.init(rawValue:))
        let sourceEventID = sourceEventValue.flatMap(GitHubEventID.init(rawValue:))
        let rawSnapshotID = rawSnapshotValue.flatMap(RawAPISnapshotID.init(rawValue:))
        guard sourceNodeValue == nil || sourceNodeID != nil,
              sourceEventValue == nil || sourceEventID != nil,
              rawSnapshotValue == nil || rawSnapshotID != nil
        else {
            throw SourceAccessObservationRepositoryError.invalidPersistedData
        }
        let observation = SourceAccessObservation(
            id: id,
            scope: SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision
            ),
            feature: feature,
            streamID: streamID,
            target: target,
            source: SourceAccessLocator(kind: locatorKind, value: locatorValue),
            sourceNodeID: sourceNodeID,
            sourceEventID: sourceEventID,
            sourceRevision: sourceRevision,
            rawSnapshotID: rawSnapshotID,
            result: result,
            reason: reason,
            authority: authority,
            confirmation: confirmation,
            observedAt: date(milliseconds: observedAtMilliseconds)
        )
        do {
            try validate(observation)
        } catch {
            throw SourceAccessObservationRepositoryError.invalidPersistedData
        }
        return observation
    }

    private nonisolated static func projection(from row: Row) throws -> SourceAccessProjection {
        guard let accountID = AccountID(rawValue: row["account_id"]),
              let organizationID = OrganizationID(rawValue: row["organization_id"]),
              let credentialRevision = CredentialRevision(rawValue: row["credential_revision"]),
              let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"]),
              let feature = CoverageFeature(rawValue: row["feature"]),
              let streamID = SyncStreamID(rawValue: row["stream_id"]),
              let targetKind = SourceAccessTargetKind(rawValue: row["target_kind"]),
              let target = SourceAccessTarget(kind: targetKind, rawValue: row["target_id"]),
              let result = SourceAccessResult(rawValue: row["result"]),
              let winningObservationID = SourceAccessObservationID(
                  rawValue: row["winning_observation_id"]
              ),
              let observedAtMilliseconds: Int64 = row["observed_at_ms"]
        else {
            throw SourceAccessObservationRepositoryError.invalidPersistedData
        }
        return SourceAccessProjection(
            scope: SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision
            ),
            feature: feature,
            streamID: streamID,
            target: target,
            result: result,
            winningObservationID: winningObservationID,
            observedAt: date(milliseconds: observedAtMilliseconds)
        )
    }

    private nonisolated static func boundedIdentifier(_ value: String) -> Bool {
        (1...512).contains(value.count)
            && value.unicodeScalars.allSatisfy { !$0.properties.isWhitespace }
    }

    private nonisolated static func boundedSource(_ value: String, maximumCount: Int) -> Bool {
        (1...maximumCount).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F
            }
    }

    private nonisolated static func milliseconds(_ date: Date) throws -> Int64 {
        let interval = date.timeIntervalSince1970
        guard interval.isFinite else {
            throw SourceAccessObservationRepositoryError.invalidTimestamp
        }
        let milliseconds = interval * 1_000
        let roundedMilliseconds = milliseconds.rounded()
        guard roundedMilliseconds.isFinite,
              roundedMilliseconds >= Double(Int64.min),
              roundedMilliseconds < Double(Int64.max)
        else {
            throw SourceAccessObservationRepositoryError.invalidTimestamp
        }
        return Int64(roundedMilliseconds)
    }

    private nonisolated static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private nonisolated static func canonicalized(
        _ observation: SourceAccessObservation
    ) throws -> SourceAccessObservation {
        SourceAccessObservation(
            id: observation.id,
            scope: observation.scope,
            feature: observation.feature,
            streamID: observation.streamID,
            target: observation.target,
            source: observation.source,
            sourceNodeID: observation.sourceNodeID,
            sourceEventID: observation.sourceEventID,
            sourceRevision: observation.sourceRevision,
            rawSnapshotID: observation.rawSnapshotID,
            result: observation.result,
            reason: observation.reason,
            authority: observation.authority,
            confirmation: observation.confirmation,
            observedAt: date(milliseconds: try milliseconds(observation.observedAt))
        )
    }
}

private extension SourceAccessObservation {
    var projection: SourceAccessProjection {
        SourceAccessProjection(
            scope: scope,
            feature: feature,
            streamID: streamID,
            target: target,
            result: result,
            winningObservationID: id,
            observedAt: observedAt
        )
    }

    func arguments(observedAtMilliseconds: Int64) -> StatementArguments {
        [
            id.rawValue,
            scope.accountID.rawValue,
            scope.organizationID.rawValue,
            scope.credentialRevision.rawValue,
            scope.capabilityRevision.rawValue,
            feature.rawValue,
            streamID.rawValue,
            target.kind.rawValue,
            target.rawValue,
            source.kind.rawValue,
            source.value,
            sourceNodeID?.rawValue,
            sourceEventID?.rawValue,
            sourceRevision,
            rawSnapshotID?.rawValue,
            result.rawValue,
            reason.rawValue,
            authority.rawValue,
            confirmation.rawValue,
            observedAtMilliseconds
        ]
    }
}
