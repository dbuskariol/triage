import Foundation

struct PullRequestStatusCheckRefreshResult: Sendable {
    let refreshedPullRequestNodeIDs: [GitHubNodeID]
    let hasRemainingCandidates: Bool
    let hasBlockedKnownCandidates: Bool
    let hadFailure: Bool
}

/// Bounded coordinator ingestion for the read-only PR status-check source.
/// A failure is scoped to its candidate repository and leaves the prior
/// normalized rollup intact; it never fabricates an empty or passing result.
actor PullRequestStatusCheckRefreshService {
    private let client: GitHubPullRequestStatusCheckClient
    private let candidates: PullRequestReviewCandidateRepository
    private let statusChecks: StatusCheckRepository
    private let coverage: CoverageRepository

    init(
        client: GitHubPullRequestStatusCheckClient,
        candidates: PullRequestReviewCandidateRepository,
        statusChecks: StatusCheckRepository,
        coverage: CoverageRepository
    ) {
        self.client = client
        self.candidates = candidates
        self.statusChecks = statusChecks
        self.coverage = coverage
    }

    func refresh(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        limit: Int = 50,
        observedAt: Date = .now
    ) async throws -> PullRequestStatusCheckRefreshResult {
        let inventory = try await candidates.fairCandidates(
            scope: scope,
            streamID: streamID,
            feature: .statusChecks,
            limit: limit
        )
        var refreshed = [GitHubNodeID]()
        var hadFailure = false
        for candidate in inventory.candidates {
            try Task.checkCancellation()
            let sourceStreamID = Self.sourceStreamID(
                organizationID: scope.organizationID,
                pullRequestNodeID: candidate.nodeID,
                sourceRevision: candidate.sourceRevision
            )
            do {
                let source = try await client.allStatusChecks(pullRequestNodeID: candidate.nodeID)
                try Task.checkCancellation()
                let record = CoverageRecord(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    repositoryID: candidate.repositoryID,
                    feature: .statusChecks,
                    streamID: sourceStreamID,
                    intervalStart: nil,
                    intervalEnd: nil,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    status: .complete,
                    lastSuccessfulAt: observedAt,
                    failureDetail: nil
                )
                try await statusChecks.replace(
                    .init(
                        mergeableState: source.mergeableState,
                        checks: source.checks.map {
                            .init(context: $0.context, state: $0.state, isRequired: $0.isRequired, completedAt: $0.completedAt)
                        },
                        sourceRevision: candidate.sourceRevision,
                        observedAt: observedAt
                    ),
                    authority: .init(
                        scope: scope,
                        pullRequestNodeID: candidate.nodeID,
                        pullRequestSourceRevision: candidate.sourceRevision,
                        streamID: sourceStreamID,
                        schedulingStreamID: streamID,
                        observedAt: observedAt
                    ),
                    coverage: record,
                    rawPages: source.rawPages,
                    schedulingCandidate: candidate,
                    attemptedAt: observedAt
                )
                refreshed.append(candidate.nodeID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                hadFailure = true
                try await coverage.save(
                    CoverageRecord(
                        accountID: scope.accountID,
                        organizationID: scope.organizationID,
                        repositoryID: candidate.repositoryID,
                        feature: .statusChecks,
                        streamID: sourceStreamID,
                        intervalStart: nil,
                        intervalEnd: nil,
                        credentialRevision: scope.credentialRevision,
                        capabilityRevision: scope.capabilityRevision,
                        status: .partial,
                        lastSuccessfulAt: nil,
                        failureDetail: "Status-check rollup could not be completed for the current pull request revision."
                    ),
                    attemptedAt: observedAt
                )
            }
        }
        return .init(
            refreshedPullRequestNodeIDs: refreshed,
            hasRemainingCandidates: inventory.hasRemainingCandidates,
            hasBlockedKnownCandidates: inventory.hasBlockedKnownCandidates,
            hadFailure: hadFailure
        )
    }

    /// Coverage and raw-page provenance must distinguish not only a
    /// repository, but the exact pull request and the immutable revision that
    /// supplied its rollup. A later success for a different pull request must
    /// never rehabilitate a failed rollup retained for this candidate.
    nonisolated static func sourceStreamID(
        organizationID: OrganizationID,
        pullRequestNodeID: GitHubNodeID,
        sourceRevision: String
    ) -> SyncStreamID {
        SyncStreamID(rawValue: "pull-request-status-checks-\(organizationID.rawValue)-\(pullRequestNodeID.rawValue)-\(sourceRevision)")!
    }
}
