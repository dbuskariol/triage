import Foundation

enum GitHubTimelineRefreshServiceError: Error, Equatable, Sendable {
    case invalidLimit
    case invalidBudget
    case paginationLimitExceeded
}

struct TimelineRefreshBudget: Equatable, Sendable {
    static let standard = TimelineRefreshBudget(
        maximumPages: 100,
        maximumDecodedBytes: 32 * 1_024 * 1_024
    )

    let maximumPages: Int
    let maximumDecodedBytes: Int
}

enum GitHubTimelineRefreshOutcomeStatus: Equatable, Sendable {
    case refreshed
    case ssoRequired(GitHubSSOHeader)
    case approvalRequired
    case authenticationRequired
    case rateLimited(retryAt: Date?)
    case unavailableOrPermission
    case deferredByBudget
    case failed
}

struct GitHubTimelineRefreshOutcome: Equatable, Sendable {
    let nodeID: GitHubNodeID
    let repositoryID: RepositoryID
    let number: Int
    let status: GitHubTimelineRefreshOutcomeStatus
}

struct GitHubTimelineCoverageAssessment: Equatable, Sendable {
    let status: CoverageStatus
    let failureDetail: String?
}

struct GitHubTimelineRefreshResult: Sendable {
    let outcomes: [GitHubTimelineRefreshOutcome]
    let hasRemainingCandidates: Bool
    let hasBudgetContinuation: Bool

    var refreshedTimelineNodeIDs: [GitHubNodeID] {
        outcomes.compactMap { $0.status == .refreshed ? $0.nodeID : nil }
    }

    var incompleteTimelineNodeIDs: [GitHubNodeID] {
        outcomes.compactMap { $0.status == .refreshed ? nil : $0.nodeID }
    }

    var hasContinuation: Bool {
        hasRemainingCandidates || hasBudgetContinuation || !incompleteTimelineNodeIDs.isEmpty
    }

    var ssoHeaders: [GitHubSSOHeader] {
        outcomes.compactMap { outcome in
            guard case let .ssoRequired(header) = outcome.status else { return nil }
            return header
        }
    }

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }

    var coverageAssessment: GitHubTimelineCoverageAssessment {
        let statuses = outcomes.map(\.status)
        if ssoHeader != nil {
            return .init(
                status: .requiresSSO,
                failureDetail: "GitHub organization SSO authorization is required for some timelines."
            )
        }
        if statuses.contains(.approvalRequired) {
            return .init(
                status: .requiresApproval,
                failureDetail: "GitHub organization approval is required for some timelines."
            )
        }
        if statuses.contains(.authenticationRequired) || statuses.contains(.failed) {
            return .init(status: .failed, failureDetail: "Some timelines could not be refreshed.")
        }
        if statuses.contains(.unavailableOrPermission) {
            return .init(
                status: .unavailable,
                failureDetail: "Some timelines are unavailable to the selected account."
            )
        }
        if statuses.contains(where: {
            if case .rateLimited = $0 { return true }
            return false
        }) {
            return .init(
                status: .partial,
                failureDetail: "GitHub rate limiting left some timeline coverage incomplete."
            )
        }
        if hasRemainingCandidates || hasBudgetContinuation || statuses.contains(.deferredByBudget) {
            return .init(
                status: .partial,
                failureDetail: "Additional timeline work remains for a later bounded refresh."
            )
        }
        return .init(status: .complete, failureDetail: nil)
    }

    func coverageAssessment(for repositoryID: RepositoryID) -> GitHubTimelineCoverageAssessment {
        GitHubTimelineRefreshResult(
            outcomes: outcomes.filter { $0.repositoryID == repositoryID },
            hasRemainingCandidates: hasRemainingCandidates,
            hasBudgetContinuation: hasBudgetContinuation
        ).coverageAssessment
    }
}

