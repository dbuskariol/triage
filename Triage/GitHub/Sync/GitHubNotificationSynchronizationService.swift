import Foundation

/// The durable boundary for account notifications. Implementations must retain
/// immutable raw pages and validate a receipt before returning `true` for a
/// conditional 304; notifications are discovery evidence only.
protocol GitHubNotificationSourcePersisting: Sendable {
    func validator(for identity: ConditionalRequestIdentity) async throws -> ConditionalRequestValidator?
    func hasValidatedUnchangedReceipt(
        for validator: ConditionalRequestValidator,
        observedAt: Date
    ) async throws -> Bool
    func persist(
        _ inventory: GitHubNotificationInventory,
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        organizationLogin: String,
        coverage: CoverageRecord,
        observedAt: Date
    ) async throws
    func recordFailure(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        organizationLogin: String,
        pages: [GitHubNotificationPage],
        classification: GitHubNotificationFailureClassification,
        coverage: CoverageRecord,
        observedAt: Date
    ) async throws
}

enum GitHubNotificationFailureClassification: Equatable, Sendable {
    case ssoRequired
    case approvalRequired
    case authenticationRequired
    case rateLimited(retryAt: Date?)
    case unavailableOrPermission
    case integrity
    case transient
}

enum GitHubNotificationRefreshStatus: Equatable, Sendable {
    case refreshed
    case unchanged
    case ssoRequired(GitHubSSOHeader)
    case approvalRequired
    case authenticationRequired
    case rateLimited(retryAt: Date?)
    case unavailableOrPermission
    case failed
}

struct GitHubNotificationRefreshResult: Equatable, Sendable {
    let status: GitHubNotificationRefreshStatus
    let coverage: CoverageRecord
    let notificationCount: Int
    let usedUnconditionalRecovery: Bool
}

