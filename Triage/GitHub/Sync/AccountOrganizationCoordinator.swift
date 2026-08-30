import Foundation

struct AccountOrganizationScope: Hashable, Sendable {
    let accountID: AccountID
    let organizationID: OrganizationID

    init(accountID: AccountID, organizationID: OrganizationID) {
        self.accountID = accountID
        self.organizationID = organizationID
    }
}

struct AccountOrganizationRequestToken: Hashable, Sendable {
    let rawValue: UInt64
}

enum AccountOrganizationRefreshPriority: Sendable {
    case selectedOrganization
    case manual
    case activeApplication
    case inactiveAccount
    case fullReconciliation

    var taskPriority: TaskPriority {
        switch self {
        case .selectedOrganization, .manual:
            .userInitiated
        case .activeApplication:
            .utility
        case .inactiveAccount, .fullReconciliation:
            .background
        }
    }

    var requestPriority: GitHubRequestPriority {
        switch self {
        case .selectedOrganization, .manual:
            .selectedOrganizationRefresh
        case .activeApplication:
            .incrementalDiscovery
        case .inactiveAccount:
            .inactiveAccountRefresh
        case .fullReconciliation:
            .fullReconciliation
        }
    }
}

struct AccountOrganizationRefreshRequest: Sendable {
    let scope: AccountOrganizationScope
    let token: AccountOrganizationRequestToken
    let priority: AccountOrganizationRefreshPriority
    let requestPriority: GitHubRequestPriority
}

struct AccountOrganizationCachedState: Codable, Equatable, Sendable {
    let coverage: [CoverageRecord]
    let lastSuccessfulSyncAt: Date?

    init(coverage: [CoverageRecord], lastSuccessfulSyncAt: Date?) {
        self.coverage = coverage
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    }

    var freshness: FreshnessState {
        let latestSuccess = coverage.compactMap(\.lastSuccessfulAt).max() ?? lastSuccessfulSyncAt
        guard !coverage.isEmpty else {
            return FreshnessState(
                status: .stale,
                lastSuccessfulSyncAt: latestSuccess,
                detail: "No cached synchronization coverage is available."
            )
        }
        if let record = coverage.first(where: { $0.status == .requiresSSO }) {
            return FreshnessState(
                status: .ssoRequired,
                lastSuccessfulSyncAt: latestSuccess,
                detail: record.failureDetail
            )
        }
        if let record = coverage.first(where: { $0.status == .requiresApproval }) {
            return FreshnessState(
                status: .approvalRequired,
                lastSuccessfulSyncAt: latestSuccess,
                detail: record.failureDetail
            )
        }
        if let record = coverage.first(where: { $0.status == .failed }) {
            return FreshnessState(
                status: .failed,
                lastSuccessfulSyncAt: latestSuccess,
                detail: record.failureDetail
            )
        }
        if let record = coverage.first(where: {
            $0.status == .partial || $0.status == .unavailable
        }) {
            return FreshnessState(
                status: .partial,
                lastSuccessfulSyncAt: latestSuccess,
                detail: record.failureDetail
            )
        }
        if coverage.contains(where: { $0.status == .unknown }) {
            return FreshnessState(
                status: .stale,
                lastSuccessfulSyncAt: latestSuccess,
                detail: "Synchronization coverage is not yet known."
            )
        }
        return FreshnessState(status: .fresh, lastSuccessfulSyncAt: latestSuccess)
    }
}

struct AccountOrganizationDurableState: Codable, Equatable, Sendable {
    let cachedState: AccountOrganizationCachedState?
    let freshness: FreshnessState

    init(
        cachedState: AccountOrganizationCachedState?,
        freshness: FreshnessState? = nil
    ) {
        self.cachedState = cachedState
        self.freshness = freshness ?? cachedState?.freshness ?? FreshnessState(
            status: .stale,
            detail: "No successful synchronization has been recorded."
        )
    }
}

