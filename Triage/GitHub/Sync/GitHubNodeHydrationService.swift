import Foundation
import GRDB

enum GitHubNodeHydrationServiceError: Error, Equatable, Sendable {
    case emptyBatch
    case batchTooLarge
    case queryCostExceeded(Int)
}

enum GitHubGraphQLPartialFailureKind: String, Equatable, Hashable, Sendable {
    case forbidden
    case notFound
    case rateLimited
    case unauthorized
    case internalFailure
    case unknown
}

enum GitHubNodeHydrationOutcomeStatus: Equatable, Sendable {
    case refreshed
    case partialGraphQL([GitHubGraphQLPartialFailureKind])
    case invalidResponse
    case missingData
    case normalizationFailed
    case queryCostExceeded
    case responseTooLarge
    case ssoRequired(GitHubSSOHeader)
    case approvalRequired
    case authenticationRequired
    case rateLimited(retryAt: Date?)
    case unavailableOrPermission
    case failed
    case deferred
}

struct GitHubNodeHydrationOutcome: Equatable, Sendable {
    let candidate: GitHubHydrationCandidate
    let status: GitHubNodeHydrationOutcomeStatus
}

struct GitHubNodeHydrationCoverageAssessment: Equatable, Sendable {
    let status: CoverageStatus
    let failureDetail: String?
}

struct GitHubNodeHydrationRefreshResult: Equatable, Sendable {
    let outcomes: [GitHubNodeHydrationOutcome]

    var isComplete: Bool {
        outcomes.allSatisfy { $0.status == .refreshed }
    }

    func coverageAssessment(
        repositoryID: RepositoryID? = nil,
        kind: GitHubContentKind
    ) -> GitHubNodeHydrationCoverageAssessment {
        let statuses = outcomes.filter {
            $0.candidate.kind == kind
                && (repositoryID == nil || $0.candidate.repositoryID == repositoryID)
        }.map(\.status)
        if statuses.contains(where: {
            if case .ssoRequired = $0 { return true }
            return false
        }) {
            return .init(
                status: .requiresSSO,
                failureDetail: "GitHub organization SSO authorization is required for current fields."
            )
        }
        if statuses.contains(.approvalRequired) {
            return .init(
                status: .requiresApproval,
                failureDetail: "GitHub organization approval is required for current fields."
            )
        }
        if statuses.contains(.authenticationRequired) || statuses.contains(.failed) {
            return .init(status: .failed, failureDetail: "Current field hydration failed.")
        }
        if statuses.contains(.unavailableOrPermission) {
            return .init(
                status: .unavailable,
                failureDetail: "Some current fields are unavailable to the selected account."
            )
        }
        if statuses.contains(where: { $0 != .refreshed }) {
            return .init(
                status: .partial,
                failureDetail: "Some current fields remain incomplete."
            )
        }
        return .init(status: .complete, failureDetail: nil)
    }
}

