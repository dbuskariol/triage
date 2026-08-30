import Foundation

enum GitHubTimelineRefreshServiceError: Error, Equatable, Sendable {
    case invalidLimit
    case paginationLimitExceeded
}

struct GitHubTimelineRefreshResult: Sendable {
    let refreshedTimelineNodeIDs: [GitHubNodeID]
    let incompleteTimelineNodeIDs: [GitHubNodeID]
    let hasRemainingCandidates: Bool
    let hasContinuation: Bool
    let ssoHeaders: [GitHubSSOHeader]

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }
}

actor GitHubTimelineRefreshService {
    private static let maximumTimelinePages = 100

    private let client: GitHubTimelineClient
    private let candidateRepository: TimelineCandidateRepository
    private let eventRepository: TimelineEventRepository
    private let conditionalRequestCacheRepository: ConditionalRequestCacheRepository

    init(
        client: GitHubTimelineClient,
        candidateRepository: TimelineCandidateRepository,
        eventRepository: TimelineEventRepository,
        conditionalRequestCacheRepository: ConditionalRequestCacheRepository
    ) {
        self.client = client
        self.candidateRepository = candidateRepository
        self.eventRepository = eventRepository
        self.conditionalRequestCacheRepository = conditionalRequestCacheRepository
    }

    func refresh(
        accountID: AccountID,
        organizationID: OrganizationID,
        currentUserID: ActorID,
        candidates requestedCandidates: [TimelineCandidate]? = nil,
        limit: Int = 50,
        observedAt: Date = .now
    ) async throws -> GitHubTimelineRefreshResult {
        guard limit > 0, limit < .max else {
            throw GitHubTimelineRefreshServiceError.invalidLimit
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

        var refreshedTimelineNodeIDs = [GitHubNodeID]()
        var incompleteTimelineNodeIDs = [GitHubNodeID]()
        var ssoHeaders = [GitHubSSOHeader]()

        for candidate in inventory.candidates {
            try Task.checkCancellation()
            do {
                let result = try await refresh(
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    observedAt: observedAt
                )
                refreshedTimelineNodeIDs.append(candidate.nodeID)
                ssoHeaders.append(contentsOf: result)
            } catch let failure as GitHubFailure {
                try await candidateRepository.fail(
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                incompleteTimelineNodeIDs.append(candidate.nodeID)
                if let ssoHeader = failure.ssoHeader {
                    ssoHeaders.append(ssoHeader)
                }
            } catch let error as GitHubTimelineClientError {
                try await markIncomplete(
                    error,
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                incompleteTimelineNodeIDs.append(candidate.nodeID)
            } catch let error as GitHubTimelineRefreshServiceError {
                try await markIncomplete(
                    error,
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                incompleteTimelineNodeIDs.append(candidate.nodeID)
            } catch let error as GitHubRESTClientError {
                try await markIncomplete(
                    error,
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                incompleteTimelineNodeIDs.append(candidate.nodeID)
            } catch let error as GitHubTransportError {
                try await markIncomplete(
                    error,
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                incompleteTimelineNodeIDs.append(candidate.nodeID)
            } catch let error as GitHubTimelineNormalizationError {
                try await markIncomplete(
                    error,
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                incompleteTimelineNodeIDs.append(candidate.nodeID)
            } catch let error as TimelineEventRepositoryError {
                switch error {
                case .accountScopeMismatch, .candidateScopeMismatch:
                    throw error
                case .invalidRawPage, .invalidPersistedPage, .invalidEventPayload,
                        .duplicateEventID, .eventBelongsToAnotherSubject:
                    try await markIncomplete(
                        error,
                        candidate: candidate,
                        accountID: accountID,
                        organizationID: organizationID,
                        at: observedAt
                    )
                    incompleteTimelineNodeIDs.append(candidate.nodeID)
                }
            }
        }

        return GitHubTimelineRefreshResult(
            refreshedTimelineNodeIDs: refreshedTimelineNodeIDs,
            incompleteTimelineNodeIDs: incompleteTimelineNodeIDs,
            hasRemainingCandidates: inventory.hasRemainingCandidates,
            hasContinuation: inventory.hasRemainingCandidates || !incompleteTimelineNodeIDs.isEmpty,
            ssoHeaders: ssoHeaders
        )
    }

    private func refresh(
        candidate: TimelineCandidate,
        accountID: AccountID,
        organizationID: OrganizationID,
        observedAt: Date
    ) async throws -> [GitHubSSOHeader] {
        var ssoHeaders = [GitHubSSOHeader]()
        var firstPageETag: String?
        let saved: TimelineSavedPageInventory
        if let checkpoint = try await candidateRepository.checkpoint(
            for: candidate,
            accountID: accountID,
            organizationID: organizationID
        ) {
            try Task.checkCancellation()
            if let nextPageURL = checkpoint.nextPageURL {
                let resumedPages = try await eventRepository.savedPages(
                    for: candidate,
                    accountID: accountID,
                    organizationID: organizationID
                )
                try Task.checkCancellation()
                try await fetchRemainingPages(
                    from: nextPageURL,
                    candidate: candidate,
                    startingAt: resumedPages.pageCount + 1,
                    accountID: accountID,
                    organizationID: organizationID,
                    observedAt: observedAt,
                    ssoHeaders: &ssoHeaders
                )
                try Task.checkCancellation()
            } else {
                guard checkpoint.isDownloadComplete else {
                    throw TimelineCandidateRepositoryError.invalidCheckpoint
                }
            }
            saved = try await eventRepository.savedPages(
                for: candidate,
                accountID: accountID,
                organizationID: organizationID
            )
            try Task.checkCancellation()
        } else {
            let requestKey = Self.requestKey(for: candidate)
            let validator = try await conditionalRequestCacheRepository.validator(
                for: requestKey,
                accountID: accountID
            )
            try Task.checkCancellation()
            let firstPageResult = try await client.firstPage(
                repository: candidate.repository,
                issueOrPullRequestNumber: candidate.number,
                ifNoneMatch: validator?.eTag
            )
            try Task.checkCancellation()
            switch firstPageResult {
            case let .notModified(ssoHeader):
                if let ssoHeader {
                    ssoHeaders.append(ssoHeader)
                }
                try await candidateRepository.complete(
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                try Task.checkCancellation()
                return ssoHeaders
            case let .page(firstPage):
                firstPageETag = firstPage.etag
                if let ssoHeader = firstPage.ssoHeader {
                    ssoHeaders.append(ssoHeader)
                }
                _ = try GitHubTimelineNormalizer.normalize(firstPage.values)
                try Task.checkCancellation()
                try await eventRepository.saveRawPage(
                    firstPage,
                    candidate: candidate,
                    pageIndex: 1,
                    accountID: accountID,
                    organizationID: organizationID,
                    observedAt: observedAt
                )
                try Task.checkCancellation()
                if let nextPageURL = firstPage.nextPageURL {
                    try await candidateRepository.saveCheckpoint(
                        for: candidate,
                        nextPageURL: nextPageURL,
                        accountID: accountID,
                        organizationID: organizationID
                    )
                    try Task.checkCancellation()
                    try await fetchRemainingPages(
                        from: nextPageURL,
                        candidate: candidate,
                        startingAt: 2,
                        accountID: accountID,
                        organizationID: organizationID,
                        observedAt: observedAt,
                        ssoHeaders: &ssoHeaders
                    )
                    try Task.checkCancellation()
                } else {
                    try await candidateRepository.markDownloadComplete(
                        candidate: candidate,
                        accountID: accountID,
                        organizationID: organizationID,
                        at: observedAt
                    )
                    try Task.checkCancellation()
                }
            }
            saved = try await eventRepository.savedPages(
                for: candidate,
                accountID: accountID,
                organizationID: organizationID
            )
            try Task.checkCancellation()
        }

        try Task.checkCancellation()
        let normalized = try GitHubTimelineNormalizer.normalize(saved.events)
        try Task.checkCancellation()
        try await eventRepository.replace(
            normalized,
            candidate: candidate,
            accountID: accountID,
            organizationID: organizationID,
            observedAt: observedAt
        )
        try Task.checkCancellation()
        if let eTag = firstPageETag ?? saved.firstPageETag {
            try await conditionalRequestCacheRepository.save(
                ConditionalRequestValidator(
                    requestKey: Self.requestKey(for: candidate),
                    accountID: accountID,
                    eTag: eTag,
                    lastModified: nil,
                    observedAt: observedAt
                )
            )
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        try await candidateRepository.complete(
            candidate: candidate,
            accountID: accountID,
            organizationID: organizationID,
            at: observedAt
        )
        try Task.checkCancellation()
        return ssoHeaders
    }

    private func fetchRemainingPages(
        from initialURL: URL,
        candidate: TimelineCandidate,
        startingAt initialPageIndex: Int,
        accountID: AccountID,
        organizationID: OrganizationID,
        observedAt: Date,
        ssoHeaders: inout [GitHubSSOHeader]
    ) async throws {
        var nextPageURL: URL? = initialURL
        var pageIndex = initialPageIndex
        var visitedPageURLs = Set([initialURL.absoluteString])
        while let url = nextPageURL {
            guard pageIndex <= Self.maximumTimelinePages else {
                throw GitHubTimelineRefreshServiceError.paginationLimitExceeded
            }
            try Task.checkCancellation()
            let page = try await client.nextPage(
                url,
                repository: candidate.repository,
                issueOrPullRequestNumber: candidate.number
            )
            try Task.checkCancellation()
            if let ssoHeader = page.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
            _ = try GitHubTimelineNormalizer.normalize(page.values)
            try Task.checkCancellation()
            try await eventRepository.saveRawPage(
                page,
                candidate: candidate,
                pageIndex: pageIndex,
                accountID: accountID,
                organizationID: organizationID,
                observedAt: observedAt
            )
            try Task.checkCancellation()
            nextPageURL = page.nextPageURL
            if let nextPageURL {
                guard visitedPageURLs.insert(nextPageURL.absoluteString).inserted else {
                    throw GitHubTimelineClientError.paginationLoop
                }
                try await candidateRepository.saveCheckpoint(
                    for: candidate,
                    nextPageURL: nextPageURL,
                    accountID: accountID,
                    organizationID: organizationID
                )
                try Task.checkCancellation()
            } else {
                try await candidateRepository.markDownloadComplete(
                    candidate: candidate,
                    accountID: accountID,
                    organizationID: organizationID,
                    at: observedAt
                )
                try Task.checkCancellation()
            }
            pageIndex += 1
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

    private nonisolated static func requestKey(for candidate: TimelineCandidate) -> String {
        "GET \(candidate.repository.path)/issues/\(candidate.number)/timeline?per_page=100&page=1"
    }
}
