import Foundation
import GRDB

enum StatusCheckRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleSynchronizationScope
    case pullRequestScopeMismatch
    case stalePullRequestRevision
    case invalidSourceRevision
    case invalidRecord
    case duplicateContext
    case incompleteCoverage
    case invalidPersistedData
}

struct StatusCheckAuthority: Sendable {
    let scope: SynchronizationScope
    let pullRequestNodeID: GitHubNodeID
    /// The immutable `github_nodes.source_revision` observed before the
    /// network traversal. A later hydration makes this source stale rather
    /// than allowing it to replace the current PR rollup.
    let pullRequestSourceRevision: String
    /// Exact PR-node/revision source stream for this GraphQL traversal and
    /// its resulting coverage/raw-page authority.
    let streamID: SyncStreamID
    /// The durable round-robin scheduler remains organization-wide. It is
    /// deliberately distinct from the per-PR source stream above.
    let schedulingStreamID: SyncStreamID
    let observedAt: Date
}

struct StatusCheckRecord: Equatable, Sendable {
    let context: String
    let state: GitHubPullRequestStatusCheckState
    let isRequired: Bool
    let completedAt: Date?
}

struct StatusCheckSnapshot: Sendable {
    let mergeableState: String
    let checks: [StatusCheckRecord]
    let sourceRevision: String
    let observedAt: Date
}

