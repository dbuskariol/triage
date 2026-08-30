import Foundation

struct RoleDiscoverySyncResult: Sendable {
    let workItemIDs: [WorkItemID]
    let candidateNodeIDs: Set<GitHubNodeID>
}

struct RoleDiscoveryStreamOutcome: Equatable, Sendable {
    let kind: RoleDiscoveryStreamKind
    let status: CoverageStatus
    let failureDetail: String?
}

actor RoleDiscoverySynchronizer {
    typealias StreamOutcomeRecorder = @Sendable (
        RoleDiscoveryStream,
        RoleDiscoveryStreamOutcome
    ) async throws -> Void

    private let searchClient: any GitHubIssueSearchExecuting
    private let workItemRepository: WorkItemRepository
    private let shardRepository: SyncShardRepository
    private let clock: @Sendable () -> Date

    init(
        searchClient: any GitHubIssueSearchExecuting,
        workItemRepository: WorkItemRepository,
        shardRepository: SyncShardRepository,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.searchClient = searchClient
        self.workItemRepository = workItemRepository
        self.shardRepository = shardRepository
        self.clock = clock
    }

    func synchronize(
        plan: RoleDiscoveryPlan,
        accountID: AccountID,
        organizationID: OrganizationID,
        githubOrganizationID: UInt64,
        streamID: SyncStreamID,
        searchRange: SearchTimeRange,
        accessibleRepositoryNames: [String],
        repositoryID: @escaping @Sendable (GitHubIssueSearchItem) -> RepositoryID?,
        streams: [RoleDiscoveryStream]? = nil,
        recordStreamOutcome: @escaping StreamOutcomeRecorder = { _, _ in }
    ) async throws -> RoleDiscoverySyncResult {
        let accumulator = RoleDiscoveryAccumulator()
        let observationClock = clock
        let shardExecutor = SearchShardExecutor(
            client: searchClient,
            shardRepository: shardRepository,
            clock: clock
        )
        let selectedStreams = streams ?? plan.streams
        var firstFailure: (any Error)?
        for (streamIndex, stream) in selectedStreams.enumerated() {
            do {
                for query in stream.queries {
                    try await shardExecutor.execute(
                        query: query,
                        range: searchRange,
                        streamID: stream.streamID(parent: streamID),
                        accountID: accountID,
                        accessibleRepositoryNames: accessibleRepositoryNames,
                        prepareControlPage: { response, boundedQuery, page in
                            Self.prepareControlPageWrite(
                                response,
                                query: boundedQuery,
                                page: page,
                                accountID: accountID,
                                observedAt: observationClock()
                            )
                        },
                        prepareUndecodablePage: { response, boundedQuery, page in
                            Self.prepareUndecodablePageWrite(
                                response,
                                query: boundedQuery,
                                page: page,
                                accountID: accountID,
                                observedAt: observationClock()
                            )
                        }
                    ) { [self] response, boundedQuery, page in
                        try await self.throwForSSORequirement(
                            in: response.ssoHeader,
                            githubOrganizationID: githubOrganizationID
                        )
                        return try await self.preparePageWrite(
                            response,
                            query: boundedQuery,
                            page: page,
                            accountID: accountID,
                            organizationID: organizationID,
                            repositoryID: repositoryID,
                            accumulator: accumulator
                        )
                    }
                }
            } catch {
                let outcome = Self.outcome(
                    for: stream.kind,
                    error: error,
                    githubOrganizationID: githubOrganizationID
                )
                try await recordStreamOutcome(
                    stream,
                    outcome
                )
                if error is CancellationError {
                    throw CancellationError()
                }
                if firstFailure == nil {
                    firstFailure = error
                }
                if Self.shouldDeferRemainingStreams(after: error) {
                    for remainingStream in selectedStreams.dropFirst(streamIndex + 1) {
                        try await recordStreamOutcome(
                            remainingStream,
                            Self.deferredOutcome(
                                for: remainingStream.kind,
                                after: outcome
                            )
                        )
                    }
                    break
                }
                continue
            }
            try await recordStreamOutcome(
                stream,
                RoleDiscoveryStreamOutcome(
                    kind: stream.kind,
                    status: .complete,
                    failureDetail: nil
                )
            )
        }

        if let firstFailure {
            throw firstFailure
        }

        let candidateNodeIDs = await accumulator.committedNodeIDs()
        return RoleDiscoverySyncResult(
            workItemIDs: try await workItemRepository.identifiers(
                for: candidateNodeIDs,
                accountID: accountID
            ),
            candidateNodeIDs: candidateNodeIDs
        )
    }

    private func preparePageWrite(
        _ response: GitHubResponse<GitHubIssueSearchPage>,
        query: GitHubIssueSearchQuery,
        page: Int,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: @escaping @Sendable (GitHubIssueSearchItem) -> RepositoryID?,
        accumulator: RoleDiscoveryAccumulator
    ) async throws -> PreparedSearchShardPageWrite {
        let observedAt = clock()
        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: accountID,
            githubNodeID: nil,
            endpoint: "/search/issues?q=\(query.value)&page=\(page)",
            eTag: response.etag,
            parserVersion: 1,
            observedAt: observedAt,
            payload: response.payload
        )
        var entries: [NormalizedPageEntry] = []
        var failures: [NormalizationFailure] = []
        for item in response.value.items {
            do {
                let node = try GitHubSearchNormalizer.normalize(
                    item,
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: repositoryID(item),
                    observedAt: observedAt
                )
                entries.append(
                    NormalizedPageEntry(
                        node: node
                    )
                )
            } catch let error as GitHubSearchNormalizationError {
                failures.append(
                    NormalizationFailure(
                        id: UUID(),
                        accountID: accountID,
                        rawSnapshotID: snapshot.id,
                        githubNodeID: nil,
                        endpoint: searchEndpoint(for: item),
                        parserVersion: 1,
                        occurredAt: observedAt,
                        redactedDiagnostic: Self.redactedDiagnostic(for: error)
                    )
                )
            }
        }
        entries.sort { $0.node.nodeID.rawValue < $1.node.nodeID.rawValue }
        let preparedEntries = entries
        let preparedFailures = failures
        let committedNodes = preparedEntries.map(\.node)

        return PreparedSearchShardPageWrite(
            write: {
                database in
                try RawAPISnapshotRepository.save(snapshot, in: database)
                for entry in preparedEntries {
                    try GitHubNodeRepository.save(entry.node, in: database)
                    _ = try WorkItemRepository.ensureWorkItem(
                        for: entry.node,
                        in: database
                    )
                }
                for failure in preparedFailures {
                    try NormalizationFailureRepository.record(failure, in: database)
                }
            },
            didCommit: {
                await accumulator.storeCommitted(
                    nodes: committedNodes
                )
            }
        )
    }

    private nonisolated static func prepareControlPageWrite(
        _ response: GitHubResponse<GitHubIssueSearchPage>,
        query: GitHubIssueSearchQuery,
        page: Int,
        accountID: AccountID,
        observedAt: Date
    ) -> PreparedSearchShardPageWrite {
        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: accountID,
            githubNodeID: nil,
            endpoint: "/search/issues?q=\(query.value)&page=\(page)",
            eTag: response.etag,
            parserVersion: 1,
            observedAt: observedAt,
            payload: response.payload
        )
        return PreparedSearchShardPageWrite(
            write: { database in
                try RawAPISnapshotRepository.save(snapshot, in: database)
            },
            didCommit: {}
        )
    }

    private nonisolated static func prepareUndecodablePageWrite(
        _ response: GitHubUndecodableResponse,
        query: GitHubIssueSearchQuery,
        page: Int,
        accountID: AccountID,
        observedAt: Date
    ) -> PreparedSearchShardPageWrite {
        let endpoint = "/search/issues?q=\(query.value)&page=\(page)"
        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: accountID,
            githubNodeID: nil,
            endpoint: endpoint,
            eTag: response.etag,
            parserVersion: 1,
            observedAt: observedAt,
            payload: response.payload
        )
        let failure = NormalizationFailure(
            id: UUID(),
            accountID: accountID,
            rawSnapshotID: snapshot.id,
            githubNodeID: nil,
            endpoint: endpoint,
            parserVersion: 1,
            occurredAt: observedAt,
            redactedDiagnostic: "GitHub search returned a response that could not be decoded."
        )
        return PreparedSearchShardPageWrite(
            write: { database in
                try RawAPISnapshotRepository.save(snapshot, in: database)
                try NormalizationFailureRepository.record(failure, in: database)
            },
            didCommit: {}
        )
    }

    private func searchEndpoint(for item: GitHubIssueSearchItem) -> String {
        "/search/issues"
    }

    private actor RoleDiscoveryAccumulator {
        private var nodeIDs: Set<GitHubNodeID> = []

        func storeCommitted(nodes: [NormalizedGitHubNode]) {
            nodeIDs.formUnion(nodes.map(\.nodeID))
        }

        func committedNodeIDs() -> Set<GitHubNodeID> {
            nodeIDs
        }
    }

    private struct NormalizedPageEntry: Sendable {
        let node: NormalizedGitHubNode
    }

    private nonisolated static func redactedDiagnostic(for error: GitHubSearchNormalizationError) -> String {
        switch error {
        case .invalidNodeID:
            "Search result contains an invalid GitHub node identifier."
        case .unknownState:
            "Search result contains an unsupported item state."
        }
    }

    private func throwForSSORequirement(
        in header: GitHubSSOHeader?,
        githubOrganizationID: UInt64
    ) throws {
        if let header = header?.scoped(to: githubOrganizationID) {
            throw OrganizationRefreshError.ssoRequirement(header)
        }
    }

    private nonisolated static func outcome(
        for kind: RoleDiscoveryStreamKind,
        error: any Error,
        githubOrganizationID: UInt64
    ) -> RoleDiscoveryStreamOutcome {
        if error is CancellationError {
            return RoleDiscoveryStreamOutcome(
                kind: kind,
                status: .partial,
                failureDetail: "Role discovery was cancelled before this stream completed."
            )
        }
        if case .ssoRequirement = error as? OrganizationRefreshError {
            return RoleDiscoveryStreamOutcome(
                kind: kind,
                status: .requiresSSO,
                failureDetail: "GitHub organization SSO authorization is required for this discovery stream."
            )
        }
        if let failure = error as? GitHubIssueSearchUndecodableResponseError,
           failure.ssoHeader?.scoped(to: githubOrganizationID) != nil {
            return RoleDiscoveryStreamOutcome(
                kind: kind,
                status: .requiresSSO,
                failureDetail: "GitHub organization SSO authorization is required for this discovery stream."
            )
        }
        if let failure = error as? GitHubFailure {
            if failure.ssoHeader?.scoped(to: githubOrganizationID) != nil {
                return RoleDiscoveryStreamOutcome(
                    kind: kind,
                    status: .requiresSSO,
                    failureDetail: "GitHub organization SSO authorization is required for this discovery stream."
                )
            }
            if let restriction = failure.accessRestriction {
                return switch restriction {
                case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
                    RoleDiscoveryStreamOutcome(
                        kind: kind,
                        status: .requiresApproval,
                        failureDetail: "GitHub organization approval is required for this discovery stream."
                    )
                case .organizationPolicyBlocked:
                    RoleDiscoveryStreamOutcome(
                        kind: kind,
                        status: .unavailable,
                        failureDetail: "Organization policy blocks this discovery stream."
                    )
                }
            }
            return switch failure.kind {
            case .rateLimited, .secondaryRateLimited:
                RoleDiscoveryStreamOutcome(
                    kind: kind,
                    status: .partial,
                    failureDetail: "GitHub rate limiting left this discovery stream incomplete."
                )
            case .forbidden, .notFound:
                RoleDiscoveryStreamOutcome(
                    kind: kind,
                    status: .unavailable,
                    failureDetail: "This discovery stream is unavailable to the selected account."
                )
            case .unauthorized, .serverFailure, .unexpectedResponse:
                RoleDiscoveryStreamOutcome(
                    kind: kind,
                    status: .failed,
                    failureDetail: "This discovery stream failed."
                )
            }
        }
        return RoleDiscoveryStreamOutcome(
            kind: kind,
            status: .failed,
            failureDetail: "This discovery stream failed."
        )
    }

    private nonisolated static func shouldDeferRemainingStreams(after error: any Error) -> Bool {
        if error is OrganizationRefreshError {
            return true
        }
        if let failure = error as? GitHubIssueSearchUndecodableResponseError {
            return failure.ssoHeader != nil
        }
        guard let failure = error as? GitHubFailure else {
            return false
        }
        if failure.ssoHeader != nil || failure.accessRestriction != nil {
            return true
        }
        return switch failure.kind {
        case .unauthorized, .rateLimited, .secondaryRateLimited, .serverFailure:
            true
        case .forbidden, .notFound, .unexpectedResponse:
            false
        }
    }

    private nonisolated static func deferredOutcome(
        for kind: RoleDiscoveryStreamKind,
        after outcome: RoleDiscoveryStreamOutcome
    ) -> RoleDiscoveryStreamOutcome {
        RoleDiscoveryStreamOutcome(
            kind: kind,
            status: outcome.status == .complete ? .partial : outcome.status,
            failureDetail: "This discovery stream was deferred after an earlier account or organization-wide failure."
        )
    }
}