actor GitHubNodeHydrationService {
    private let client: GitHubGraphQLClient
    private let detailsRepository: GitHubNodeDetailsRepository
    private let rawSnapshotRepository: RawAPISnapshotRepository
    private let normalizationFailureRepository: NormalizationFailureRepository
    private let batchMetricRepository: GitHubHydrationBatchMetricRepository
    private let clock: @Sendable () -> Date

    init(
        client: GitHubGraphQLClient,
        detailsRepository: GitHubNodeDetailsRepository,
        rawSnapshotRepository: RawAPISnapshotRepository,
        normalizationFailureRepository: NormalizationFailureRepository,
        batchMetricRepository: GitHubHydrationBatchMetricRepository,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.detailsRepository = detailsRepository
        self.rawSnapshotRepository = rawSnapshotRepository
        self.normalizationFailureRepository = normalizationFailureRepository
        self.batchMetricRepository = batchMetricRepository
        self.clock = clock
    }

    func hydrate(
        nodeIDs: Set<GitHubNodeID>,
        scope: SynchronizationScope,
        githubOrganizationID: UInt64? = nil,
        repositoryID: @escaping @Sendable (GitHubNodeHydrationPayload.Repository) -> RepositoryID?
    ) async throws -> GitHubNodeHydrationRefreshResult {
        let accountID = scope.accountID
        let organizationID = scope.organizationID
        try await validateCurrentScope(scope)
        guard !nodeIDs.isEmpty else {
            return GitHubNodeHydrationRefreshResult(outcomes: [])
        }
        let candidates = try await detailsRepository.hydrationCandidates(
            nodeIDs: nodeIDs,
            accountID: accountID,
            organizationID: organizationID
        )
        try await validateCurrentScope(scope)
        let candidatesByNodeID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.nodeID, $0) })
        let query = try GitHubGraphQLQueries.hydrateNodes()
        let sortedNodeIDs = nodeIDs.sorted { $0.rawValue < $1.rawValue }
        var nextIndex = 0
        var batchSize = GitHubHydrationBatchPlanner.initialBatchSize
        var outcomes = [GitHubNodeHydrationOutcome]()
        while nextIndex < sortedNodeIDs.count {
            try await validateCurrentScope(scope)
            let endIndex = min(nextIndex + batchSize, sortedNodeIDs.count)
            let batch = Array(sortedNodeIDs[nextIndex ..< endIndex])
            guard batch.count <= GitHubHydrationBatchPlanner.maximumBatchSize else {
                throw GitHubNodeHydrationServiceError.batchTooLarge
            }
            let decodingResult: GitHubGraphQLDecodingResult<GitHubNodeHydrationPayload>
            do {
                decodingResult = try await client.executePreservingUndecodableResponse(
                    query,
                    variables: Variables(ids: batch.map(\.rawValue)),
                    as: GitHubNodeHydrationPayload.self
                )
            } catch GitHubGraphQLError.responseTooLarge {
                try await validateCurrentScope(scope)
                guard let reducedBatchSize = GitHubHydrationBatchPlanner.retryBatchSize(
                    for: batch.count
                ) else {
                    Self.appendTerminalOutcomes(
                        status: .responseTooLarge,
                        batch: batch,
                        remaining: Array(sortedNodeIDs[endIndex...]),
                        candidatesByNodeID: candidatesByNodeID,
                        outcomes: &outcomes
                    )
                    return GitHubNodeHydrationRefreshResult(outcomes: outcomes)
                }
                batchSize = reducedBatchSize
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GitHubGraphQLError {
                try await validateCurrentScope(scope)
                let status = Self.status(
                    for: error,
                    githubOrganizationID: githubOrganizationID,
                    observedAt: clock()
                )
                Self.appendTerminalOutcomes(
                    status: status,
                    batch: batch,
                    remaining: Array(sortedNodeIDs[endIndex...]),
                    candidatesByNodeID: candidatesByNodeID,
                    outcomes: &outcomes
                )
                return GitHubNodeHydrationRefreshResult(outcomes: outcomes)
            } catch {
                try await validateCurrentScope(scope)
                Self.appendTerminalOutcomes(
                    status: .failed,
                    batch: batch,
                    remaining: Array(sortedNodeIDs[endIndex...]),
                    candidatesByNodeID: candidatesByNodeID,
                    outcomes: &outcomes
                )
                return GitHubNodeHydrationRefreshResult(outcomes: outcomes)
            }
            try await validateCurrentScope(scope)
            let observedAt = clock()
            let response: GitHubGraphQLResponse<GitHubNodeHydrationPayload>
            switch decodingResult {
            case let .response(decoded):
                response = decoded
            case let .undecodable(rejected):
                let snapshot = Self.snapshot(
                    payload: rejected.payload,
                    accountID: accountID,
                    observedAt: observedAt
                )
                try await recordRejectedResponse(
                    snapshot,
                    scope: scope,
                    observedAt: observedAt,
                    diagnostic: "Hydration response could not be decoded."
                )
                let status = Self.status(
                    for: rejected.errors,
                    metadata: rejected.metadata,
                    githubOrganizationID: githubOrganizationID,
                    observedAt: observedAt,
                    default: .invalidResponse
                )
                Self.appendTerminalOutcomes(
                    status: status,
                    batch: batch,
                    remaining: Array(sortedNodeIDs[endIndex...]),
                    candidatesByNodeID: candidatesByNodeID,
                    outcomes: &outcomes
                )
                return GitHubNodeHydrationRefreshResult(outcomes: outcomes)
            }
            let snapshot = Self.snapshot(
                payload: response.payload,
                accountID: accountID,
                observedAt: observedAt
            )
            guard let payload = response.data else {
                try await recordRejectedResponse(
                    snapshot,
                    scope: scope,
                    observedAt: observedAt,
                    diagnostic: "Hydration response omitted its data payload."
                )
                let status = Self.status(
                    for: response.errors,
                    metadata: response.metadata,
                    githubOrganizationID: githubOrganizationID,
                    observedAt: observedAt,
                    default: response.errors.isEmpty
                        ? .missingData
                        : .partialGraphQL(Self.partialKinds(response.errors))
                )
                Self.appendTerminalOutcomes(
                    status: status,
                    batch: batch,
                    remaining: Array(sortedNodeIDs[endIndex...]),
                    candidatesByNodeID: candidatesByNodeID,
                    outcomes: &outcomes
                )
                return GitHubNodeHydrationRefreshResult(outcomes: outcomes)
            }
            try await recordBatchMetric(
                GitHubHydrationBatchMetric(
                    accountID: accountID,
                    requestedNodeCount: batch.count,
                    responseBytes: response.payload.count,
                    queryCost: payload.rateLimit.cost,
                    rateLimitRemaining: payload.rateLimit.remaining,
                    rateLimitResetAt: payload.rateLimit.resetAt,
                    observedAt: observedAt
                ),
                scope: scope
            )
            try await validateCurrentScope(scope)
            guard response.errors.isEmpty else {
                try await recordRejectedResponse(
                    snapshot,
                    scope: scope,
                    observedAt: observedAt,
                    diagnostic: "Hydration response contained partial GraphQL errors."
                )
                let status = Self.status(
                    for: response.errors,
                    metadata: response.metadata,
                    githubOrganizationID: githubOrganizationID,
                    observedAt: observedAt,
                    default: .partialGraphQL(Self.partialKinds(response.errors))
                )
                Self.appendTerminalOutcomes(
                    status: status,
                    batch: batch,
                    remaining: Array(sortedNodeIDs[endIndex...]),
                    candidatesByNodeID: candidatesByNodeID,
                    outcomes: &outcomes
                )
                return GitHubNodeHydrationRefreshResult(outcomes: outcomes)
            }
            guard payload.rateLimit.cost <= GitHubHydrationBatchPlanner.maximumQueryCost else {
                try await saveRawSnapshot(snapshot, scope: scope)
                try await validateCurrentScope(scope)
                guard let reducedBatchSize = GitHubHydrationBatchPlanner.retryBatchSize(
                    for: batch.count
                ) else {
                    try await recordRejectedResponse(
                        snapshot,
                        scope: scope,
                        observedAt: observedAt,
                        diagnostic: "Hydration query exceeded the supported cost limit."
                    )
                    Self.appendTerminalOutcomes(
                        status: .queryCostExceeded,
                        batch: batch,
                        remaining: Array(sortedNodeIDs[endIndex...]),
                        candidatesByNodeID: candidatesByNodeID,
                        outcomes: &outcomes
                    )
                    return GitHubNodeHydrationRefreshResult(outcomes: outcomes)
                }
                batchSize = reducedBatchSize
                continue
            }
            let normalized: [HydratedGitHubNode]
            do {
                normalized = try GitHubNodeHydrationNormalizer.normalizeHydrated(
                    payload,
                    requestedNodeIDs: Set(batch),
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: repositoryID,
                    observedAt: observedAt
                )
            } catch let error as GitHubNodeHydrationNormalizationError {
                let diagnostic = Self.redactedDiagnostic(for: error)
                try await detailsRepository.writeTransaction(accountID: accountID) { database in
                    try Self.validateCurrentScope(scope, in: database)
                    try RawAPISnapshotRepository.save(snapshot, in: database)
                    try NormalizationFailureRepository.record(
                        NormalizationFailure(
                            id: UUID(),
                            accountID: accountID,
                            rawSnapshotID: snapshot.id,
                            githubNodeID: nil,
                            endpoint: snapshot.endpoint,
                            parserVersion: snapshot.parserVersion,
                            occurredAt: observedAt,
                            redactedDiagnostic: diagnostic
                        ),
                        in: database
                    )
                }
                Self.appendTerminalOutcomes(
                    status: .normalizationFailed,
                    batch: batch,
                    remaining: Array(sortedNodeIDs[endIndex...]),
                    candidatesByNodeID: candidatesByNodeID,
                    outcomes: &outcomes
                )
                return GitHubNodeHydrationRefreshResult(outcomes: outcomes)
            }
            try await validateCurrentScope(scope)
            let payloadActors = Self.actors(in: payload)
            do {
                try await detailsRepository.writeTransaction(accountID: accountID) { database in
                    try Self.validateCurrentScope(scope, in: database)
                    try RawAPISnapshotRepository.save(snapshot, in: database)
                    for actor in payloadActors {
                        try ActorRepository.save(
                            actor,
                            observedAtMilliseconds: Self.milliseconds(observedAt),
                            in: database
                        )
                    }
                    for hydratedNode in normalized {
                        try GitHubNodeDetailsRepository.save(
                            hydratedNode,
                            accountID: accountID,
                            observedAtMilliseconds: Self.milliseconds(observedAt),
                            in: database
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await saveRawSnapshot(snapshot, scope: scope)
                throw error
            }
            try await validateCurrentScope(scope)
            batchSize = GitHubHydrationBatchPlanner.nextBatchSize(
                after: batchSize,
                queryCost: payload.rateLimit.cost,
                responseBytes: response.payload.count
            )
            outcomes.append(contentsOf: batch.map { nodeID in
                GitHubNodeHydrationOutcome(
                    candidate: candidatesByNodeID[nodeID]!,
                    status: .refreshed
                )
            })
            nextIndex = endIndex
        }
        return GitHubNodeHydrationRefreshResult(outcomes: outcomes)
    }

    private func recordRejectedResponse(
        _ snapshot: RawAPISnapshot,
        scope: SynchronizationScope,
        observedAt: Date,
        diagnostic: String
    ) async throws {
        let accountID = scope.accountID
        try await validateCurrentScope(scope)
        try await detailsRepository.writeTransaction(accountID: accountID) { database in
            try Self.validateCurrentScope(scope, in: database)
            try RawAPISnapshotRepository.save(snapshot, in: database)
            try NormalizationFailureRepository.record(
                NormalizationFailure(
                    id: UUID(),
                    accountID: accountID,
                    rawSnapshotID: snapshot.id,
                    githubNodeID: nil,
                    endpoint: snapshot.endpoint,
                    parserVersion: snapshot.parserVersion,
                    occurredAt: observedAt,
                    redactedDiagnostic: diagnostic
                ),
                in: database
            )
        }
        try await validateCurrentScope(scope)
    }

    private func saveRawSnapshot(
        _ snapshot: RawAPISnapshot,
        scope: SynchronizationScope
    ) async throws {
        try await validateCurrentScope(scope)
        try await detailsRepository.writeTransaction(accountID: scope.accountID) { database in
            try Self.validateCurrentScope(scope, in: database)
            try RawAPISnapshotRepository.save(snapshot, in: database)
        }
        try await validateCurrentScope(scope)
    }

    private func recordBatchMetric(
        _ metric: GitHubHydrationBatchMetric,
        scope: SynchronizationScope
    ) async throws {
        guard metric.accountID == scope.accountID else {
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

        try await validateCurrentScope(scope)
        try await detailsRepository.writeTransaction(accountID: scope.accountID) { database in
            try Self.validateCurrentScope(scope, in: database)
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
                          LIMIT 500
                      )
                """,
                arguments: [metric.accountID.rawValue, metric.accountID.rawValue]
            )
        }
        try await validateCurrentScope(scope)
    }

    private func validateCurrentScope(_ scope: SynchronizationScope) async throws {
        try Task.checkCancellation()
        do {
            try await detailsRepository.writeTransaction(accountID: scope.accountID) { database in
                try Self.validateCurrentScope(scope, in: database)
            }
        } catch is CancellationError {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private nonisolated static func validateCurrentScope(
        _ scope: SynchronizationScope,
        in database: Database
    ) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope {
            throw CancellationError()
        } catch OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw CancellationError()
        }
    }

    private nonisolated static func appendTerminalOutcomes(
        status: GitHubNodeHydrationOutcomeStatus,
        batch: [GitHubNodeID],
        remaining: [GitHubNodeID],
        candidatesByNodeID: [GitHubNodeID: GitHubHydrationCandidate],
        outcomes: inout [GitHubNodeHydrationOutcome]
    ) {
        outcomes.append(contentsOf: batch.compactMap { nodeID in
            candidatesByNodeID[nodeID].map {
                GitHubNodeHydrationOutcome(candidate: $0, status: status)
            }
        })
        outcomes.append(contentsOf: remaining.compactMap { nodeID in
            candidatesByNodeID[nodeID].map {
                GitHubNodeHydrationOutcome(candidate: $0, status: .deferred)
            }
        })
    }

    private nonisolated static func status(
        for error: GitHubGraphQLError,
        githubOrganizationID: UInt64?,
        observedAt: Date
    ) -> GitHubNodeHydrationOutcomeStatus {
        guard case let .requestFailed(failure) = error else {
            return switch error {
            case .responseTooLarge: .responseTooLarge
            case .partialResponse: .partialGraphQL([.unknown])
            case .missingData: .missingData
            case .invalidResponse: .invalidResponse
            case .mutationRejected, .invalidQuery, .requestFailed: .failed
            }
        }
        if let header = scopedSSOHeader(
            failure.ssoHeader,
            githubOrganizationID: githubOrganizationID
        ) {
            return .ssoRequired(header)
        }
        if let restriction = failure.accessRestriction {
            return switch restriction {
            case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
                .approvalRequired
            case .organizationPolicyBlocked:
                .unavailableOrPermission
            }
        }
        return switch failure.kind {
        case .unauthorized:
            .authenticationRequired
        case .rateLimited, .secondaryRateLimited:
            .rateLimited(retryAt: failure.retryAfter.map { observedAt.addingTimeInterval($0) })
        case .forbidden, .notFound:
            .unavailableOrPermission
        case .serverFailure, .unexpectedResponse:
            .failed
        }
    }

    private nonisolated static func status(
        for errors: [GitHubGraphQLPartialError],
        metadata: GitHubGraphQLResponseMetadata,
        githubOrganizationID: UInt64?,
        observedAt: Date,
        default defaultStatus: GitHubNodeHydrationOutcomeStatus
    ) -> GitHubNodeHydrationOutcomeStatus {
        if let header = scopedSSOHeader(
            metadata.ssoHeader,
            githubOrganizationID: githubOrganizationID
        ) {
            return .ssoRequired(header)
        }
        let kinds = partialKinds(errors)
        if kinds.contains(.unauthorized) {
            return .authenticationRequired
        }
        if kinds.contains(.rateLimited) {
            return .rateLimited(
                retryAt: metadata.retryAfter.map { observedAt.addingTimeInterval($0) }
            )
        }
        if kinds.contains(.forbidden) || kinds.contains(.notFound) {
            return .unavailableOrPermission
        }
        return defaultStatus
    }

    private nonisolated static func partialKinds(
        _ errors: [GitHubGraphQLPartialError]
    ) -> [GitHubGraphQLPartialFailureKind] {
        let kinds = Set(errors.map { error -> GitHubGraphQLPartialFailureKind in
            let value = error.extensions?.code ?? error.extensions?.type ?? error.type
            return switch value?.uppercased() {
            case "FORBIDDEN": .forbidden
            case "NOT_FOUND": .notFound
            case "RATE_LIMITED": .rateLimited
            case "UNAUTHORIZED": .unauthorized
            case "INTERNAL", "INTERNAL_SERVER_ERROR": .internalFailure
            default: .unknown
            }
        })
        return kinds.sorted { $0.rawValue < $1.rawValue }
    }

    private nonisolated static func scopedSSOHeader(
        _ header: GitHubSSOHeader?,
        githubOrganizationID: UInt64?
    ) -> GitHubSSOHeader? {
        guard let header else { return nil }
        guard let githubOrganizationID else {
            if case .authorizationRequired = header { return header }
            return nil
        }
        return header.scoped(to: githubOrganizationID)
    }

    private nonisolated static func snapshot(
        payload: Data,
        accountID: AccountID,
        observedAt: Date
    ) -> RawAPISnapshot {
        RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: accountID,
            githubNodeID: nil,
            endpoint: "graphql:TriageHydrateNodes",
            eTag: nil,
            parserVersion: 2,
            observedAt: observedAt,
            payload: payload
        )
    }

    private struct Variables: Encodable, Sendable {
        let ids: [String]
    }

    private nonisolated static func actors(in payload: GitHubNodeHydrationPayload) -> [ActorSummary] {
        var actors = [ActorID: ActorSummary]()
        let payloadActors = payload.nodes.compactMap(\.?).flatMap { node in
            [node.author].compactMap(\.self) + node.assignees.nodes.compactMap(\.?)
        }
        for actor in payloadActors {
            guard let id = ActorID(rawValue: actor.id),
                  let login = actor.login, !login.isEmpty
            else {
                continue
            }
            actors[id] = ActorSummary(
                id: id,
                nodeID: GitHubNodeID(rawValue: actor.id)!,
                login: login,
                displayName: nil,
                avatarURL: actor.avatarUrl
            )
        }
        return actors.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private nonisolated static func redactedDiagnostic(
        for error: GitHubNodeHydrationNormalizationError
    ) -> String {
        switch error {
        case .missingRequestedNode:
            "Hydration response omitted a requested GitHub node."
        case .duplicateNode:
            "Hydration response contained a duplicate GitHub node."
        case .unsupportedNodeType:
            "Hydration response contained an unsupported GitHub node type."
        case .invalidNodeID:
            "Hydration response contained an invalid GitHub node identifier."
        case .invalidRepositoryID:
            "Hydration response could not be mapped to an accessible repository."
        case .invalidNumber:
            "Hydration response contained an invalid issue or pull request number."
        case .invalidTitle:
            "Hydration response contained an invalid issue or pull request title."
        case .invalidURL:
            "Hydration response contained an invalid GitHub URL."
        case .invalidState:
            "Hydration response contained an unsupported issue or pull request state."
        case .invalidDates:
            "Hydration response contained inconsistent issue or pull request timestamps."
        case .invalidIssueDetails:
            "Hydration response omitted required issue details."
        case .invalidRelatedNodeID:
            "Hydration response contained an invalid related GitHub node identifier."
        case .incompleteConnection:
            "Hydration response exceeded the supported related-object page size."
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