actor GitHubNotificationSynchronizationService {
    private let client: GitHubNotificationClient
    private let repository: any GitHubNotificationSourcePersisting

    init(client: GitHubNotificationClient, repository: any GitHubNotificationSourcePersisting) {
        self.client = client
        self.repository = repository
    }

    /// Performs one bounded account-feed reconciliation for the selected
    /// organization. It has no fallback source and does not change GitHub
    /// notification read state.
    func refresh(
        scope: SynchronizationScope,
        organizationLogin: String,
        streamID: SyncStreamID,
        previousHighWater: Date?,
        observedAt: Date = .now
    ) async throws -> GitHubNotificationRefreshResult {
        let identity = ConditionalRequestIdentity(
            scope: scope,
            feature: .notifications,
            streamID: streamID,
            requestKey: GitHubNotificationClient.firstPageRequestKey
        )
        let intervalStart = previousHighWater ?? Date(timeIntervalSince1970: 0)
        do {
            try Task.checkCancellation()
            let cachedValidator = try await repository.validator(for: identity)
            guard cachedValidator == nil || cachedValidator?.identity == identity else {
                throw GitHubNotificationSynchronizationError.invalidConditionalAuthority
            }
            let validators = try cachedValidator.map(Self.httpValidators)
            var usedUnconditionalRecovery = false
            var fetched = try await client.fetchNotifications(validators: validators)
            if case .notModified = fetched {
                guard let cachedValidator,
                      try await repository.hasValidatedUnchangedReceipt(
                        for: cachedValidator,
                        observedAt: observedAt
                      )
                else {
                    // A 304 without exact, current, normalized authority is
                    // never an empty success. One explicit same-endpoint retry
                    // is permitted; there is no cross-source fallback.
                    usedUnconditionalRecovery = true
                    fetched = try await client.fetchNotifications(validators: nil)
                    if case .notModified = fetched {
                        throw GitHubNotificationSynchronizationError.unconditionalNotModified
                    }
                    return try await persistModified(
                        fetched,
                        scope: scope,
                        organizationLogin: organizationLogin,
                        streamID: streamID,
                        intervalStart: intervalStart,
                        observedAt: observedAt,
                        usedUnconditionalRecovery: usedUnconditionalRecovery
                    )
                }
                let coverage = coverage(
                    scope: scope,
                    streamID: streamID,
                    intervalStart: intervalStart,
                    observedAt: observedAt,
                    status: .complete,
                    failureDetail: nil,
                    successfulAt: observedAt
                )
                return .init(
                    status: .unchanged,
                    coverage: coverage,
                    notificationCount: 0,
                    usedUnconditionalRecovery: false
                )
            }
            return try await persistModified(
                fetched,
                scope: scope,
                organizationLogin: organizationLogin,
                streamID: streamID,
                intervalStart: intervalStart,
                observedAt: observedAt,
                usedUnconditionalRecovery: usedUnconditionalRecovery
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let classification = Self.classification(for: error, observedAt: observedAt)
            let failureCoverage = coverage(
                scope: scope,
                streamID: streamID,
                intervalStart: intervalStart,
                observedAt: observedAt,
                status: Self.coverageStatus(for: classification),
                failureDetail: Self.diagnostic(for: classification),
                successfulAt: nil
            )
            try await repository.recordFailure(
                scope: scope,
                streamID: streamID,
                organizationLogin: organizationLogin,
                pages: [],
                classification: classification,
                coverage: failureCoverage,
                observedAt: observedAt
            )
            return .init(
                status: Self.status(for: classification, sourceError: error),
                coverage: failureCoverage,
                notificationCount: 0,
                usedUnconditionalRecovery: false
            )
        }
    }

    private func persistModified(
        _ result: GitHubNotificationFetch,
        scope: SynchronizationScope,
        organizationLogin: String,
        streamID: SyncStreamID,
        intervalStart: Date,
        observedAt: Date,
        usedUnconditionalRecovery: Bool
    ) async throws -> GitHubNotificationRefreshResult {
        guard case let .modified(inventory) = result else {
            throw GitHubNotificationSynchronizationError.unconditionalNotModified
        }
        let selectedOrganizationSSO = inventory.ssoHeader
        if let selectedOrganizationSSO {
            throw GitHubNotificationSynchronizationError.ssoRequirement(selectedOrganizationSSO)
        }
        let coverage = coverage(
            scope: scope,
            streamID: streamID,
            intervalStart: intervalStart,
            observedAt: observedAt,
            status: .complete,
            failureDetail: nil,
            successfulAt: observedAt
        )
        try await repository.persist(
            inventory,
            scope: scope,
            streamID: streamID,
            organizationLogin: organizationLogin,
            coverage: coverage,
            observedAt: observedAt
        )
        let organizationNotifications = inventory.notifications.filter {
            $0.repository.owner.login.caseInsensitiveCompare(organizationLogin) == .orderedSame
        }
        return .init(
            status: .refreshed,
            coverage: coverage,
            notificationCount: organizationNotifications.count,
            usedUnconditionalRecovery: usedUnconditionalRecovery
        )
    }

    private func coverage(
        scope: SynchronizationScope,
        streamID: SyncStreamID,
        intervalStart: Date,
        observedAt: Date,
        status: CoverageStatus,
        failureDetail: String?,
        successfulAt: Date?
    ) -> CoverageRecord {
        .init(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: nil,
            feature: .notifications,
            streamID: streamID,
            intervalStart: intervalStart,
            intervalEnd: observedAt,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: status,
            lastSuccessfulAt: successfulAt,
            failureDetail: failureDetail
        )
    }

    private nonisolated static func httpValidators(
        _ validator: ConditionalRequestValidator
    ) throws -> GitHubHTTPValidators {
        try .init(eTag: validator.eTag, lastModified: validator.lastModified)
    }

    private nonisolated static func classification(
        for error: Error,
        observedAt: Date
    ) -> GitHubNotificationFailureClassification {
        if let error = error as? GitHubNotificationSynchronizationError {
            switch error {
            case .ssoRequirement:
                return .ssoRequired
            case .invalidConditionalAuthority, .unconditionalNotModified:
                return .integrity
            }
        }
        guard let failure = error as? GitHubFailure else {
            return error is GitHubNotificationClientError || error is GitHubRESTClientError
                ? .integrity
                : .transient
        }
        if failure.ssoHeader != nil { return .ssoRequired }
        if failure.accessRestriction != nil { return .approvalRequired }
        switch failure.kind {
        case .unauthorized:
            return .authenticationRequired
        case .rateLimited, .secondaryRateLimited:
            return .rateLimited(retryAt: failure.retryAfter.map { observedAt.addingTimeInterval($0) })
        case .forbidden, .notFound:
            return .unavailableOrPermission
        case .serverFailure, .unexpectedResponse:
            return .transient
        }
    }

    private nonisolated static func coverageStatus(
        for classification: GitHubNotificationFailureClassification
    ) -> CoverageStatus {
        switch classification {
        case .ssoRequired:
            return .requiresSSO
        case .approvalRequired:
            return .requiresApproval
        case .authenticationRequired, .integrity, .transient:
            return .failed
        case .rateLimited:
            return .partial
        case .unavailableOrPermission:
            return .unavailable
        }
    }

    private nonisolated static func diagnostic(
        for classification: GitHubNotificationFailureClassification
    ) -> String {
        switch classification {
        case .ssoRequired:
            return "GitHub SSO authorization is required before notifications can refresh."
        case .approvalRequired:
            return "GitHub organization approval is required before notifications can refresh."
        case .authenticationRequired:
            return "GitHub authentication is required before notifications can refresh."
        case .rateLimited:
            return "GitHub rate limiting left notification discovery incomplete."
        case .unavailableOrPermission:
            return "GitHub notifications are unavailable to the selected account."
        case .integrity:
            return "GitHub notification source data could not be validated."
        case .transient:
            return "GitHub notifications could not be refreshed."
        }
    }

    private nonisolated static func status(
        for classification: GitHubNotificationFailureClassification,
        sourceError: Error
    ) -> GitHubNotificationRefreshStatus {
        switch classification {
        case .ssoRequired:
            if let error = sourceError as? GitHubNotificationSynchronizationError,
               case let .ssoRequirement(header) = error {
                return .ssoRequired(header)
            }
            if let failure = sourceError as? GitHubFailure,
               let header = failure.ssoHeader {
                return .ssoRequired(header)
            }
            return .failed
        case .approvalRequired:
            return .approvalRequired
        case .authenticationRequired:
            return .authenticationRequired
        case let .rateLimited(retryAt):
            return .rateLimited(retryAt: retryAt)
        case .unavailableOrPermission:
            return .unavailableOrPermission
        case .integrity, .transient:
            return .failed
        }
    }
}

enum GitHubNotificationSynchronizationError: Error, Equatable, Sendable {
    case invalidConditionalAuthority
    case unconditionalNotModified
    case ssoRequirement(GitHubSSOHeader)
}