/// Scoped local persistence for the pull-request-specific `statusCheckRollup`.
/// This repository has no network behavior: callers must present a complete
/// source traversal and a current PR revision before replacement is allowed.
actor StatusCheckRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func replace(
        _ snapshot: StatusCheckSnapshot,
        authority: StatusCheckAuthority,
        coverage: CoverageRecord,
        rawPages: [GitHubPullRequestStatusCheckRawPage] = [],
        schedulingCandidate: PullRequestReviewCandidate? = nil,
        attemptedAt: Date = .now
    ) async throws {
        guard authority.scope.accountID == vault.accountID else {
            throw StatusCheckRepositoryError.accountScopeMismatch
        }
        try Self.validate(snapshot, authority: authority, coverage: coverage)
        try await vault.writeTransaction { database in
            try OrganizationSchedulerStateRepository.validateCurrentScope(authority.scope, in: database)
            try Self.validateCurrentPullRequest(authority: authority, in: database)
            for page in rawPages {
                try RawAPISnapshotRepository.save(
                    RawAPISnapshot(
                        id: .make(),
                        accountID: authority.scope.accountID,
                        githubNodeID: authority.pullRequestNodeID,
                        endpoint: page.requestKey,
                        eTag: nil,
                        parserVersion: 1,
                        observedAt: snapshot.observedAt,
                        payload: page.payload,
                        requestIdentity: ConditionalRequestIdentity(
                            scope: authority.scope,
                            feature: .statusChecks,
                            streamID: authority.streamID,
                            requestKey: page.requestKey
                        )
                    ),
                    in: database
                )
            }
            try CoverageRepository.save(
                coverage,
                attemptedAt: attemptedAt,
                expectedAccountID: authority.scope.accountID,
                in: database
            )
            try database.execute(
                sql: """
                    INSERT INTO status_check_rollup_markers (
                        github_node_id, account_id, organization_id, credential_revision,
                        capability_revision, source_revision, mergeable_state, observed_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(github_node_id) DO UPDATE SET
                        account_id = excluded.account_id,
                        organization_id = excluded.organization_id,
                        credential_revision = excluded.credential_revision,
                        capability_revision = excluded.capability_revision,
                        source_revision = excluded.source_revision,
                        mergeable_state = excluded.mergeable_state,
                        observed_at_ms = excluded.observed_at_ms
                    """,
                arguments: [
                    authority.pullRequestNodeID.rawValue,
                    authority.scope.accountID.rawValue,
                    authority.scope.organizationID.rawValue,
                    authority.scope.credentialRevision.rawValue,
                    authority.scope.capabilityRevision.rawValue,
                    snapshot.sourceRevision,
                    snapshot.mergeableState,
                    Self.milliseconds(snapshot.observedAt)
                ]
            )
            try database.execute(
                sql: "DELETE FROM status_checks WHERE github_node_id = ?",
                arguments: [authority.pullRequestNodeID.rawValue]
            )
            for check in snapshot.checks.sorted(by: { $0.context < $1.context }) {
                try database.execute(
                    sql: """
                        INSERT INTO status_checks (
                            github_node_id, context, state, is_required, completed_at_ms,
                            account_id, organization_id, credential_revision, capability_revision,
                            source_revision, observed_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        authority.pullRequestNodeID.rawValue,
                        check.context,
                        check.state.rawValue,
                        check.isRequired,
                        check.completedAt.map(Self.milliseconds),
                        authority.scope.accountID.rawValue,
                        authority.scope.organizationID.rawValue,
                        authority.scope.credentialRevision.rawValue,
                        authority.scope.capabilityRevision.rawValue,
                        snapshot.sourceRevision,
                        Self.milliseconds(snapshot.observedAt)
                    ]
                )
            }
            if let schedulingCandidate {
                try PullRequestReviewCandidateRepository.advanceFairSchedule(
                    after: schedulingCandidate,
                    scope: authority.scope,
                    streamID: authority.schedulingStreamID,
                    feature: .statusChecks,
                    at: attemptedAt,
                    in: database
                )
            }
        }
    }

    func snapshot(
        pullRequestNodeID: GitHubNodeID,
        scope: SynchronizationScope
    ) async throws -> StatusCheckSnapshot? {
        guard scope.accountID == vault.accountID else {
            throw StatusCheckRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
            guard let currentRevision: String = try String.fetchOne(
                database,
                sql: """
                    SELECT source_revision FROM github_nodes
                    WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                    """,
                arguments: [pullRequestNodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue]
            ) else { return nil }
            guard let marker = try Row.fetchOne(
                database,
                sql: """
                    SELECT mergeable_state, source_revision, observed_at_ms
                    FROM status_check_rollup_markers
                    WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                      AND credential_revision = ? AND capability_revision = ?
                      AND source_revision = ?
                    """,
                arguments: [
                    pullRequestNodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue,
                    scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue, currentRevision
                ]
            ), let mergeable: String = marker["mergeable_state"],
              let sourceRevision: String = marker["source_revision"],
              let observed: Int64 = marker["observed_at_ms"]
            else { return nil }
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT context, state, is_required, completed_at_ms, source_revision, observed_at_ms
                    FROM status_checks
                    WHERE github_node_id = ?
                      AND account_id = ? AND organization_id = ?
                      AND credential_revision = ? AND capability_revision = ?
                      AND source_revision = ?
                    ORDER BY context
                    """,
                arguments: [
                    pullRequestNodeID.rawValue, scope.accountID.rawValue, scope.organizationID.rawValue,
                    scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue, currentRevision
                ]
            )
            let records = try rows.map { row -> StatusCheckRecord in
                guard let context: String = row["context"],
                      let stateValue: String = row["state"],
                      let state = GitHubPullRequestStatusCheckState(rawValue: stateValue),
                      let required: Bool = row["is_required"],
                      let sourceRevision: String = row["source_revision"], sourceRevision == currentRevision,
                      let observed: Int64 = row["observed_at_ms"], observed >= 0
                else { throw StatusCheckRepositoryError.invalidPersistedData }
                return .init(
                    context: context,
                    state: state,
                    isRequired: required,
                    completedAt: (row["completed_at_ms"] as Int64?).map(Self.date)
                )
            }
            guard Set(records.map(\.context)).count == records.count else {
                throw StatusCheckRepositoryError.invalidPersistedData
            }
            return StatusCheckSnapshot(
                mergeableState: mergeable,
                checks: records,
                sourceRevision: sourceRevision,
                observedAt: Self.date(observed)
            )
        }
    }

    private nonisolated static func validate(
        _ snapshot: StatusCheckSnapshot,
        authority: StatusCheckAuthority,
        coverage: CoverageRecord
    ) throws {
        guard snapshot.sourceRevision == authority.pullRequestSourceRevision,
              Self.isSourceRevision(snapshot.sourceRevision),
              ["MERGEABLE", "CONFLICTING", "UNKNOWN"].contains(snapshot.mergeableState),
              snapshot.observedAt.timeIntervalSinceReferenceDate.isFinite,
              coverage.accountID == authority.scope.accountID,
              coverage.organizationID == authority.scope.organizationID,
              coverage.feature == .statusChecks,
              coverage.streamID == authority.streamID,
              coverage.credentialRevision == authority.scope.credentialRevision,
              coverage.capabilityRevision == authority.scope.capabilityRevision,
              coverage.status == .complete
        else { throw StatusCheckRepositoryError.incompleteCoverage }
        guard Set(snapshot.checks.map(\.context)).count == snapshot.checks.count else {
            throw StatusCheckRepositoryError.duplicateContext
        }
        for check in snapshot.checks {
            guard !check.context.isEmpty, check.context.count <= 700,
                  check.completedAt?.timeIntervalSinceReferenceDate.isFinite != false
            else { throw StatusCheckRepositoryError.invalidRecord }
        }
    }

    private nonisolated static func validateCurrentPullRequest(
        authority: StatusCheckAuthority,
        in database: Database
    ) throws {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT github_nodes.source_revision
                FROM github_nodes JOIN pull_requests
                  ON pull_requests.github_node_id = github_nodes.github_node_id
                WHERE github_nodes.github_node_id = ?
                  AND github_nodes.account_id = ? AND github_nodes.organization_id = ?
                """,
            arguments: [
                authority.pullRequestNodeID.rawValue,
                authority.scope.accountID.rawValue,
                authority.scope.organizationID.rawValue
            ]
        ), let revision: String = row["source_revision"] else {
            throw StatusCheckRepositoryError.pullRequestScopeMismatch
        }
        guard revision == authority.pullRequestSourceRevision else {
            throw StatusCheckRepositoryError.stalePullRequestRevision
        }
    }

    private nonisolated static func isSourceRevision(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.numericType != nil || (97...102).contains($0.value)) }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}
