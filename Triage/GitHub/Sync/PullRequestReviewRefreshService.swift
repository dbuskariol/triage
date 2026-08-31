import Foundation
import GRDB

enum RequestedReviewerCorroboration: Sendable, Equatable {
    case agreement
    case disagreement
    case sourceUnavailable
}

struct PullRequestReviewRefreshResult: Sendable {
    let refreshedPullRequestNodeIDs: [GitHubNodeID]
    let hasRemainingCandidates: Bool
    let hasBlockedKnownCandidates: Bool
    let ssoHeaders: [GitHubSSOHeader]
    /// Candidate-local terminal failures have durable raw/classified evidence.
    /// The organization coordinator must not treat an otherwise exhausted batch
    /// containing these classifications as complete coverage.
    let failureClassifications: [ReviewCandidateFailureClassification]
    let hasUncorroboratedRequestedReviewers: Bool

    init(
        refreshedPullRequestNodeIDs: [GitHubNodeID],
        hasRemainingCandidates: Bool,
        hasBlockedKnownCandidates: Bool,
        ssoHeaders: [GitHubSSOHeader],
        failureClassifications: [ReviewCandidateFailureClassification],
        hasUncorroboratedRequestedReviewers: Bool = false
    ) {
        self.refreshedPullRequestNodeIDs = refreshedPullRequestNodeIDs
        self.hasRemainingCandidates = hasRemainingCandidates
        self.hasBlockedKnownCandidates = hasBlockedKnownCandidates
        self.ssoHeaders = ssoHeaders
        self.failureClassifications = failureClassifications
        self.hasUncorroboratedRequestedReviewers = hasUncorroboratedRequestedReviewers
    }

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }
}