protocol AccountOrganizationCachedStateStoring: Sendable {
    func loadState(for scope: AccountOrganizationScope) async throws -> AccountOrganizationDurableState?
    func saveState(
        _ state: AccountOrganizationDurableState,
        for scope: AccountOrganizationScope
    ) async throws
}

protocol AccountOrganizationRefreshOperating: Sendable {
    func refresh(_ request: AccountOrganizationRefreshRequest) async throws -> AccountOrganizationCachedState
}

enum AccountOrganizationRefreshFailure: Error, Equatable, Sendable {
    case offline(detail: String?)
    case authenticationRequired(detail: String?)
    case ssoRequired(detail: String?)
    case approvalRequired(detail: String?)
    case unavailable(detail: String?)
    case failed(detail: String?)

    var freshness: FreshnessState {
        switch self {
        case let .offline(detail):
            FreshnessState(status: .offline, detail: detail)
        case let .authenticationRequired(detail):
            FreshnessState(status: .authenticationRequired, detail: detail)
        case let .ssoRequired(detail):
            FreshnessState(status: .ssoRequired, detail: detail)
        case let .approvalRequired(detail):
            FreshnessState(status: .approvalRequired, detail: detail)
        case let .unavailable(detail):
            FreshnessState(status: .partial, detail: detail)
        case let .failed(detail):
            FreshnessState(status: .failed, detail: detail)
        }
    }
}

enum AccountOrganizationLoadPhase: Equatable, Sendable {
    case idle
    case activatingCached
    case refreshing
}

struct AccountOrganizationCoordinatorState: Equatable, Sendable {
    let scope: AccountOrganizationScope
    let phase: AccountOrganizationLoadPhase
    let durableState: AccountOrganizationDurableState

    var freshness: FreshnessState {
        guard phase == .refreshing else {
            return durableState.freshness
        }
        return FreshnessState(
            status: .refreshing,
            lastSuccessfulSyncAt: durableState.freshness.lastSuccessfulSyncAt,
            nextRetryAt: durableState.freshness.nextRetryAt,
            detail: durableState.freshness.detail
        )
    }
}

