import Foundation

enum GitHubNodeHydrationServiceError: Error, Equatable, Sendable {
    case emptyBatch
    case batchTooLarge
    case queryCostExceeded(Int)
}

actor GitHubNodeHydrationService {
    private static let initialBatchSize = 25
    private static let maximumBatchSize = 50
    private static let maximumQueryCost = 500

    private let client: GitHubGraphQLClient
    private let nodeRepository: GitHubNodeRepository
    private let actorRepository: ActorRepository
    private let rawSnapshotRepository: RawAPISnapshotRepository
    private let normalizationFailureRepository: NormalizationFailureRepository
    private let clock: @Sendable () -> Date

    init(
        client: GitHubGraphQLClient,
        nodeRepository: GitHubNodeRepository,
        actorRepository: ActorRepository,
        rawSnapshotRepository: RawAPISnapshotRepository,
        normalizationFailureRepository: NormalizationFailureRepository,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.nodeRepository = nodeRepository
        self.actorRepository = actorRepository
        self.rawSnapshotRepository = rawSnapshotRepository
        self.normalizationFailureRepository = normalizationFailureRepository
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
        for batch in nodeIDs.sorted(by: { $0.rawValue < $1.rawValue }).chunked(into: Self.initialBatchSize) {
            try Task.checkCancellation()
            guard batch.count <= Self.maximumBatchSize else {
                throw GitHubNodeHydrationServiceError.batchTooLarge
            }
            let response = try await client.execute(
                query,
                variables: Variables(ids: batch.map(\.rawValue)),
                as: GitHubNodeHydrationPayload.self
            )
            guard response.errors.isEmpty, let payload = response.data else {
                throw GitHubGraphQLError.partialResponse
            }
            guard payload.rateLimit.cost <= Self.maximumQueryCost else {
                throw GitHubNodeHydrationServiceError.queryCostExceeded(payload.rateLimit.cost)
            }

            let observedAt = clock()
            let snapshot = RawAPISnapshot(
                id: RawAPISnapshotID.make(),
                accountID: accountID,
                githubNodeID: nil,
                endpoint: "graphql:TriageHydrateNodes",
                eTag: nil,
                parserVersion: 1,
                observedAt: observedAt,
                payload: response.payload
            )
            try await rawSnapshotRepository.save(snapshot)
            for actor in actors(in: payload) {
                try await actorRepository.save(actor, observedAt: observedAt)
            }
            let normalized: [NormalizedGitHubNode]
            do {
                normalized = try GitHubNodeHydrationNormalizer.normalize(
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
            for node in normalized {
                try await nodeRepository.save(node)
            }
        }
    }

    private struct Variables: Encodable, Sendable {
        let ids: [String]
    }

    private func actors(in payload: GitHubNodeHydrationPayload) -> [ActorSummary] {
        var actors = [ActorID: ActorSummary]()
        for actor in payload.nodes.compactMap(\.?.author) {
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
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