actor PullRequestReviewRefreshService {
    private let client: GitHubPullRequestClient
    private let candidateRepository: PullRequestReviewCandidateRepository
    private let failureEnvelopeRepository: ReviewCandidateFailureEnvelopeRepository?
    private let corroborationOverride: RequestedReviewerCorroboration?

    init(
        client: GitHubPullRequestClient,
        candidateRepository: PullRequestReviewCandidateRepository,
        failureEnvelopeRepository: ReviewCandidateFailureEnvelopeRepository? = nil,
        corroborationOverride: RequestedReviewerCorroboration? = nil
    ) {
        self.client = client
        self.candidateRepository = candidateRepository
        self.failureEnvelopeRepository = failureEnvelopeRepository
        self.corroborationOverride = corroborationOverride
    }

    func refresh(
        scope: SynchronizationScope,
        githubOrganizationID: UInt64,
        limit: Int = 50,
        observedAt: Date = .now,
        streamID: SyncStreamID
    ) async throws -> PullRequestReviewRefreshResult {
        let accountID = scope.accountID
        try await validateCurrentScope(scope)
        let inventory = try await selectCandidates(
            scope: scope,
            streamID: streamID,
            limit: limit
        )
        try await validateCurrentScope(scope)
        var refreshedPullRequestNodeIDs = [GitHubNodeID]()
        var ssoHeaders = [GitHubSSOHeader]()
        var failureClassifications = [ReviewCandidateFailureClassification]()
        var hasUncorroboratedRequestedReviewers = false
        let observedAtMilliseconds = Self.milliseconds(observedAt)

        candidateLoop: for candidate in inventory.candidates {
            let reviewFetch: GitHubPullRequestReviewFetchResult
            do {
                try await validateCurrentScope(scope)
                reviewFetch = try await client.allReviewsPreservingFailure(
                    repository: candidate.repository,
                    number: candidate.number,
                    githubOrganizationID: githubOrganizationID
                )
                try await validateCurrentScope(scope)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await validateCurrentScope(scope)
                throw error
            }
            let reviews: GitHubPullRequestReviewInventory
            let reviewRawPages: [GitHubPullRequestReviewRawPage]
            switch reviewFetch {
            case let .inventory(inventory, rawPages):
                reviews = inventory
                reviewRawPages = rawPages
            case let .failure(failure):
                ssoHeaders.append(contentsOf: failure.ssoHeaders)
                let classification = try await publishFailure(
                    failure,
                    accumulatedRawPages: [],
                    candidate: candidate,
                    scope: scope,
                    streamID: streamID,
                    githubOrganizationID: githubOrganizationID,
                    attemptedAt: observedAt
                )
                failureClassifications.append(classification)
                if Self.continuesAfter(classification) { continue }
                break candidateLoop
            }
            ssoHeaders.append(contentsOf: reviews.ssoHeaders)
            if reviews.ssoHeader?.scoped(to: githubOrganizationID) != nil {
                let failure = GitHubPullRequestReviewFetchFailure(
                    terminalRequestKey: reviewRawPages.last?.requestKey
                        ?? Self.reviewsRequestKey(for: candidate),
                    rawPages: reviewRawPages,
                    terminalFailure: .github(
                        GitHubFailure(
                            kind: .forbidden,
                            statusCode: 403,
                            ssoHeader: reviews.ssoHeader
                        )
                    )
                )
                let classification = try await publishFailure(
                    failure,
                    accumulatedRawPages: [],
                    candidate: candidate,
                    scope: scope,
                    streamID: streamID,
                    githubOrganizationID: githubOrganizationID,
                    attemptedAt: observedAt
                )
                failureClassifications.append(classification)
                break candidateLoop
            }
            let requestedReviewersFetch: GitHubRequestedReviewersFetchResult
            do {
                try await validateCurrentScope(scope)
                requestedReviewersFetch = try await client.requestedReviewersPreservingFailure(
                    repository: candidate.repository,
                    number: candidate.number
                )
                try await validateCurrentScope(scope)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await validateCurrentScope(scope)
                throw error
            }
            let requestedReviewers: GitHubResponse<GitHubRequestedReviewersDTO>
            switch requestedReviewersFetch {
            case let .response(response):
                requestedReviewers = response
            case let .failure(failure):
                ssoHeaders.append(contentsOf: failure.ssoHeaders)
                let classification = try await publishFailure(
                    failure,
                    accumulatedRawPages: reviewRawPages,
                    candidate: candidate,
                    scope: scope,
                    streamID: streamID,
                    githubOrganizationID: githubOrganizationID,
                    attemptedAt: observedAt
                )
                failureClassifications.append(classification)
                if Self.continuesAfter(classification) { continue }
                break candidateLoop
            }
            if let ssoHeader = requestedReviewers.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
            let candidateSSOHeader = GitHubSSOHeader.combined(
                [reviews.ssoHeader, requestedReviewers.ssoHeader]
            )
            if candidateSSOHeader?.scoped(to: githubOrganizationID) != nil {
                let requestedRawPage = Self.rawPage(
                    requestedReviewers,
                    requestKey: Self.requestedReviewersRequestKey(for: candidate)
                )
                let failure = GitHubPullRequestReviewFetchFailure(
                    terminalRequestKey: requestedRawPage.requestKey,
                    rawPages: [requestedRawPage],
                    terminalFailure: .github(
                        GitHubFailure(
                            kind: .forbidden,
                            statusCode: 403,
                            ssoHeader: candidateSSOHeader
                        )
                    )
                )
                let classification = try await publishFailure(
                    failure,
                    accumulatedRawPages: reviewRawPages,
                    candidate: candidate,
                    scope: scope,
                    streamID: streamID,
                    githubOrganizationID: githubOrganizationID,
                    attemptedAt: observedAt
                )
                failureClassifications.append(classification)
                break candidateLoop
            }
            let corroboration: RequestedReviewerCorroboration
            if let corroborationOverride {
                corroboration = corroborationOverride
            } else {
                corroboration = try await candidateRepository.writeTransaction(accountID: accountID) { database in
                    try Self.validateCurrentScope(scope, in: database)
                    return Self.corroborateRequestedReviewers(
                        requestedReviewers.value,
                        candidate: candidate,
                        accountID: accountID,
                        in: database
                    )
                }
            }
            guard corroboration == .agreement else {
                hasUncorroboratedRequestedReviewers = true
                continue
            }
            let traversal = Self.completeTraversal(
                candidate: candidate,
                scope: scope,
                streamID: streamID,
                reviews: reviews.reviews,
                reviewRawPages: reviewRawPages,
                requestedReviewers: requestedReviewers.value,
                requestedReviewersResponse: requestedReviewers,
                observedAt: observedAt
            )
            do {
                try await candidateRepository.writeTransaction(accountID: accountID) { database in
                try Self.validateCurrentScope(scope, in: database)
                let receipt = try ReviewCandidateCompleteTraversalReceiptRepository.persist(
                    traversal,
                    in: database
                )
                let replacementProof = try PullRequestReviewReplacementProof.make(
                    reviews: reviews.reviews,
                    requestedReviewers: requestedReviewers.value,
                    completeTraversalReceipt: receipt,
                    in: database
                )
                try PullRequestReviewRepository.replace(
                    reviews.reviews,
                    pullRequestNodeID: candidate.nodeID,
                    accountID: accountID,
                    observedAtMilliseconds: observedAtMilliseconds,
                    replacementProof: replacementProof,
                    in: database
                )
                try PullRequestReviewRequestRepository.replace(
                    requestedReviewers.value,
                    pullRequestNodeID: candidate.nodeID,
                    accountID: accountID,
                    observedAtMilliseconds: observedAtMilliseconds,
                    replacementProof: replacementProof,
                    in: database
                )
                try PullRequestReviewCandidateRepository.advanceFairSchedule(
                    after: candidate,
                    scope: scope,
                    streamID: streamID,
                    feature: .reviews,
                    at: observedAt,
                    in: database
                )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch is PullRequestReviewRepositoryError,
                    is PullRequestReviewRequestRepositoryError,
                    is ReviewCandidateCompleteTraversalReceiptRepositoryError,
                    is PullRequestReviewReplacementProofError {
                let requestedRawPage = Self.rawPage(
                    requestedReviewers,
                    requestKey: Self.requestedReviewersRequestKey(for: candidate)
                )
                let failure = GitHubPullRequestReviewFetchFailure(
                    terminalRequestKey: requestedRawPage.requestKey,
                    rawPages: [requestedRawPage],
                    terminalFailure: .normalization
                )
                let classification = try await publishFailure(
                    failure,
                    accumulatedRawPages: reviewRawPages,
                    candidate: candidate,
                    scope: scope,
                    streamID: streamID,
                    githubOrganizationID: githubOrganizationID,
                    attemptedAt: observedAt
                )
                failureClassifications.append(classification)
                break candidateLoop
            }
            try await validateCurrentScope(scope)
            refreshedPullRequestNodeIDs.append(candidate.nodeID)
        }
        try await validateCurrentScope(scope)
        return PullRequestReviewRefreshResult(
            refreshedPullRequestNodeIDs: refreshedPullRequestNodeIDs,
            hasRemainingCandidates: inventory.hasRemainingCandidates,
            hasBlockedKnownCandidates: inventory.hasBlockedKnownCandidates,
            ssoHeaders: ssoHeaders,
            failureClassifications: failureClassifications,
            hasUncorroboratedRequestedReviewers: hasUncorroboratedRequestedReviewers
        )
    }

    private nonisolated static func corroborateRequestedReviewers(
        _ rest: GitHubRequestedReviewersDTO,
        candidate: PullRequestReviewCandidate,
        accountID: AccountID,
        in database: Database
    ) -> RequestedReviewerCorroboration {
        guard let restIDs = reviewerIDs(from: rest) else { return .sourceUnavailable }
        let payloads = (try? Data.fetchAll(
            database,
            sql: "SELECT payload FROM raw_api_snapshots WHERE account_id = ? AND endpoint = ? ORDER BY observed_at_ms DESC",
            arguments: [accountID.rawValue, "graphql:TriageHydrateNodes"]
        )) ?? []
        for payload in payloads {
            guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let data = root["data"] as? [String: Any],
                  let nodes = data["nodes"] as? [[String: Any]]
            else { continue }
            for node in nodes where node["id"] as? String == candidate.nodeID.rawValue {
                guard node["updatedAt"] as? String == candidate.sourceRevision,
                      let requests = node["reviewRequests"] as? [String: Any],
                      let pageInfo = requests["pageInfo"] as? [String: Any],
                      pageInfo["hasNextPage"] as? Bool == false,
                      let requestNodes = requests["nodes"] as? [[String: Any]]
                else { return .sourceUnavailable }
                let graphQLIDs = requestNodes.compactMap { ($0["requestedReviewer"] as? [String: Any])?["id"] as? String }
                    .compactMap(GitHubNodeID.init(rawValue:))
                guard graphQLIDs.count == requestNodes.count, Set(graphQLIDs).count == graphQLIDs.count else {
                    return .sourceUnavailable
                }
                return Set(graphQLIDs) == restIDs ? .agreement : .disagreement
            }
        }
        return .sourceUnavailable
    }

    private nonisolated static func reviewerIDs(from value: GitHubRequestedReviewersDTO) -> Set<GitHubNodeID>? {
        let ids = (value.users + value.teams).compactMap { GitHubNodeID(rawValue: $0.nodeID) }
        guard ids.count == value.users.count + value.teams.count, Set(ids).count == ids.count else { return nil }
        return Set(ids)
    }

    private func selectCandidates(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        limit: Int
    ) async throws -> PullRequestReviewCandidateInventory {
        do {
            return try await candidateRepository.fairCandidates(
                scope: scope,
                streamID: streamID,
                feature: .reviews,
                limit: limit
            )
        } catch OrganizationSchedulerStateRepositoryError.staleSynchronizationScope,
                OrganizationSchedulerStateRepositoryError.organizationScopeMismatch {
            throw CancellationError()
        }
    }

    private func validateCurrentScope(_ scope: SynchronizationScope) async throws {
        try Task.checkCancellation()
        do {
            try await candidateRepository.writeTransaction(accountID: scope.accountID) { database in
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

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func publishFailure(
        _ failure: GitHubPullRequestReviewFetchFailure,
        accumulatedRawPages: [GitHubPullRequestReviewRawPage],
        candidate: PullRequestReviewCandidate,
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        githubOrganizationID: UInt64,
        attemptedAt: Date
    ) async throws -> ReviewCandidateFailureClassification {
        guard failureEnvelopeRepository != nil else {
            // The caller has not yet supplied the explicit durable dependency.
            // Preserve the historical fail-closed behavior rather than advance
            // a cursor without provenance.
            throw failure
        }
        let classification = Self.classification(
            for: failure.terminalFailure,
            ssoHeaders: failure.ssoHeaders,
            githubOrganizationID: githubOrganizationID
        )
        let requestIdentity = Self.requestIdentity(
            scope: scope,
            streamID: streamID,
            requestKey: failure.terminalRequestKey
        )
        let rawPages = (accumulatedRawPages + failure.rawPages).map { page in
            ReviewCandidateFailureRawPage(
                ordinal: page.ordinal,
                rawSnapshotID: RawAPISnapshotID.make(),
                requestIdentity: Self.requestIdentity(
                    scope: scope,
                    streamID: streamID,
                    requestKey: page.requestKey
                ),
                endpoint: page.requestKey,
                eTag: page.eTag,
                lastModified: page.lastModified,
                payload: page.payload
            )
        }
        let publication = ReviewCandidateFailurePublication(
            scope: scope,
            feature: .reviews,
            streamID: streamID,
            candidate: candidate,
            requestIdentity: requestIdentity,
            parserVersion: 1,
            attemptedAt: attemptedAt,
            terminalAt: attemptedAt,
            classification: classification,
            redactedDiagnostic: Self.diagnostic(for: classification),
            rawProvenance: Self.rawProvenance(
                for: failure,
                accumulatedRawPages: accumulatedRawPages,
                classification: classification
            ),
            rawPages: rawPages
        )
        do {
            try await candidateRepository.writeTransaction(accountID: scope.accountID) { database in
                try Self.validateCurrentScope(scope, in: database)
                try ReviewCandidateFailureEnvelopeRepository.publish(publication, in: database)
            }
        } catch ReviewCandidateFailureEnvelopeRepositoryError.staleSynchronizationScope {
            throw CancellationError()
        }
        try await validateCurrentScope(scope)
        return classification
    }

    private nonisolated static func classification(
        for failure: GitHubPullRequestReviewTerminalFailure,
        ssoHeaders: [GitHubSSOHeader],
        githubOrganizationID: UInt64
    ) -> ReviewCandidateFailureClassification {
        if GitHubSSOHeader.combined(ssoHeaders)?.scoped(to: githubOrganizationID) != nil {
            return .ssoRequired
        }
        switch failure {
        case let .github(githubFailure):
            switch githubFailure.accessRestriction {
            case .organizationApprovalRequired?, .oauthApplicationApprovalRequired?: return .approvalRequired
            case .organizationPolicyBlocked?: return .unavailableOrPermission
            case nil: break
            }
            return switch githubFailure.kind {
            case .unauthorized: .authenticationRequired
            case .rateLimited, .secondaryRateLimited: .rateLimited
            case .forbidden, .notFound: .unavailableOrPermission
            case .serverFailure: .serverFailure
            case .unexpectedResponse: .transportFailure
            }
        case .transport: return .transportFailure
        case .malformedResponse, .pagination: return .malformedResponse
        case .normalization: return .normalizationFailure
        }
    }

    private nonisolated static func diagnostic(
        for classification: ReviewCandidateFailureClassification
    ) -> String {
        switch classification {
        case .authenticationRequired: "GitHub authentication is required to refresh this pull request."
        case .ssoRequired: "GitHub organization SSO authorization is required to refresh this pull request."
        case .approvalRequired: "GitHub organization approval is required to refresh this pull request."
        case .rateLimited: "GitHub rate limiting prevented this pull request refresh."
        case .unavailableOrPermission: "This pull request review source is unavailable to the selected account."
        case .transportFailure: "A network or transport failure prevented this pull request refresh."
        case .serverFailure: "GitHub could not complete this pull request refresh."
        case .malformedResponse: "GitHub returned a malformed pull request review response."
        case .normalizationFailure: "GitHub pull request review data could not be normalized."
        }
    }

    private nonisolated static func rawProvenance(
        for failure: GitHubPullRequestReviewFetchFailure,
        accumulatedRawPages: [GitHubPullRequestReviewRawPage],
        classification: ReviewCandidateFailureClassification
    ) -> ReviewCandidateFailureRawProvenance {
        let rawPages = accumulatedRawPages + failure.rawPages
        let hasTerminalRawPage = rawPages.last?.requestKey == failure.terminalRequestKey
        if !rawPages.isEmpty, !hasTerminalRawPage {
            switch failure.terminalFailure {
            case .transport:
                return .accumulatedPagesBodylessTerminalTransportFailure
            case let .github(githubFailure) where Self.isBodylessHTTPFailure(
                classification,
                statusCode: githubFailure.statusCode
            ):
                return .accumulatedPagesBodylessTerminalHTTPFailure(
                    statusCode: githubFailure.statusCode
                )
            case .github, .malformedResponse, .pagination, .normalization:
                return .terminalRawPage
            }
        }
        if rawPages.isEmpty,
           case .transport = failure.terminalFailure {
            return .zeroRawTransportFailure
        }
        if rawPages.isEmpty,
           classification == .ssoRequired,
           case let .github(githubFailure) = failure.terminalFailure,
           githubFailure.kind == .forbidden,
           githubFailure.statusCode == 403 {
            return .zeroRawBodylessSelectedOrganizationSSOFailure
        }
        if rawPages.isEmpty,
           case let .github(githubFailure) = failure.terminalFailure,
           classification == .unavailableOrPermission,
           (githubFailure.kind == .forbidden || githubFailure.kind == .notFound),
           githubFailure.statusCode == 403 || githubFailure.statusCode == 404 {
            return .zeroRawBodylessHTTPAccessFailure(statusCode: githubFailure.statusCode)
        }
        if rawPages.isEmpty,
           case let .github(githubFailure) = failure.terminalFailure,
           Self.isBodylessHTTPFailure(classification, statusCode: githubFailure.statusCode) {
            return .zeroRawBodylessTerminalHTTPFailure(statusCode: githubFailure.statusCode)
        }
        return .terminalRawPage
    }

    private nonisolated static func isBodylessHTTPFailure(
        _ classification: ReviewCandidateFailureClassification,
        statusCode: Int
    ) -> Bool {
        switch statusCode {
        case 401:
            classification == .authenticationRequired
        case 403:
            [.approvalRequired, .ssoRequired, .rateLimited, .unavailableOrPermission]
                .contains(classification)
        case 404:
            classification == .unavailableOrPermission
        case 429:
            classification == .rateLimited
        case 500...599:
            classification == .serverFailure
        default:
            false
        }
    }

    private nonisolated static func continuesAfter(
        _ classification: ReviewCandidateFailureClassification
    ) -> Bool {
        classification == .unavailableOrPermission
    }

    private nonisolated static func requestIdentity(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        requestKey: String
    ) -> ConditionalRequestIdentity {
        ConditionalRequestIdentity(
            scope: scope,
            feature: .reviews,
            streamID: streamID,
            requestKey: requestKey
        )
    }

    private nonisolated static func reviewsRequestKey(for candidate: PullRequestReviewCandidate) -> String {
        "GET \(candidate.repository.path)/pulls/\(candidate.number)/reviews?per_page=100"
    }

    private nonisolated static func requestedReviewersRequestKey(for candidate: PullRequestReviewCandidate) -> String {
        "GET \(candidate.repository.path)/pulls/\(candidate.number)/requested_reviewers"
    }

    private nonisolated static func rawPage(
        _ response: GitHubResponse<GitHubRequestedReviewersDTO>,
        requestKey: String
    ) -> GitHubPullRequestReviewRawPage {
        .init(
            requestKey: requestKey,
            ordinal: 1,
            payload: response.payload,
            eTag: response.etag,
            lastModified: response.lastModified,
            ssoHeader: response.ssoHeader
        )
    }

    private nonisolated static func completeTraversal(
        candidate: PullRequestReviewCandidate,
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        reviews: [GitHubPullRequestReviewDTO],
        reviewRawPages: [GitHubPullRequestReviewRawPage],
        requestedReviewers: GitHubRequestedReviewersDTO,
        requestedReviewersResponse: GitHubResponse<GitHubRequestedReviewersDTO>,
        observedAt: Date
    ) -> ReviewCandidateCompleteTraversal {
        let reviewPages = reviewRawPages.enumerated().map { offset, rawPage in
            ReviewCandidateTraversalPage(
                ordinal: offset + 1,
                rawSnapshotID: .make(),
                requestIdentity: requestIdentity(
                    scope: scope,
                    streamID: streamID,
                    requestKey: rawPage.requestKey
                ),
                endpoint: rawPage.requestKey,
                eTag: rawPage.eTag,
                lastModified: rawPage.lastModified,
                payload: rawPage.payload,
                isTerminal: offset == reviewRawPages.indices.last
            )
        }
        let requestedRequestKey = requestedReviewersRequestKey(for: candidate)
        let requestedPage = ReviewCandidateTraversalPage(
            ordinal: 1,
            rawSnapshotID: .make(),
            requestIdentity: requestIdentity(
                scope: scope,
                streamID: streamID,
                requestKey: requestedRequestKey
            ),
            endpoint: requestedRequestKey,
            eTag: requestedReviewersResponse.etag,
            lastModified: requestedReviewersResponse.lastModified,
            payload: requestedReviewersResponse.payload,
            isTerminal: true
        )
        return ReviewCandidateCompleteTraversal(
            scope: scope,
            feature: .reviews,
            streamID: streamID,
            candidate: candidate,
            candidateSourceRevision: candidate.sourceRevision,
            parserVersion: 1,
            observedAt: observedAt,
            normalizedDigest: PullRequestReviewReplacementProof.normalizedDigest(
                reviews: reviews,
                requestedReviewers: requestedReviewers
            ),
            segments: [
                .init(kind: .reviewHistory, pages: reviewPages),
                .init(kind: .requestedReviewers, pages: [requestedPage])
            ]
        )
    }

}
