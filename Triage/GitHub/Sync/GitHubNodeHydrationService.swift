import Foundation

enum GitHubNodeHydrationServiceError: Error, Equatable, Sendable {
    case emptyBatch
    case batchTooLarge
    case queryCostExceeded(Int)
}

actor GitHubNodeHydrationService {
    private let client: GitHubGraphQLClient
    private let detailsRepository: GitHubNodeDetailsRepository
    private let actorRepository: ActorRepository
    private let rawSnapshotRepository: RawAPISnapshotRepository
    private let normalizationFailureRepository: NormalizationFailureRepository
    private let batchMetricRepository: GitHubHydrationBatchMetricRepository
    private let clock: @Sendable () -> Date

    init(
        client: GitHubGraphQLClient,
        detailsRepository: GitHubNodeDetailsRepository,
        actorRepository: ActorRepository,
        rawSnapshotRepository: RawAPISnapshotRepository,
        normalizationFailureRepository: NormalizationFailureRepository,
        batchMetricRepository: GitHubHydrationBatchMetricRepository,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.detailsRepository = detailsRepository
        self.actorRepository = actorRepository
        self.rawSnapshotRepository = rawSnapshotRepository
        self.normalizationFailureRepository = normalizationFailureRepository
        self.batchMetricRepository = batchMetricRepository
        self.clock = clock
    }

    func hydrate(
        nodeIDs: Set<GitHubNodeID>,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: @escaping @Sendable (GitHubNodeHydrationPayload.Repository) -> RepositoryID?
    ) async throws {
        guard !nodeIDs.isEmpty else { return }
        let query = try GitHubGraphQLQueries.hydrateNodes()
        let sortedNodeIDs = nodeIDs.sorted { $0.rawValue < $1.rawValue }
        var nextIndex = 0
        var batchSize = GitHubHydrationBatchPlanner.initialBatchSize
        while nextIndex < sortedNodeIDs.count {
            try Task.checkCancellation()
            let endIndex = min(nextIndex + batchSize, sortedNodeIDs.count)
            let batch = Array(sortedNodeIDs[nextIndex ..< endIndex])
            guard batch.count <= GitHubHydrationBatchPlanner.maximumBatchSize else {
                throw GitHubNodeHydrationServiceError.batchTooLarge
            }
            let response: GitHubGraphQLResponse<GitHubNodeHydrationPayload>
            do {
                response = try await client.execute(
                    query,
                    variables: Variables(ids: batch.map(\.rawValue)),
                    as: GitHubNodeHydrationPayload.self
                )
            } catch GitHubGraphQLError.responseTooLarge {
                guard let reducedBatchSize = GitHubHydrationBatchPlanner.retryBatchSize(
                    for: batch.count
                ) else {
                    throw GitHubGraphQLError.responseTooLarge
                }
                batchSize = reducedBatchSize
                continue
            }
            guard let payload = response.data else {
                throw GitHubGraphQLError.partialResponse
            }

            let observedAt = clock()
            try await batchMetricRepository.record(
                GitHubHydrationBatchMetric(
                    accountID: accountID,
                    requestedNodeCount: batch.count,
                    responseBytes: response.payload.count,
                    queryCost: payload.rateLimit.cost,
                    rateLimitRemaining: payload.rateLimit.remaining,
                    rateLimitResetAt: payload.rateLimit.resetAt,
                    observedAt: observedAt
                )
            )
            guard response.errors.isEmpty else {
                throw GitHubGraphQLError.partialResponse
            }
            guard payload.rateLimit.cost <= GitHubHydrationBatchPlanner.maximumQueryCost else {
                guard let reducedBatchSize = GitHubHydrationBatchPlanner.retryBatchSize(
                    for: batch.count
                ) else {
                    throw GitHubNodeHydrationServiceError.queryCostExceeded(payload.rateLimit.cost)
                }
                batchSize = reducedBatchSize
                continue
            }

            let snapshot = RawAPISnapshot(
                id: RawAPISnapshotID.make(),
                accountID: accountID,
                githubNodeID: nil,
                endpoint: "graphql:TriageHydrateNodes",
                eTag: nil,
                parserVersion: 2,
                observedAt: observedAt,
                payload: response.payload
            )
            try await rawSnapshotRepository.save(snapshot)
            for actor in actors(in: payload) {
                try await actorRepository.save(actor, observedAt: observedAt)
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
                try await normalizationFailureRepository.record(
                    NormalizationFailure(
                        id: UUID(),
                        accountID: accountID,
                        rawSnapshotID: snapshot.id,
                        githubNodeID: nil,
                        endpoint: snapshot.endpoint,
                        parserVersion: snapshot.parserVersion,
                        occurredAt: observedAt,
                        redactedDiagnostic: redactedDiagnostic(for: error)
                    )
                )
                throw error
            }
            for hydratedNode in normalized {
                try await detailsRepository.save(
                    hydratedNode,
                    accountID: accountID,
                    observedAt: observedAt
                )
            }
            batchSize = GitHubHydrationBatchPlanner.nextBatchSize(
                after: batchSize,
                queryCost: payload.rateLimit.cost,
                responseBytes: response.payload.count
            )
            nextIndex = endIndex
        }
    }

    private struct Variables: Encodable, Sendable {
        let ids: [String]
    }

    private func actors(in payload: GitHubNodeHydrationPayload) -> [ActorSummary] {
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

    private func redactedDiagnostic(for error: GitHubNodeHydrationNormalizationError) -> String {
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
}