actor AccountOrganizationCoordinator {
    typealias CachedStateActivation = @Sendable (
        AccountOrganizationScope,
        AccountOrganizationDurableState
    ) async -> Void

    private let stateStore: any AccountOrganizationCachedStateStoring
    private let refreshOperation: any AccountOrganizationRefreshOperating
    private let activateCachedState: CachedStateActivation
    private var selectedScopeStorage: AccountOrganizationScope?
    private var states: [AccountOrganizationScope: AccountOrganizationCoordinatorState] = [:]
    private var tasks: [AccountOrganizationScope: Task<Void, Never>] = [:]
    private var generations: [AccountOrganizationScope: UInt64] = [:]

    init(
        stateStore: any AccountOrganizationCachedStateStoring,
        refreshOperation: any AccountOrganizationRefreshOperating,
        activateCachedState: @escaping CachedStateActivation = { _, _ in }
    ) {
        self.stateStore = stateStore
        self.refreshOperation = refreshOperation
        self.activateCachedState = activateCachedState
    }

    func selectedScope() -> AccountOrganizationScope? {
        selectedScopeStorage
    }

    func state(for scope: AccountOrganizationScope) -> AccountOrganizationCoordinatorState? {
        states[scope]
    }

    func select(_ scope: AccountOrganizationScope) async throws {
        if let previouslySelected = selectedScopeStorage, previouslySelected != scope {
            cancelRefresh(for: previouslySelected)
        }
        selectedScopeStorage = scope

        cancelTask(for: scope)
        let token = nextToken(for: scope)
        let durableState = try await stateStore.loadState(for: scope) ?? AccountOrganizationDurableState(cachedState: nil)
        guard selectedScopeStorage == scope, isCurrent(token, for: scope) else { return }

        states[scope] = AccountOrganizationCoordinatorState(
            scope: scope,
            phase: .activatingCached,
            durableState: durableState
        )
        await activateCachedState(scope, durableState)
        guard selectedScopeStorage == scope, isCurrent(token, for: scope) else { return }
        startRefresh(
            for: scope,
            token: token,
            priority: .selectedOrganization,
            durableState: durableState
        )
    }

    func refreshSelected() async throws {
        guard let scope = selectedScopeStorage else { return }
        try await refresh(scope, priority: .manual)
    }

    func refresh(
        _ scope: AccountOrganizationScope,
        priority: AccountOrganizationRefreshPriority
    ) async throws {
        cancelTask(for: scope)
        let token = nextToken(for: scope)
        let durableState: AccountOrganizationDurableState
        if let existingState = states[scope] {
            durableState = existingState.durableState
        } else {
            durableState = try await stateStore.loadState(for: scope)
                ?? AccountOrganizationDurableState(cachedState: nil)
        }
        guard isCurrent(token, for: scope) else { return }
        startRefresh(for: scope, token: token, priority: priority, durableState: durableState)
    }

    func cancelRefresh(for scope: AccountOrganizationScope) {
        cancelTask(for: scope)
        _ = nextToken(for: scope)
        if let state = states[scope] {
            states[scope] = AccountOrganizationCoordinatorState(
                scope: scope,
                phase: .idle,
                durableState: state.durableState
            )
        }
    }

    private func startRefresh(
        for scope: AccountOrganizationScope,
        token: AccountOrganizationRequestToken,
        priority: AccountOrganizationRefreshPriority,
        durableState: AccountOrganizationDurableState
    ) {
        cancelTask(for: scope)
        states[scope] = AccountOrganizationCoordinatorState(
            scope: scope,
            phase: .refreshing,
            durableState: durableState
        )
        let operation = refreshOperation
        tasks[scope] = Task(priority: priority.taskPriority) {
            let request = AccountOrganizationRefreshRequest(
                scope: scope,
                token: token,
                priority: priority,
                requestPriority: priority.requestPriority
            )
            do {
                let cachedState = try await operation.refresh(request)
                await self.complete(
                    cachedState: cachedState,
                    for: scope,
                    token: token
                )
            } catch is CancellationError {
                self.cancelled(scope: scope, token: token)
            } catch {
                await self.failed(error, for: scope, token: token)
            }
        }
    }

    private func complete(
        cachedState: AccountOrganizationCachedState,
        for scope: AccountOrganizationScope,
        token: AccountOrganizationRequestToken
    ) async {
        guard isCurrent(token, for: scope) else { return }
        let durableState = AccountOrganizationDurableState(cachedState: cachedState)
        do {
            try await stateStore.saveState(durableState, for: scope)
        } catch {
            persistenceFailed(error, for: scope, token: token)
            return
        }
        guard isCurrent(token, for: scope) else { return }
        tasks[scope] = nil
        states[scope] = AccountOrganizationCoordinatorState(
            scope: scope,
            phase: .idle,
            durableState: durableState
        )
    }

    private func failed(
        _ error: Error,
        for scope: AccountOrganizationScope,
        token: AccountOrganizationRequestToken
    ) async {
        guard isCurrent(token, for: scope) else { return }
        let previous = states[scope]?.durableState ?? AccountOrganizationDurableState(cachedState: nil)
        let failedState = AccountOrganizationDurableState(
            cachedState: previous.cachedState,
            freshness: freshness(for: error, retaining: previous.freshness.lastSuccessfulSyncAt)
        )
        do {
            try await stateStore.saveState(failedState, for: scope)
        } catch {
            persistenceFailed(error, for: scope, token: token)
            return
        }
        guard isCurrent(token, for: scope) else { return }
        tasks[scope] = nil
        states[scope] = AccountOrganizationCoordinatorState(
            scope: scope,
            phase: .idle,
            durableState: failedState
        )
    }

    private func cancelled(scope: AccountOrganizationScope, token: AccountOrganizationRequestToken) {
        guard isCurrent(token, for: scope) else { return }
        tasks[scope] = nil
        if let state = states[scope] {
            states[scope] = AccountOrganizationCoordinatorState(
                scope: scope,
                phase: .idle,
                durableState: state.durableState
            )
        }
    }

    private func persistenceFailed(
        _ error: Error,
        for scope: AccountOrganizationScope,
        token: AccountOrganizationRequestToken
    ) {
        guard isCurrent(token, for: scope) else { return }
        tasks[scope] = nil
        let previous = states[scope]?.durableState ?? AccountOrganizationDurableState(cachedState: nil)
        let failedState = AccountOrganizationDurableState(
            cachedState: previous.cachedState,
            freshness: FreshnessState(
                status: .failed,
                lastSuccessfulSyncAt: previous.freshness.lastSuccessfulSyncAt,
                detail: "Synchronization state could not be stored: \(String(reflecting: type(of: error)))."
            )
        )
        states[scope] = AccountOrganizationCoordinatorState(
            scope: scope,
            phase: .idle,
            durableState: failedState
        )
    }

    private func freshness(for error: Error, retaining lastSuccessfulSyncAt: Date?) -> FreshnessState {
        var freshness: FreshnessState
        if let classified = error as? AccountOrganizationRefreshFailure {
            freshness = classified.freshness
        } else if let organizationError = error as? OrganizationRefreshError {
            switch organizationError {
            case .ssoRequirement:
                freshness = FreshnessState(
                    status: .ssoRequired,
                    detail: "GitHub organization SSO authorization is required."
                )
            }
        } else if let failure = error as? GitHubFailure {
            freshness = freshnessState(for: failure)
        } else {
            freshness = FreshnessState(
                status: .failed,
                detail: "Synchronization failed: \(String(reflecting: type(of: error)))."
            )
        }
        freshness = FreshnessState(
            status: freshness.status,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            nextRetryAt: freshness.nextRetryAt,
            detail: freshness.detail
        )
        return freshness
    }

    private func freshnessState(for failure: GitHubFailure) -> FreshnessState {
        if failure.ssoHeader != nil {
            return FreshnessState(
                status: .ssoRequired,
                detail: "GitHub organization SSO authorization is required."
            )
        }
        if let restriction = failure.accessRestriction {
            switch restriction {
            case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
                return FreshnessState(
                    status: .approvalRequired,
                    detail: "GitHub organization access approval is required."
                )
            case .organizationPolicyBlocked:
                return FreshnessState(
                    status: .partial,
                    detail: "GitHub organization policy limits the selected account's access."
                )
            }
        }
        switch failure.kind {
        case .unauthorized:
            return FreshnessState(
                status: .authenticationRequired,
                detail: "Reconnect the selected account to continue synchronization."
            )
        case .rateLimited, .secondaryRateLimited:
            return FreshnessState(
                status: .rateLimited,
                nextRetryAt: failure.retryAfter.map { Date.now.addingTimeInterval($0) },
                detail: "GitHub is temporarily limiting synchronization requests."
            )
        case .forbidden, .notFound:
            return FreshnessState(
                status: .partial,
                detail: "The selected account cannot access all organization resources."
            )
        case .serverFailure, .unexpectedResponse:
            return FreshnessState(
                status: .failed,
                detail: "GitHub did not complete the synchronization request."
            )
        }
    }

    private func cancelTask(for scope: AccountOrganizationScope) {
        tasks.removeValue(forKey: scope)?.cancel()
    }

    private func nextToken(for scope: AccountOrganizationScope) -> AccountOrganizationRequestToken {
        let token = AccountOrganizationRequestToken(rawValue: (generations[scope] ?? 0) &+ 1)
        generations[scope] = token.rawValue
        return token
    }

    private func isCurrent(_ token: AccountOrganizationRequestToken, for scope: AccountOrganizationScope) -> Bool {
        generations[scope] == token.rawValue
    }
}