actor GitHubTimelineRefreshService {
    private static let maximumTimelinePages = 100

    private enum ControlFlowError: Error {
        case budgetExhausted
        case ssoRequired(GitHubSSOHeader)
    }

    private struct BudgetMeter {
        var remainingPages: Int
        var remainingDecodedBytes: Int

        mutating func reservePage() -> Bool {
            guard remainingPages > 0 else { return false }
            remainingPages -= 1
            return true
        }

        mutating func consumeDecodedBytes(_ count: Int) -> Bool {
            guard count >= 0, count <= remainingDecodedBytes else {
                remainingDecodedBytes = 0
                return false
            }
            remainingDecodedBytes -= count
            return true
        }
    }

    private let client: GitHubTimelineClient
    private let candidateRepository: TimelineCandidateRepository
    private let eventRepository: TimelineEventRepository
    private let normalizationFailureRepository: NormalizationFailureRepository
    private let conditionalRequestCacheRepository: ConditionalRequestCacheRepository

    init(
        client: GitHubTimelineClient,
        candidateRepository: TimelineCandidateRepository,
        eventRepository: TimelineEventRepository,
        normalizationFailureRepository: NormalizationFailureRepository,
        conditionalRequestCacheRepository: ConditionalRequestCacheRepository
    ) {
        self.client = client
        self.candidateRepository = candidateRepository
        self.eventRepository = eventRepository
        self.normalizationFailureRepository = normalizationFailureRepository
        self.conditionalRequestCacheRepository = conditionalRequestCacheRepository
    }

    func refresh(
        scope: SynchronizationScope,
        githubOrganizationID: UInt64,
        currentUserID: ActorID,
        candidates requestedCandidates: [TimelineCandidate]? = nil,
        limit: Int = 50,
        budget: TimelineRefreshBudget = .standard,
        observedAt: Date = .now
    ) async throws -> GitHubTimelineRefreshResult {
        let accountID = scope.accountID
        let organizationID = scope.organizationID
        guard limit > 0, limit < .max else {
            throw GitHubTimelineRefreshServiceError.invalidLimit
        }
        guard budget.maximumPages > 0,
              budget.maximumPages < .max,
              budget.maximumDecodedBytes > 0,
              budget.maximumDecodedBytes < .max
        else {
            throw GitHubTimelineRefreshServiceError.invalidBudget
        }
        _ = currentUserID
        let inventory: TimelineCandidateInventory
        if let requestedCandidates {
            inventory = try await candidateRepository.validatedCandidates(
                requestedCandidates,
                accountID: accountID,
                organizationID: organizationID,
                limit: limit
            )
        } else {
            inventory = try await candidateRepository.candidates(
                accountID: accountID,
                organizationID: organizationID,
                limit: limit
            )
        }

        var outcomes = [GitHubTimelineRefreshOutcome]()
        outcomes.reserveCapacity(inventory.candidates.count)
        var meter = BudgetMeter(
            remainingPages: budget.maximumPages,
            remainingDecodedBytes: budget.maximumDecodedBytes
        )
        var hasBudgetContinuation = false

        candidateLoop: for (index, candidate) in inventory.candidates.enumerated() {
            try Task.checkCancellation()
            do {
                let status = try await refresh(
                    candidate: candidate,
                    scope: scope,
                    githubOrganizationID: githubOrganizationID,
                    observedAt: observedAt,
                    budget: &meter
                )
                outcomes.append(outcome(for: candidate, status: status))
            } catch is CancellationError {
                throw CancellationError()
            } catch ControlFlowError.budgetExhausted {
                try await candidateRepository.fail(
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                outcomes.append(outcome(for: candidate, status: .deferredByBudget))
                for deferred in inventory.candidates.dropFirst(index + 1) {
                    outcomes.append(outcome(for: deferred, status: .deferredByBudget))
                }
                hasBudgetContinuation = true
                break candidateLoop
            } catch let ControlFlowError.ssoRequired(header) {
                try await candidateRepository.fail(
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                outcomes.append(outcome(for: candidate, status: .ssoRequired(header)))
            } catch let error as TimelineEventRepositoryError {
                switch error {
                case .accountScopeMismatch, .candidateScopeMismatch:
                    throw error
                case let .invalidPersistedPage(provenance):
                    if let provenance {
                        try await recordNormalizationFailure(
                            rawPage: provenance,
                            candidate: candidate,
                            accountID: accountID,
                            observedAt: observedAt,
                            diagnostic: "Saved timeline page could not be decoded."
                        )
                    }
                    try await markIncomplete(
                        error,
                        candidate: candidate,
                        accountID: accountID,
                        organizationID: organizationID,
                        at: observedAt
                    )
                    outcomes.append(outcome(for: candidate, status: .failed))
                case .invalidRawPage, .invalidEventPayload,
                        .duplicateEventID, .eventBelongsToAnotherSubject:
                    try await markIncomplete(
                        error,
                        candidate: candidate,
                        accountID: accountID,
                        organizationID: organizationID,
                        at: observedAt
                    )
                    outcomes.append(outcome(for: candidate, status: .failed))
                }
            } catch let error as TimelineCandidateRepositoryError {
                throw error
            } catch {
                try await markIncomplete(
                    error,
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                outcomes.append(
                    outcome(
                        for: candidate,
                        status: Self.status(
                            for: error,
                            githubOrganizationID: githubOrganizationID,
                            observedAt: observedAt
                        )
                    )
                )
            }
        }

        return GitHubTimelineRefreshResult(
            outcomes: outcomes,
            hasRemainingCandidates: inventory.hasRemainingCandidates,
            hasBudgetContinuation: hasBudgetContinuation
        )
    }

    private func refresh(
        candidate: TimelineCandidate,
        scope: SynchronizationScope,
        githubOrganizationID: UInt64,
        observedAt: Date,
        budget: inout BudgetMeter
    ) async throws -> GitHubTimelineRefreshOutcomeStatus {
        let accountID = scope.accountID
        let organizationID = scope.organizationID
        var ssoHeaders = [GitHubSSOHeader]()
        var firstPageValidators: GitHubHTTPValidators?
        var resumedFromCheckpoint = false
        let saved: TimelineSavedPageInventory
        if let checkpoint = try await candidateRepository.checkpoint(
            for: candidate,
            accountID: accountID,
            organizationID: organizationID
        ) {
            resumedFromCheckpoint = true
            try Task.checkCancellation()
            if let nextPageURL = checkpoint.nextPageURL {
                let resumedPages = try await eventRepository.savedPages(
                    for: candidate,
                    scope: scope,
                    accountID: accountID,
                    organizationID: organizationID
                )
                try Task.checkCancellation()
                try await fetchRemainingPages(
                    from: nextPageURL,
                    candidate: candidate,
                    startingAt: resumedPages.pageCount + 1,
                    scope: scope,
                    accountID: accountID,
                    organizationID: organizationID,
                    githubOrganizationID: githubOrganizationID,
                    observedAt: observedAt,
                    ssoHeaders: &ssoHeaders,
                    budget: &budget
                )
                try Task.checkCancellation()
            } else {
                guard checkpoint.isDownloadComplete else {
                    throw TimelineCandidateRepositoryError.invalidCheckpoint
                }
            }
            saved = try await eventRepository.savedPages(
                for: candidate,
                scope: scope,
                accountID: accountID,
                organizationID: organizationID
            )
            try Task.checkCancellation()
        } else {
            let identity = Self.conditionalRequestIdentity(for: candidate, scope: scope)
            let validator = try await conditionalRequestCacheRepository.validator(for: identity)
            let requestValidators = try Self.httpValidators(
                eTag: validator?.eTag,
                lastModified: validator?.lastModified
            )
            try Task.checkCancellation()
            guard budget.reservePage() else {
                throw ControlFlowError.budgetExhausted
            }
            var firstPageResult = try await firstPagePreservingRejectedPayload(
                candidate: candidate,
                repository: candidate.repository,
                issueOrPullRequestNumber: candidate.number,
                validators: requestValidators,
                scope: scope,
                accountID: accountID,
                organizationID: organizationID,
                githubOrganizationID: githubOrganizationID,
                observedAt: observedAt,
                budget: &budget
            )
            try Task.checkCancellation()
            if case let .notModified(ssoHeader) = firstPageResult {
                if let ssoHeader {
                    ssoHeaders.append(ssoHeader)
                }
                if let scopedHeader = GitHubSSOHeader.combined(ssoHeaders)?.scoped(
                    to: githubOrganizationID
                ) {
                    throw ControlFlowError.ssoRequired(scopedHeader)
                }
                try Task.checkCancellation()
                if let validator,
                   try await eventRepository.completeNotModifiedReplay(
                    candidate: candidate,
                    validator: validator,
                    observedAt: observedAt
                   ) {
                    try Task.checkCancellation()
                    return .refreshed
                }
                try Task.checkCancellation()
                guard budget.reservePage() else {
                    throw ControlFlowError.budgetExhausted
                }
                firstPageResult = try await firstPagePreservingRejectedPayload(
                    candidate: candidate,
                    repository: candidate.repository,
                    issueOrPullRequestNumber: candidate.number,
                    validators: nil,
                    scope: scope,
                    accountID: accountID,
                    organizationID: organizationID,
                    githubOrganizationID: githubOrganizationID,
                    observedAt: observedAt,
                    budget: &budget
                )
                try Task.checkCancellation()
            }
            switch firstPageResult {
            case .notModified:
                throw GitHubTimelineClientError.unexpectedNotModified
            case let .page(firstPage):
                firstPageValidators = try Self.httpValidators(
                    eTag: firstPage.etag,
                    lastModified: firstPage.lastModified
                )
                if let ssoHeader = firstPage.ssoHeader {
                    ssoHeaders.append(ssoHeader)
                }
                let rawSnapshotID = try await eventRepository.saveRawPage(
                    firstPage,
                    candidate: candidate,
                    pageIndex: 1,
                    requestKey: Self.requestKey(for: candidate),
                    scope: scope,
                    accountID: accountID,
                    organizationID: organizationID,
                    observedAt: observedAt
                )
                try Task.checkCancellation()
                if let scopedHeader = GitHubSSOHeader.combined(ssoHeaders)?.scoped(
                    to: githubOrganizationID
                ) {
                    throw ControlFlowError.ssoRequired(scopedHeader)
                }
                guard budget.consumeDecodedBytes(firstPage.payload.count) else {
                    throw ControlFlowError.budgetExhausted
                }
                try await validate(
                    firstPage.values,
                    rawSnapshotID: rawSnapshotID,
                    candidate: candidate,
                    accountID: accountID,
                    observedAt: observedAt
                )
                try Task.checkCancellation()
                try await eventRepository.commitValidatedRawPage(
                    rawSnapshotID,
                    candidate: candidate,
                    pageIndex: 1,
                    requestKey: Self.requestKey(for: candidate),
                    scope: scope,
                    nextPageURL: firstPage.nextPageURL,
                    accountID: accountID,
                    organizationID: organizationID,
                    attemptedAt: observedAt
                )
                try Task.checkCancellation()
                if let nextPageURL = firstPage.nextPageURL {
                    try await fetchRemainingPages(
                        from: nextPageURL,
                        candidate: candidate,
                        startingAt: 2,
                        scope: scope,
                        accountID: accountID,
                        organizationID: organizationID,
                        githubOrganizationID: githubOrganizationID,
                        observedAt: observedAt,
                        ssoHeaders: &ssoHeaders,
                        budget: &budget
                    )
                    try Task.checkCancellation()
                }
            }
            saved = try await eventRepository.savedPages(
                for: candidate,
                scope: scope,
                accountID: accountID,
                organizationID: organizationID
            )
            try Task.checkCancellation()
        }

        try Task.checkCancellation()
        let normalized: [NormalizedGitHubTimelineEvent]
        do {
            normalized = try GitHubTimelineNormalizer.normalize(saved.events)
        } catch let error as GitHubTimelineNormalizationError {
            if error != .duplicateEventID {
                try await recordNormalizationFailure(
                    rawPage: saved.latestPageProvenance,
                    candidate: candidate,
                    accountID: accountID,
                    observedAt: observedAt,
                    diagnostic: Self.redactedDiagnostic(for: error)
                )
            }
            throw error
        }
        try Task.checkCancellation()
        if let scopedHeader = GitHubSSOHeader.combined(ssoHeaders)?.scoped(to: githubOrganizationID) {
            try await candidateRepository.fail(
                candidate: candidate,
                accountID: accountID,
                organizationID: organizationID,
                at: observedAt
            )
            try Task.checkCancellation()
            return .ssoRequired(scopedHeader)
        }
        let conditionalIdentity = Self.conditionalRequestIdentity(for: candidate, scope: scope)
        let conditionalMutation: ConditionalRequestCacheMutation
        let persistedValidator: ConditionalRequestValidator?
        let currentTraversalValidators: GitHubHTTPValidators?
        if let firstPageValidators {
            currentTraversalValidators = firstPageValidators
        } else if resumedFromCheckpoint {
            currentTraversalValidators = try Self.httpValidators(
                eTag: saved.firstPageETag,
                lastModified: saved.firstPageLastModified
            )
        } else {
            currentTraversalValidators = nil
        }
        if let currentTraversalValidators {
            let validator = ConditionalRequestValidator(
                identity: conditionalIdentity,
                eTag: currentTraversalValidators.eTag,
                lastModified: currentTraversalValidators.lastModified,
                observedAt: observedAt
            )
            persistedValidator = validator
            conditionalMutation = .save(validator)
        } else {
            persistedValidator = nil
            conditionalMutation = .remove(conditionalIdentity)
        }
        try Task.checkCancellation()
        try await eventRepository.replaceAndComplete(
            normalized,
            candidate: candidate,
            accountID: accountID,
            organizationID: organizationID,
            observedAt: observedAt,
            conditionalRequestCacheMutation: conditionalMutation,
            replayReceipt: persistedValidator.map {
                TimelineReplayReceiptInput(
                    validator: $0,
                    rawSourceRevision: candidate.sourceRevision,
                    pages: saved.pageProvenances
                )
            }
        )
        try Task.checkCancellation()
        return .refreshed
    }

    private func fetchRemainingPages(
        from initialURL: URL,
        candidate: TimelineCandidate,
        startingAt initialPageIndex: Int,
        scope: SynchronizationScope,
        accountID: AccountID,
        organizationID: OrganizationID,
        githubOrganizationID: UInt64,
        observedAt: Date,
        ssoHeaders: inout [GitHubSSOHeader],
        budget: inout BudgetMeter
    ) async throws {
        var nextPageURL: URL? = initialURL
        var pageIndex = initialPageIndex
        var visitedPageURLs = Set([initialURL.absoluteString])
        while let url = nextPageURL {
            guard pageIndex <= Self.maximumTimelinePages else {
                throw GitHubTimelineRefreshServiceError.paginationLimitExceeded
            }
            try Task.checkCancellation()
            guard budget.reservePage() else {
                throw ControlFlowError.budgetExhausted
            }
            let requestKey = try Self.requestKey(
                for: url,
                candidate: candidate,
                pageIndex: pageIndex
            )
            let page = try await nextPagePreservingRejectedPayload(
                url,
                candidate: candidate,
                repository: candidate.repository,
                issueOrPullRequestNumber: candidate.number,
                pageIndex: pageIndex,
                requestKey: requestKey,
                scope: scope,
                accountID: accountID,
                organizationID: organizationID,
                githubOrganizationID: githubOrganizationID,
                observedAt: observedAt,
                budget: &budget
            )
            try Task.checkCancellation()
            if let ssoHeader = page.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
            let rawSnapshotID = try await eventRepository.saveRawPage(
                page,
                candidate: candidate,
                pageIndex: pageIndex,
                requestKey: requestKey,
                scope: scope,
                accountID: accountID,
                organizationID: organizationID,
                observedAt: observedAt
            )
            try Task.checkCancellation()
            if let scopedHeader = GitHubSSOHeader.combined(ssoHeaders)?.scoped(
                to: githubOrganizationID
            ) {
                throw ControlFlowError.ssoRequired(scopedHeader)
            }
            guard budget.consumeDecodedBytes(page.payload.count) else {
                throw ControlFlowError.budgetExhausted
            }
            try await validate(
                page.values,
                rawSnapshotID: rawSnapshotID,
                candidate: candidate,
                accountID: accountID,
                observedAt: observedAt
            )
            try Task.checkCancellation()
            let followingPageURL = page.nextPageURL
            if let followingPageURL {
                guard visitedPageURLs.insert(followingPageURL.absoluteString).inserted else {
                    throw GitHubTimelineClientError.paginationLoop
                }
            }
            try await eventRepository.commitValidatedRawPage(
                rawSnapshotID,
                candidate: candidate,
                pageIndex: pageIndex,
                requestKey: requestKey,
                scope: scope,
                nextPageURL: followingPageURL,
                accountID: accountID,
                organizationID: organizationID,
                attemptedAt: observedAt
            )
            try Task.checkCancellation()
            nextPageURL = followingPageURL
            pageIndex += 1
        }
    }

    private func firstPagePreservingRejectedPayload(
        candidate: TimelineCandidate,
        repository: GitHubRepositoryPath,
        issueOrPullRequestNumber: Int,
        validators: GitHubHTTPValidators?,
        scope: SynchronizationScope,
        accountID: AccountID,
        organizationID: OrganizationID,
        githubOrganizationID: UInt64,
        observedAt: Date,
        budget: inout BudgetMeter
    ) async throws -> GitHubTimelinePageResult {
        do {
            return try await client.firstPage(
                repository: repository,
                issueOrPullRequestNumber: issueOrPullRequestNumber,
                validators: validators
            )
        } catch let error as GitHubTimelineUndecodablePageError {
            try await preserveRejectedPayload(
                error.page,
                candidate: candidate,
                pageIndex: 1,
                requestKey: Self.requestKey(for: candidate),
                scope: scope,
                accountID: accountID,
                organizationID: organizationID,
                githubOrganizationID: githubOrganizationID,
                observedAt: observedAt,
                budget: &budget
            )
            throw GitHubRESTClientError.invalidJSON
        }
    }

    private func nextPagePreservingRejectedPayload(
        _ url: URL,
        candidate: TimelineCandidate,
        repository: GitHubRepositoryPath,
        issueOrPullRequestNumber: Int,
        pageIndex: Int,
        requestKey: String,
        scope: SynchronizationScope,
        accountID: AccountID,
        organizationID: OrganizationID,
        githubOrganizationID: UInt64,
        observedAt: Date,
        budget: inout BudgetMeter
    ) async throws -> GitHubPage<GitHubTimelineEventDTO> {
        do {
            return try await client.nextPage(
                url,
                repository: repository,
                issueOrPullRequestNumber: issueOrPullRequestNumber
            )
        } catch let error as GitHubTimelineUndecodablePageError {
            try await preserveRejectedPayload(
                error.page,
                candidate: candidate,
                pageIndex: pageIndex,
                requestKey: requestKey,
                scope: scope,
                accountID: accountID,
                organizationID: organizationID,
                githubOrganizationID: githubOrganizationID,
                observedAt: observedAt,
                budget: &budget
            )
            throw GitHubRESTClientError.invalidJSON
        }
    }

    private func preserveRejectedPayload(
        _ page: GitHubUndecodablePage,
        candidate: TimelineCandidate,
        pageIndex: Int,
        requestKey: String,
        scope: SynchronizationScope,
        accountID: AccountID,
        organizationID: OrganizationID,
        githubOrganizationID: UInt64,
        observedAt: Date,
        budget: inout BudgetMeter
    ) async throws {
        try Task.checkCancellation()
        _ = budget.consumeDecodedBytes(page.payload.count)
        _ = try await eventRepository.saveRejectedRawPage(
            page,
            candidate: candidate,
            pageIndex: pageIndex,
            requestKey: requestKey,
            scope: scope,
            accountID: accountID,
            organizationID: organizationID,
            observedAt: observedAt,
            redactedDiagnostic: "GitHub returned a timeline page that could not be decoded."
        )
        try Task.checkCancellation()
        if let scopedHeader = page.ssoHeader?.scoped(to: githubOrganizationID) {
            throw ControlFlowError.ssoRequired(scopedHeader)
        }
    }

    private func markIncomplete(
        _: some Error,
        candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        at: Date
    ) async throws {
        try await candidateRepository.fail(
            candidate: candidate,
            accountID: accountID,
            organizationID: organizationID,
            at: at
        )
    }

    private nonisolated func outcome(
        for candidate: TimelineCandidate,
        status: GitHubTimelineRefreshOutcomeStatus
    ) -> GitHubTimelineRefreshOutcome {
        GitHubTimelineRefreshOutcome(
            nodeID: candidate.nodeID,
            repositoryID: candidate.repositoryID,
            number: candidate.number,
            status: status
        )
    }

    nonisolated static func status(
        for error: Error,
        githubOrganizationID: UInt64,
        observedAt: Date
    ) -> GitHubTimelineRefreshOutcomeStatus {
        guard let failure = error as? GitHubFailure else {
            return .failed
        }
        if let header = failure.ssoHeader?.scoped(to: githubOrganizationID) {
            return .ssoRequired(header)
        }
        if let restriction = failure.accessRestriction {
            switch restriction {
            case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
                return .approvalRequired
            case .organizationPolicyBlocked:
                return .unavailableOrPermission
            }
        }
        switch failure.kind {
        case .unauthorized:
            return .authenticationRequired
        case .rateLimited, .secondaryRateLimited:
            return .rateLimited(retryAt: failure.retryAfter.map { observedAt.addingTimeInterval($0) })
        case .forbidden, .notFound:
            return .unavailableOrPermission
        case .serverFailure, .unexpectedResponse:
            return .failed
        }
    }

    private func validate(
        _ events: [GitHubTimelineEventDTO],
        rawSnapshotID: RawAPISnapshotID,
        candidate: TimelineCandidate,
        accountID: AccountID,
        observedAt: Date
    ) async throws {
        do {
            _ = try GitHubTimelineNormalizer.normalize(events)
        } catch let error as GitHubTimelineNormalizationError {
            try await recordNormalizationFailure(
                rawPage: TimelineRawPageProvenance(
                    snapshotID: rawSnapshotID,
                    endpoint: Self.timelineEndpoint(for: candidate),
                    parserVersion: 1
                ),
                candidate: candidate,
                accountID: accountID,
                observedAt: observedAt,
                diagnostic: Self.redactedDiagnostic(for: error)
            )
            throw error
        }
    }

    private func recordNormalizationFailure(
        rawPage: TimelineRawPageProvenance,
        candidate: TimelineCandidate,
        accountID: AccountID,
        observedAt: Date,
        diagnostic: String
    ) async throws {
        try Task.checkCancellation()
        try await normalizationFailureRepository.record(
            NormalizationFailure(
                id: UUID(),
                accountID: accountID,
                rawSnapshotID: rawPage.snapshotID,
                githubNodeID: candidate.nodeID,
                endpoint: rawPage.endpoint,
                parserVersion: rawPage.parserVersion,
                occurredAt: observedAt,
                redactedDiagnostic: diagnostic
            )
        )
        try Task.checkCancellation()
    }

    private nonisolated static func timelineEndpoint(for candidate: TimelineCandidate) -> String {
        "GET \(candidate.repository.path)/issues/\(candidate.number)/timeline"
    }

    private nonisolated static func redactedDiagnostic(
        for error: GitHubTimelineNormalizationError
    ) -> String {
        switch error {
        case .invalidEventID:
            "Timeline page contains an invalid GitHub event identifier."
        case .invalidEventName:
            "Timeline page contains an invalid event name."
        case .invalidEventDate:
            "Timeline page contains an invalid event timestamp."
        case .invalidEventPayload:
            "Timeline page contains an invalid event payload shape."
        case .eventPayloadTooLarge:
            "Timeline page contains an event payload exceeding the supported limit."
        case .duplicateEventID:
            "Timeline page contains duplicate GitHub event identifiers."
        }
    }

    private nonisolated static func requestKey(for candidate: TimelineCandidate) -> String {
        "GET \(candidate.repository.path)/issues/\(candidate.number)/timeline?per_page=100&page=1"
    }

    private nonisolated static func requestKey(
        for url: URL,
        candidate: TimelineCandidate,
        pageIndex: Int
    ) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host?.caseInsensitiveCompare("api.github.com") == .orderedSame,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.path == "\(candidate.repository.path)/issues/\(candidate.number)/timeline",
              let query = components.percentEncodedQuery,
              !query.isEmpty,
              let page = components.queryItems?.first(where: { $0.name == "page" })?.value.flatMap(Int.init),
              page == pageIndex
        else {
            throw GitHubTimelineClientError.invalidPaginationLink
        }
        return "GET \(components.percentEncodedPath)?\(query)"
    }

    private nonisolated static func conditionalRequestIdentity(
        for candidate: TimelineCandidate,
        scope: SynchronizationScope
    ) -> ConditionalRequestIdentity {
        ConditionalRequestIdentity(
            scope: scope,
            feature: .timelines,
            streamID: SyncStreamID(rawValue: "timeline:\(candidate.nodeID.rawValue)")!,
            requestKey: requestKey(for: candidate)
        )
    }

    private nonisolated static func httpValidators(
        eTag: String?,
        lastModified: String?
    ) throws -> GitHubHTTPValidators? {
        guard eTag != nil || lastModified != nil else { return nil }
        return try GitHubHTTPValidators(eTag: eTag, lastModified: lastModified)
    }
}
