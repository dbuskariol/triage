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

enum AccountOrganizationRefreshPriority: Equatable, Sendable {
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
    let synchronizationScope: SynchronizationScope
    let scope: AccountOrganizationScope
    let token: AccountOrganizationRequestToken
    let priority: AccountOrganizationRefreshPriority
    let requestPriority: GitHubRequestPriority
    let reconciliationIntent: SynchronizationReconciliationIntent
}

enum AccountOrganizationCoverageManifest {
    static let requiredFeatures: Set<CoverageFeature> = [
        .repositories,
        .teams,
        .issues,
        .pullRequests,
        .reviews,
        .reviewThreads,
        .timelines,
        .discussions,
        .discussionComments,
        .discussionReplies,
        .projects,
        .projectItems,
        .roleDiscovery
    ]

    static func missingFeatures(in coverage: [CoverageRecord]) -> Set<CoverageFeature> {
        requiredFeatures.subtracting(Set(coverage.map(\.feature)))
    }

    static func missingFeatures(
        in requirements: [CoverageRequirement]
    ) -> Set<CoverageFeature> {
        requiredFeatures.subtracting(Set(requirements.map(\.feature)))
    }
}

struct AccountOrganizationCachedState: Codable, Equatable, Sendable {
    let coverage: [CoverageRecord]
    /// The authoritative coverage topology planned for this refresh. A nil
    /// manifest represents a legacy or not-yet-integrated producer and must
    /// never be treated as complete merely because every present record is
    /// complete.
    let coverageRequirements: [CoverageRequirement]?
    let lastSuccessfulSyncAt: Date?

    init(
        coverage: [CoverageRecord],
        coverageRequirements: [CoverageRequirement]? = nil,
        lastSuccessfulSyncAt: Date?
    ) {
        self.coverage = coverage
        self.coverageRequirements = coverageRequirements
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
        guard let coverageRequirements,
              !coverageRequirements.isEmpty
        else {
            return FreshnessState(
                status: .partial,
                lastSuccessfulSyncAt: latestSuccess,
                detail: "The required GitHub coverage manifest is not available yet."
            )
        }
        guard AccountOrganizationCoverageManifest.missingFeatures(
            in: coverageRequirements
        ).isEmpty else {
            return FreshnessState(
                status: .partial,
                lastSuccessfulSyncAt: latestSuccess,
                detail: "Some required GitHub feature coverage is not available yet."
            )
        }
        guard let first = coverage.first,
              coverage.allSatisfy({ record in
                  record.accountID == first.accountID
                      && record.organizationID == first.organizationID
                      && record.credentialRevision == first.credentialRevision
                      && record.capabilityRevision == first.capabilityRevision
              })
        else {
            return FreshnessState(
                status: .partial,
                lastSuccessfulSyncAt: latestSuccess,
                detail: "Synchronization coverage spans more than one authority revision."
            )
        }
        let evaluation = CoverageEvaluator().evaluate(
            requirements: coverageRequirements,
            records: coverage,
            accountID: first.accountID,
            organizationID: first.organizationID,
            credentialRevision: first.credentialRevision,
            capabilityRevision: first.capabilityRevision
        )
        guard evaluation.isComplete else {
            return FreshnessState(
                status: evaluation.freshness.status,
                lastSuccessfulSyncAt: latestSuccess,
                detail: evaluation.freshness.detail
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
    func loadState(for scope: SynchronizationScope) async throws -> AccountOrganizationDurableState?
}

/// Commits the terminal scheduler transition and its matching cached/freshness
/// projection in one encrypted-vault transaction.
protocol AccountOrganizationRefreshFinalizing: Sendable {
    func finalize(
        _ state: AccountOrganizationDurableState,
        schedule: OrganizationSchedulerState,
        for scope: SynchronizationScope,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) async throws -> AccountOrganizationDurableState?

    /// Commits a terminal failed attempt after snapshotting the exact
    /// revision-qualified coverage already written by its source streams.
    /// A nil result means the scheduler CAS lost ownership and nothing changed.
    func finalizeFailure(
        _ state: AccountOrganizationDurableState,
        schedule: OrganizationSchedulerState,
        for scope: SynchronizationScope,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) async throws -> AccountOrganizationDurableState?

    /// Commits a cancelled attempt after snapshotting any exact
    /// revision-qualified coverage written before cancellation completed.
    /// A nil result means the scheduler CAS lost ownership and nothing changed.
    func finalizeInterruption(
        _ state: AccountOrganizationDurableState,
        schedule: OrganizationSchedulerState,
        for scope: SynchronizationScope,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) async throws -> AccountOrganizationDurableState?
}

protocol AccountOrganizationRefreshOperating: Sendable {
    func refresh(_ request: AccountOrganizationRefreshRequest) async throws -> AccountOrganizationCachedState
}

protocol OrganizationSchedulerStateStoring: Sendable {
    func state(for scope: SynchronizationScope) async throws -> OrganizationSchedulerState?
    /// Atomically returns the current revision-qualified state, or inserts and
    /// returns `initial` when no current state exists.
    func createIfAbsent(
        _ initial: OrganizationSchedulerState
    ) async throws -> OrganizationSchedulerState
    func claim(
        _ state: OrganizationSchedulerState,
        replacingIdleGeneration expectedGeneration: UInt64
    ) async throws -> Bool
    func replace(
        _ state: OrganizationSchedulerState,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) async throws -> Bool
}

enum AccountOrganizationRefreshFailure: Error, Equatable, Sendable {
    case offline(detail: String?)
    case authenticationRequired(detail: String?)
    case ssoRequired(detail: String?)
    case approvalRequired(detail: String?)
    case rateLimited(retryAt: Date?, detail: String?)
    case unavailable(detail: String?)
    case failed(detail: String?)

    var freshness: FreshnessState {
        switch self {
        case .offline:
            FreshnessState(
                status: .offline,
                detail: "A network connection is required to refresh GitHub data."
            )
        case .authenticationRequired:
            FreshnessState(
                status: .authenticationRequired,
                detail: "Reconnect the selected account to continue synchronization."
            )
        case .ssoRequired:
            FreshnessState(
                status: .ssoRequired,
                detail: "GitHub organization SSO authorization is required."
            )
        case .approvalRequired:
            FreshnessState(
                status: .approvalRequired,
                detail: "GitHub organization access approval is required."
            )
        case let .rateLimited(retryAt, _):
            FreshnessState(
                status: .rateLimited,
                nextRetryAt: retryAt,
                detail: "GitHub is temporarily limiting synchronization requests."
            )
        case .unavailable:
            FreshnessState(
                status: .partial,
                detail: "Some GitHub organization resources are unavailable."
            )
        case .failed:
            FreshnessState(
                status: .failed,
                detail: "GitHub did not complete the synchronization request."
            )
        }
    }
}

enum AccountOrganizationLoadPhase: Equatable, Sendable {
    case idle
    case activatingCached
    case refreshing
}

struct AccountOrganizationCoordinatorState: Equatable, Sendable {
    let synchronizationScope: SynchronizationScope
    let scope: AccountOrganizationScope
    let phase: AccountOrganizationLoadPhase
    let durableState: AccountOrganizationDurableState
    let schedulerState: OrganizationSchedulerState?

    init(
        synchronizationScope: SynchronizationScope,
        phase: AccountOrganizationLoadPhase,
        durableState: AccountOrganizationDurableState,
        schedulerState: OrganizationSchedulerState? = nil
    ) {
        self.synchronizationScope = synchronizationScope
        scope = AccountOrganizationScope(
            accountID: synchronizationScope.accountID,
            organizationID: synchronizationScope.organizationID
        )
        self.phase = phase
        self.durableState = durableState
        self.schedulerState = schedulerState
    }

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

enum AccountOrganizationCoordinatorError: Error, Equatable, Sendable {
    case runtimeGenerationExhausted
    case scheduleGenerationExhausted
    case scheduleOwnershipLost
    case invalidCachedStateScope
}

actor AccountOrganizationCoordinator {
    typealias CachedStateActivation = @Sendable (
        AccountOrganizationScope,
        AccountOrganizationDurableState
    ) async -> Void

    private struct ActiveRefresh: Sendable {
        let synchronizationScope: SynchronizationScope
        let token: AccountOrganizationRequestToken
        let attemptID: UUID
        let generation: UInt64
        let trigger: OrganizationRefreshScheduleTrigger
        let priority: AccountOrganizationRefreshPriority

        var scope: AccountOrganizationScope {
            AccountOrganizationScope(
                accountID: synchronizationScope.accountID,
                organizationID: synchronizationScope.organizationID
            )
        }
    }

    private struct RefreshCompletionWaiter {
        let token: AccountOrganizationRequestToken
        let continuation: CheckedContinuation<Void, Never>
    }

    private let stateStore: any AccountOrganizationCachedStateStoring
    private let scheduleStore: any OrganizationSchedulerStateStoring
    private let finalizer: any AccountOrganizationRefreshFinalizing
    private let refreshOperation: any AccountOrganizationRefreshOperating
    private let schedulingPolicy: OrganizationRefreshSchedulingPolicy
    private let activateCachedState: CachedStateActivation
    private let clock: @Sendable () -> Date
    private let randomUnit: @Sendable () -> Double
    private let makeAttemptID: @Sendable () -> UUID
    private var selectedSynchronizationScopeStorage: SynchronizationScope?
    private var states: [AccountOrganizationScope: AccountOrganizationCoordinatorState] = [:]
    private var tasks: [AccountOrganizationScope: Task<Void, Never>] = [:]
    private var activeRefreshes: [AccountOrganizationScope: ActiveRefresh] = [:]
    private var completionWaiters: [
        AccountOrganizationScope: [UUID: RefreshCompletionWaiter]
    ] = [:]
    private var runtimeGenerations: [AccountOrganizationScope: UInt64] = [:]
    private var externallyOwnedScheduleScopes: Set<SynchronizationScope> = []
    private var selectionGeneration: UInt64 = 0

    init(
        stateStore: any AccountOrganizationCachedStateStoring,
        scheduleStore: any OrganizationSchedulerStateStoring,
        finalizer: any AccountOrganizationRefreshFinalizing,
        refreshOperation: any AccountOrganizationRefreshOperating,
        schedulingPolicy: OrganizationRefreshSchedulingPolicy = .init(),
        activateCachedState: @escaping CachedStateActivation = { _, _ in },
        clock: @escaping @Sendable () -> Date = Date.init,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        makeAttemptID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.stateStore = stateStore
        self.scheduleStore = scheduleStore
        self.finalizer = finalizer
        self.refreshOperation = refreshOperation
        self.schedulingPolicy = schedulingPolicy
        self.activateCachedState = activateCachedState
        self.clock = clock
        self.randomUnit = randomUnit
        self.makeAttemptID = makeAttemptID
    }

    func selectedScope() -> AccountOrganizationScope? {
        selectedSynchronizationScopeStorage.map(Self.accountOrganizationScope)
    }

    func selectedSynchronizationScope() -> SynchronizationScope? {
        selectedSynchronizationScopeStorage
    }

    func state(for synchronizationScope: SynchronizationScope) -> AccountOrganizationCoordinatorState? {
        let state = states[Self.accountOrganizationScope(synchronizationScope)]
        return state?.synchronizationScope == synchronizationScope ? state : nil
    }

    func select(_ synchronizationScope: SynchronizationScope) async throws {
        let scope = Self.accountOrganizationScope(synchronizationScope)
        let previousSelection = selectedSynchronizationScopeStorage
        let currentSelectionGeneration = try nextSelectionGeneration()
        selectedSynchronizationScopeStorage = synchronizationScope
        if let previousSelection,
           Self.accountOrganizationScope(previousSelection) != scope {
            let previouslySelected = Self.accountOrganizationScope(previousSelection)
            _ = try await cancelRefresh(for: previouslySelected, publishIdleState: true)
            guard isCurrentSelection(
                synchronizationScope,
                generation: currentSelectionGeneration
            ) else { return }
        }
        let activationToken = try await cancelRefresh(for: scope, publishIdleState: false)
        guard isCurrentSelection(
            synchronizationScope,
            generation: currentSelectionGeneration
        ) else { return }
        let durableState = try await loadDurableState(for: synchronizationScope)
        guard isCurrentSelection(
            synchronizationScope,
            generation: currentSelectionGeneration
        ), isCurrent(activationToken, for: scope) else { return }

        states[scope] = AccountOrganizationCoordinatorState(
            synchronizationScope: synchronizationScope,
            phase: .activatingCached,
            durableState: durableState,
            schedulerState: currentState(
                for: synchronizationScope
            )?.schedulerState
        )
        await activateCachedState(scope, durableState)
        guard isCurrentSelection(
            synchronizationScope,
            generation: currentSelectionGeneration
        ), isCurrent(activationToken, for: scope) else { return }

        try await beginRefresh(
            synchronizationScope,
            trigger: .selectedOrganization,
            priority: .selectedOrganization,
            durableState: durableState,
            expectedToken: activationToken
        )
    }

    func refreshSelected() async throws {
        guard let synchronizationScope = selectedSynchronizationScopeStorage else { return }
        try await refresh(synchronizationScope, priority: .manual)
    }

    func refresh(
        _ synchronizationScope: SynchronizationScope,
        priority: AccountOrganizationRefreshPriority
    ) async throws {
        let scope = Self.accountOrganizationScope(synchronizationScope)
        let refreshToken = try await cancelRefresh(for: scope, publishIdleState: false)
        let loadedDurableState = try await loadDurableState(for: synchronizationScope)
        let durableState = currentState(for: synchronizationScope)?.durableState
            ?? loadedDurableState
        try await beginRefresh(
            synchronizationScope,
            trigger: Self.trigger(for: priority),
            priority: priority,
            durableState: durableState,
            expectedToken: refreshToken
        )
    }

    /// Suspends until the refresh currently owned by `synchronizationScope`
    /// reaches a terminal state. A caller whose request was superseded receives
    /// cancellation rather than observing the replacement request as its own.
    func waitForRefreshCompletion(
        for synchronizationScope: SynchronizationScope
    ) async throws -> AccountOrganizationCoordinatorState? {
        let scope = Self.accountOrganizationScope(synchronizationScope)
        guard let token = activeRefreshes[scope]?.token else {
            try Task.checkCancellation()
            return state(for: synchronizationScope)
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      activeRefreshes[scope]?.token == token,
                      isCurrent(token, for: scope)
                else {
                    continuation.resume()
                    return
                }
                completionWaiters[scope, default: [:]][waiterID] = RefreshCompletionWaiter(
                    token: token,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelCompletionWaiter(waiterID, for: scope)
            }
        }
        try Task.checkCancellation()
        if !isCurrent(token, for: scope) {
            throw CancellationError()
        }
        return state(for: synchronizationScope)
    }

    func cancelRefresh(for scope: AccountOrganizationScope) async throws {
        _ = try await cancelRefresh(for: scope, publishIdleState: true)
    }

    func applicationDidBecomeActive(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async throws {
        var uniqueScopes: [AccountOrganizationScope: SynchronizationScope] = [:]
        for synchronizationScope in synchronizationScopes {
            uniqueScopes[Self.accountOrganizationScope(synchronizationScope)] = synchronizationScope
        }
        let selected = selectedScope()
        let ordered = uniqueScopes.values.sorted { lhs, rhs in
            let lhsScope = Self.accountOrganizationScope(lhs)
            let rhsScope = Self.accountOrganizationScope(rhs)
            let lhsRank = Self.activationRank(
                lhsScope,
                selected: selected,
                activeAccountID: activeAccountID
            )
            let rhsRank = Self.activationRank(
                rhsScope,
                selected: selected,
                activeAccountID: activeAccountID
            )
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhsScope.accountID.rawValue != rhsScope.accountID.rawValue {
                return lhsScope.accountID.rawValue < rhsScope.accountID.rawValue
            }
            return lhsScope.organizationID.rawValue < rhsScope.organizationID.rawValue
        }
        for synchronizationScope in ordered {
            try await refreshIfDue(
                synchronizationScope,
                isActiveAccount: synchronizationScope.accountID == activeAccountID
            )
        }
    }

    private func refreshIfDue(
        _ synchronizationScope: SynchronizationScope,
        isActiveAccount: Bool
    ) async throws {
        let scope = Self.accountOrganizationScope(synchronizationScope)
        guard tasks[scope] == nil, activeRefreshes[scope] == nil else { return }
        let refreshToken = try nextToken(for: scope)
        let loadedDurableState = try await loadDurableState(for: synchronizationScope)
        let durableState = currentState(for: synchronizationScope)?.durableState
            ?? loadedDurableState
        let schedule = try await preparedSchedule(for: synchronizationScope)
        let incrementalPriority: AccountOrganizationRefreshPriority = isActiveAccount
            ? .activeApplication
            : .inactiveAccount
        let incrementalTrigger = Self.trigger(for: incrementalPriority)
        let eligibilityDate = clock()
        if schedulingPolicy.eligibility(
            of: schedule,
            for: .fullReconciliation,
            at: eligibilityDate
        ) == .eligible {
            try await startRefresh(
                synchronizationScope,
                schedule: schedule,
                trigger: .fullReconciliation,
                priority: .fullReconciliation,
                durableState: durableState,
                expectedToken: refreshToken
            )
            return
        }
        if schedulingPolicy.eligibility(
            of: schedule,
            for: incrementalTrigger,
            at: eligibilityDate
        ) == .eligible {
            try await startRefresh(
                synchronizationScope,
                schedule: schedule,
                trigger: incrementalTrigger,
                priority: incrementalPriority,
                durableState: durableState,
                expectedToken: refreshToken
            )
            return
        }
        guard isCurrent(refreshToken, for: scope) else { return }
        states[scope] = AccountOrganizationCoordinatorState(
            synchronizationScope: synchronizationScope,
            phase: .idle,
            durableState: durableState,
            schedulerState: schedule
        )
    }

    private func beginRefresh(
        _ synchronizationScope: SynchronizationScope,
        trigger: OrganizationRefreshScheduleTrigger,
        priority: AccountOrganizationRefreshPriority,
        durableState: AccountOrganizationDurableState,
        expectedToken: AccountOrganizationRequestToken
    ) async throws {
        let schedule = try await preparedSchedule(for: synchronizationScope)
        guard isCurrent(expectedToken, for: Self.accountOrganizationScope(synchronizationScope)) else {
            return
        }
        try await startRefresh(
            synchronizationScope,
            schedule: schedule,
            trigger: trigger,
            priority: priority,
            durableState: durableState,
            expectedToken: expectedToken
        )
    }

    private func startRefresh(
        _ synchronizationScope: SynchronizationScope,
        schedule: OrganizationSchedulerState,
        trigger: OrganizationRefreshScheduleTrigger,
        priority: AccountOrganizationRefreshPriority,
        durableState: AccountOrganizationDurableState,
        expectedToken: AccountOrganizationRequestToken
    ) async throws {
        let scope = Self.accountOrganizationScope(synchronizationScope)
        guard isCurrent(expectedToken, for: scope) else { return }
        let attemptID = makeAttemptID()
        switch schedulingPolicy.start(
            schedule,
            trigger: trigger,
            attemptID: attemptID,
            at: clock()
        ) {
        case let .deferred(eligibility):
            guard isCurrent(expectedToken, for: scope) else { return }
            states[scope] = AccountOrganizationCoordinatorState(
                synchronizationScope: synchronizationScope,
                phase: .idle,
                durableState: durableStateForDeferral(
                    eligibility,
                    retaining: durableState
                ),
                schedulerState: schedule
            )
        case .generationExhausted:
            throw AccountOrganizationCoordinatorError.scheduleGenerationExhausted
        case let .started(startedSchedule):
            let activeRefresh = ActiveRefresh(
                synchronizationScope: synchronizationScope,
                token: expectedToken,
                attemptID: attemptID,
                generation: startedSchedule.generation,
                trigger: trigger,
                priority: priority
            )
            activeRefreshes[scope] = activeRefresh
            do {
                guard try await scheduleStore.claim(
                    startedSchedule,
                    replacingIdleGeneration: schedule.generation
                ) else {
                    try await abandonClaim(activeRefresh, durableState: durableState)
                    return
                }
            } catch {
                if owns(activeRefresh) {
                    clearRuntimeOwnership(of: activeRefresh)
                    persistenceFailed(
                        error,
                        for: synchronizationScope,
                        schedulerState: schedule
                    )
                }
                throw error
            }
            guard owns(activeRefresh) else {
                try await releaseStaleClaim(
                    activeRefresh,
                    startedSchedule: startedSchedule
                )
                return
            }
            states[scope] = AccountOrganizationCoordinatorState(
                synchronizationScope: synchronizationScope,
                phase: .refreshing,
                durableState: durableState,
                schedulerState: startedSchedule
            )
            launch(activeRefresh)
        }
    }

    private func abandonClaim(
        _ activeRefresh: ActiveRefresh,
        durableState: AccountOrganizationDurableState
    ) async throws {
        let scope = activeRefresh.scope
        guard owns(activeRefresh) else { return }
        let schedulerState: OrganizationSchedulerState
        do {
            guard let reloaded = try await scheduleStore.state(
                for: activeRefresh.synchronizationScope
            ) else {
                throw AccountOrganizationCoordinatorError.scheduleOwnershipLost
            }
            schedulerState = reloaded
        } catch {
            if owns(activeRefresh) {
                clearRuntimeOwnership(of: activeRefresh)
                persistenceFailed(
                    error,
                    for: activeRefresh.synchronizationScope,
                    schedulerState: states[scope]?.schedulerState
                )
            }
            throw error
        }
        guard owns(activeRefresh) else { return }
        recordExternalOwnershipIfActive(
            schedulerState,
            for: activeRefresh.synchronizationScope
        )
        clearRuntimeOwnership(of: activeRefresh)
        states[scope] = AccountOrganizationCoordinatorState(
            synchronizationScope: activeRefresh.synchronizationScope,
            phase: .idle,
            durableState: durableState,
            schedulerState: schedulerState
        )
    }

    private func releaseStaleClaim(
        _ activeRefresh: ActiveRefresh,
        startedSchedule: OrganizationSchedulerState
    ) async throws {
        guard let cancelledSchedule = schedulingPolicy.cancel(
            startedSchedule,
            ownedBy: activeRefresh.attemptID,
            generation: activeRefresh.generation,
            at: clock()
        ) else { return }
        guard try await scheduleStore.replace(
            cancelledSchedule,
            ifOwnedBy: activeRefresh.attemptID,
            generation: activeRefresh.generation
        ) else {
            externallyOwnedScheduleScopes.insert(activeRefresh.synchronizationScope)
            throw AccountOrganizationCoordinatorError.scheduleOwnershipLost
        }
    }

    private func launch(_ activeRefresh: ActiveRefresh) {
        let scope = activeRefresh.scope
        let operation = refreshOperation
        tasks[scope] = Task(priority: activeRefresh.priority.taskPriority) {
            let request = AccountOrganizationRefreshRequest(
                synchronizationScope: activeRefresh.synchronizationScope,
                scope: scope,
                token: activeRefresh.token,
                priority: activeRefresh.priority,
                requestPriority: activeRefresh.priority.requestPriority,
                reconciliationIntent: activeRefresh.trigger.reconciliationIntent
            )
            do {
                let cachedState = try await operation.refresh(request)
                await self.complete(cachedState: cachedState, activeRefresh: activeRefresh)
            } catch is CancellationError {
                await self.cancelled(activeRefresh)
            } catch {
                await self.failed(error, activeRefresh: activeRefresh)
            }
        }
    }

    private func complete(
        cachedState: AccountOrganizationCachedState,
        activeRefresh: ActiveRefresh
    ) async {
        let scope = activeRefresh.scope
        guard owns(activeRefresh) else { return }
        guard Self.isAuthoritative(
            cachedState,
            for: activeRefresh.synchronizationScope
        ) else {
            await failed(
                AccountOrganizationCoordinatorError.invalidCachedStateScope,
                activeRefresh: activeRefresh
            )
            return
        }
        let eventDate = clock()
        guard let currentSchedule = states[scope]?.schedulerState,
              let completedSchedule = schedulingPolicy.finish(
                  currentSchedule,
                  ownedBy: activeRefresh.attemptID,
                  generation: activeRefresh.generation,
                  trigger: activeRefresh.trigger,
                  outcome: .completed,
                  at: eventDate,
                  randomUnit: randomUnit()
              )
        else {
            return
        }
        let durableState = AccountOrganizationDurableState(cachedState: cachedState)
        let committedState: AccountOrganizationDurableState
        do {
            guard let finalizedState = try await finalizer.finalize(
                durableState,
                schedule: completedSchedule,
                for: activeRefresh.synchronizationScope,
                ifOwnedBy: activeRefresh.attemptID,
                generation: activeRefresh.generation
            ) else {
                await reconcileLostOwnership(activeRefresh)
                return
            }
            committedState = finalizedState
        } catch {
            persistenceFailed(
                error,
                for: activeRefresh.synchronizationScope,
                schedulerState: currentSchedule
            )
            clearRuntimeOwnership(of: activeRefresh)
            return
        }
        guard owns(activeRefresh) else { return }
        clearRuntimeOwnership(of: activeRefresh)
        states[scope] = AccountOrganizationCoordinatorState(
            synchronizationScope: activeRefresh.synchronizationScope,
            phase: .idle,
            durableState: committedState,
            schedulerState: completedSchedule
        )
    }

    private func failed(_ error: Error, activeRefresh: ActiveRefresh) async {
        let scope = activeRefresh.scope
        guard owns(activeRefresh) else { return }
        let eventDate = clock()
        let previous = currentState(
            for: activeRefresh.synchronizationScope
        )?.durableState
            ?? AccountOrganizationDurableState(cachedState: nil)
        guard let currentSchedule = states[scope]?.schedulerState,
              let failedSchedule = schedulingPolicy.finish(
                  currentSchedule,
                  ownedBy: activeRefresh.attemptID,
                  generation: activeRefresh.generation,
                  trigger: activeRefresh.trigger,
                  outcome: attemptOutcome(for: error, at: eventDate),
                  at: eventDate,
                  randomUnit: randomUnit()
              )
        else {
            return
        }
        let failedState = AccountOrganizationDurableState(
            cachedState: previous.cachedState,
            freshness: freshness(
                for: error,
                at: eventDate,
                durableRetryAt: failedSchedule.rateLimitedUntil,
                retaining: previous.freshness.lastSuccessfulSyncAt
            )
        )
        let committedFailureState: AccountOrganizationDurableState
        do {
            guard let committedState = try await finalizer.finalizeFailure(
                failedState,
                schedule: failedSchedule,
                for: activeRefresh.synchronizationScope,
                ifOwnedBy: activeRefresh.attemptID,
                generation: activeRefresh.generation
            ) else {
                await reconcileLostOwnership(activeRefresh)
                return
            }
            committedFailureState = committedState
        } catch {
            persistenceFailed(
                error,
                for: activeRefresh.synchronizationScope,
                schedulerState: currentSchedule
            )
            clearRuntimeOwnership(of: activeRefresh)
            return
        }
        guard owns(activeRefresh) else { return }
        clearRuntimeOwnership(of: activeRefresh)
        states[scope] = AccountOrganizationCoordinatorState(
            synchronizationScope: activeRefresh.synchronizationScope,
            phase: .idle,
            durableState: committedFailureState,
            schedulerState: failedSchedule
        )
    }

    private func cancelled(_ activeRefresh: ActiveRefresh) async {
        let scope = activeRefresh.scope
        guard owns(activeRefresh),
              let currentSchedule = states[scope]?.schedulerState,
              let cancelledSchedule = schedulingPolicy.cancel(
                  currentSchedule,
                  ownedBy: activeRefresh.attemptID,
                  generation: activeRefresh.generation,
                  at: clock()
              )
        else {
            return
        }
        let interruptedState = Self.interrupted(
            states[scope]?.durableState ?? AccountOrganizationDurableState(cachedState: nil)
        )
        let committedState: AccountOrganizationDurableState
        do {
            guard let finalizedState = try await finalizer.finalizeInterruption(
                interruptedState,
                schedule: cancelledSchedule,
                for: activeRefresh.synchronizationScope,
                ifOwnedBy: activeRefresh.attemptID,
                generation: activeRefresh.generation
            ) else {
                await failLostScheduleOwnership(activeRefresh)
                return
            }
            committedState = finalizedState
        } catch {
            persistenceFailed(
                error,
                for: activeRefresh.synchronizationScope,
                schedulerState: currentSchedule
            )
            clearRuntimeOwnership(of: activeRefresh)
            return
        }
        guard owns(activeRefresh) else { return }
        clearRuntimeOwnership(of: activeRefresh)
        states[scope] = AccountOrganizationCoordinatorState(
            synchronizationScope: activeRefresh.synchronizationScope,
            phase: .idle,
            durableState: committedState,
            schedulerState: cancelledSchedule
        )
    }

    private func cancelRefresh(
        for scope: AccountOrganizationScope,
        publishIdleState: Bool
    ) async throws -> AccountOrganizationRequestToken {
        let cancellationToken = try nextToken(for: scope)
        defer {
            resumeCompletionWaiters(
                for: scope,
                supersededBy: cancellationToken
            )
        }
        let cancelledTask = tasks.removeValue(forKey: scope)
        cancelledTask?.cancel()
        guard let activeRefresh = activeRefreshes.removeValue(forKey: scope) else {
            if publishIdleState,
               isCurrent(cancellationToken, for: scope),
               let state = states[scope] {
                states[scope] = AccountOrganizationCoordinatorState(
                    synchronizationScope: state.synchronizationScope,
                    phase: .idle,
                    durableState: state.durableState,
                    schedulerState: state.schedulerState
                )
            }
            return cancellationToken
        }
        guard isCurrent(cancellationToken, for: scope) else {
            return cancellationToken
        }
        guard let currentSchedule = states[scope]?.schedulerState,
              let cancelledSchedule = schedulingPolicy.cancel(
                  currentSchedule,
                  ownedBy: activeRefresh.attemptID,
                  generation: activeRefresh.generation,
                  at: clock()
              )
        else {
            return cancellationToken
        }
        let priorState = states[scope]?.durableState
            ?? AccountOrganizationDurableState(cachedState: nil)
        let committedState: AccountOrganizationDurableState?
        do {
            committedState = try await finalizer.finalizeInterruption(
                Self.interrupted(priorState),
                schedule: cancelledSchedule,
                for: activeRefresh.synchronizationScope,
                ifOwnedBy: activeRefresh.attemptID,
                generation: activeRefresh.generation
            )
        } catch {
            if isCurrent(cancellationToken, for: scope) {
                persistenceFailed(
                    error,
                    for: activeRefresh.synchronizationScope,
                    schedulerState: currentSchedule
                )
            }
            throw error
        }
        guard let committedState else {
            externallyOwnedScheduleScopes.insert(activeRefresh.synchronizationScope)
            if isCurrent(cancellationToken, for: scope) {
                persistenceFailed(
                    AccountOrganizationCoordinatorError.scheduleOwnershipLost,
                    for: activeRefresh.synchronizationScope,
                    schedulerState: currentSchedule
                )
            }
            throw AccountOrganizationCoordinatorError.scheduleOwnershipLost
        }
        if isCurrent(cancellationToken, for: scope), let state = states[scope] {
            states[scope] = AccountOrganizationCoordinatorState(
                synchronizationScope: state.synchronizationScope,
                phase: publishIdleState ? .idle : state.phase,
                durableState: committedState,
                schedulerState: cancelledSchedule
            )
        }
        return cancellationToken
    }

    private func preparedSchedule(
        for synchronizationScope: SynchronizationScope
    ) async throws -> OrganizationSchedulerState {
        let scope = Self.accountOrganizationScope(synchronizationScope)
        if let stored = try await scheduleStore.state(for: synchronizationScope) {
            guard stored.activeAttemptID != nil else {
                externallyOwnedScheduleScopes.remove(synchronizationScope)
                return stored
            }
            guard !externallyOwnedScheduleScopes.contains(synchronizationScope) else {
                throw AccountOrganizationCoordinatorError.scheduleOwnershipLost
            }
            guard activeRefreshes[scope] == nil else { return stored }
            let recovered = schedulingPolicy.recoverInterruptedAttempt(
                in: stored,
                at: clock()
            )
            guard let attemptID = stored.activeAttemptID else { return recovered }
            if try await scheduleStore.replace(
                recovered,
                ifOwnedBy: attemptID,
                generation: stored.generation
            ) {
                return recovered
            }
            if let reloaded = try await scheduleStore.state(for: synchronizationScope) {
                guard reloaded.activeAttemptID == nil else {
                    externallyOwnedScheduleScopes.insert(synchronizationScope)
                    throw AccountOrganizationCoordinatorError.scheduleOwnershipLost
                }
                externallyOwnedScheduleScopes.remove(synchronizationScope)
                return reloaded
            }
            throw AccountOrganizationCoordinatorError.scheduleOwnershipLost
        }
        externallyOwnedScheduleScopes.remove(synchronizationScope)
        let initial = schedulingPolicy.initialState(for: synchronizationScope, at: clock())
        return try await scheduleStore.createIfAbsent(initial)
    }

    private func reconcileLostOwnership(_ activeRefresh: ActiveRefresh) async {
        let scope = activeRefresh.scope
        guard owns(activeRefresh) else { return }
        clearRuntimeOwnership(of: activeRefresh)
        do {
            let persistedDurableState = try await loadDurableState(
                for: activeRefresh.synchronizationScope
            )
            let schedulerState = try await scheduleStore.state(
                for: activeRefresh.synchronizationScope
            )
            guard isCurrent(activeRefresh.token, for: scope) else { return }
            recordExternalOwnershipIfActive(
                schedulerState,
                for: activeRefresh.synchronizationScope
            )
            states[scope] = AccountOrganizationCoordinatorState(
                synchronizationScope: activeRefresh.synchronizationScope,
                phase: .idle,
                durableState: persistedDurableState,
                schedulerState: schedulerState
            )
            persistenceFailed(
                AccountOrganizationCoordinatorError.scheduleOwnershipLost,
                for: activeRefresh.synchronizationScope,
                schedulerState: schedulerState
            )
        } catch {
            guard isCurrent(activeRefresh.token, for: scope) else { return }
            persistenceFailed(
                error,
                for: activeRefresh.synchronizationScope,
                schedulerState: states[scope]?.schedulerState
            )
        }
    }

    private func failLostScheduleOwnership(_ activeRefresh: ActiveRefresh) async {
        let scope = activeRefresh.scope
        guard owns(activeRefresh) else { return }
        clearRuntimeOwnership(of: activeRefresh)
        do {
            let schedulerState = try await scheduleStore.state(
                for: activeRefresh.synchronizationScope
            )
            guard isCurrent(activeRefresh.token, for: scope) else { return }
            recordExternalOwnershipIfActive(
                schedulerState,
                for: activeRefresh.synchronizationScope
            )
            persistenceFailed(
                AccountOrganizationCoordinatorError.scheduleOwnershipLost,
                for: activeRefresh.synchronizationScope,
                schedulerState: schedulerState
            )
        } catch {
            guard isCurrent(activeRefresh.token, for: scope) else { return }
            persistenceFailed(
                error,
                for: activeRefresh.synchronizationScope,
                schedulerState: states[scope]?.schedulerState
            )
        }
    }

    private func durableStateForDeferral(
        _ eligibility: OrganizationRefreshScheduleEligibility,
        retaining durableState: AccountOrganizationDurableState
    ) -> AccountOrganizationDurableState {
        let lastSuccessfulAt = durableState.freshness.lastSuccessfulSyncAt
        switch eligibility {
        case let .blocked(reason):
            let freshness: FreshnessState
            switch reason {
            case .authenticationRequired:
                freshness = FreshnessState(
                    status: .authenticationRequired,
                    lastSuccessfulSyncAt: lastSuccessfulAt,
                    detail: "Reconnect the selected account to continue synchronization."
                )
            case .ssoRequired:
                freshness = FreshnessState(
                    status: .ssoRequired,
                    lastSuccessfulSyncAt: lastSuccessfulAt,
                    detail: "GitHub organization SSO authorization is required."
                )
            case .approvalRequired:
                freshness = FreshnessState(
                    status: .approvalRequired,
                    lastSuccessfulSyncAt: lastSuccessfulAt,
                    detail: "GitHub organization access approval is required."
                )
            }
            return AccountOrganizationDurableState(
                cachedState: durableState.cachedState,
                freshness: freshness
            )
        case let .rateLimited(until):
            return AccountOrganizationDurableState(
                cachedState: durableState.cachedState,
                freshness: FreshnessState(
                    status: .rateLimited,
                    lastSuccessfulSyncAt: lastSuccessfulAt,
                    nextRetryAt: until,
                    detail: "GitHub is temporarily limiting synchronization requests."
                )
            )
        case .eligible, .inFlight, .notDue:
            return durableState
        }
    }

    private func attemptOutcome(
        for error: Error,
        at date: Date
    ) -> OrganizationRefreshAttemptOutcome {
        if let failure = error as? AccountOrganizationRefreshFailure {
            switch failure {
            case .offline, .failed:
                return .transientFailure
            case .authenticationRequired:
                return .blocked(reason: .authenticationRequired)
            case .ssoRequired:
                return .blocked(reason: .ssoRequired)
            case .approvalRequired:
                return .blocked(reason: .approvalRequired)
            case let .rateLimited(retryAt, _):
                return .rateLimited(retryAt: retryAt)
            case .unavailable:
                return .unavailable
            }
        }
        if error is OrganizationRefreshError {
            return .blocked(reason: .ssoRequired)
        }
        if let failure = error as? GitHubFailure {
            if failure.ssoHeader != nil {
                return .blocked(reason: .ssoRequired)
            }
            if let restriction = failure.accessRestriction {
                switch restriction {
                case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
                    return .blocked(reason: .approvalRequired)
                case .organizationPolicyBlocked:
                    return .unavailable
                }
            }
            switch failure.kind {
            case .unauthorized:
                return .blocked(reason: .authenticationRequired)
            case .rateLimited, .secondaryRateLimited:
                return .rateLimited(
                    retryAt: failure.retryAfter.map(date.addingTimeInterval)
                )
            case .forbidden, .notFound:
                return .unavailable
            case .serverFailure, .unexpectedResponse:
                return .transientFailure
            }
        }
        return .transientFailure
    }

    private func freshness(
        for error: Error,
        at date: Date,
        durableRetryAt: Date?,
        retaining lastSuccessfulSyncAt: Date?
    ) -> FreshnessState {
        let freshness: FreshnessState
        if let classified = error as? AccountOrganizationRefreshFailure {
            switch classified {
            case .offline:
                freshness = FreshnessState(
                    status: .offline,
                    detail: "A network connection is required to refresh GitHub data."
                )
            case .authenticationRequired:
                freshness = FreshnessState(
                    status: .authenticationRequired,
                    detail: "Reconnect the selected account to continue synchronization."
                )
            case .ssoRequired:
                freshness = FreshnessState(
                    status: .ssoRequired,
                    detail: "GitHub organization SSO authorization is required."
                )
            case .approvalRequired:
                freshness = FreshnessState(
                    status: .approvalRequired,
                    detail: "GitHub organization access approval is required."
                )
            case .rateLimited:
                freshness = FreshnessState(
                    status: .rateLimited,
                    nextRetryAt: durableRetryAt,
                    detail: "GitHub is temporarily limiting synchronization requests."
                )
            case .unavailable:
                freshness = FreshnessState(
                    status: .partial,
                    detail: "Some GitHub organization resources are unavailable."
                )
            case .failed:
                freshness = FreshnessState(
                    status: .failed,
                    detail: "GitHub did not complete the synchronization request."
                )
            }
        } else if error is OrganizationRefreshError {
            freshness = FreshnessState(
                status: .ssoRequired,
                detail: "GitHub organization SSO authorization is required."
            )
        } else if let failure = error as? GitHubFailure {
            freshness = freshnessState(for: failure, at: date)
        } else {
            freshness = FreshnessState(
                status: .failed,
                detail: "Organization synchronization did not complete."
            )
        }
        return FreshnessState(
            status: freshness.status,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            nextRetryAt: freshness.nextRetryAt,
            detail: freshness.detail
        )
    }

    private func freshnessState(for failure: GitHubFailure, at date: Date) -> FreshnessState {
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
                nextRetryAt: failure.retryAfter.map(date.addingTimeInterval),
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

    private func persistenceFailed(
        _ error: Error,
        for synchronizationScope: SynchronizationScope,
        schedulerState: OrganizationSchedulerState?
    ) {
        let scope = Self.accountOrganizationScope(synchronizationScope)
        let previous = currentState(for: synchronizationScope)?.durableState
            ?? AccountOrganizationDurableState(cachedState: nil)
        states[scope] = AccountOrganizationCoordinatorState(
            synchronizationScope: synchronizationScope,
            phase: .idle,
            durableState: AccountOrganizationDurableState(
                cachedState: previous.cachedState,
                freshness: FreshnessState(
                    status: .failed,
                    lastSuccessfulSyncAt: previous.freshness.lastSuccessfulSyncAt,
                    detail: "Synchronization state could not be stored."
                )
            ),
            schedulerState: schedulerState
        )
    }

    private func clearRuntimeOwnership(of activeRefresh: ActiveRefresh) {
        let scope = activeRefresh.scope
        guard owns(activeRefresh) else { return }
        tasks[scope] = nil
        activeRefreshes[scope] = nil
        resumeCompletionWaiters(for: scope, matching: activeRefresh.token)
    }

    private func cancelCompletionWaiter(
        _ waiterID: UUID,
        for scope: AccountOrganizationScope
    ) {
        guard let waiter = completionWaiters[scope]?.removeValue(forKey: waiterID) else {
            return
        }
        if completionWaiters[scope]?.isEmpty == true {
            completionWaiters[scope] = nil
        }
        waiter.continuation.resume()
    }

    private func resumeCompletionWaiters(
        for scope: AccountOrganizationScope,
        matching token: AccountOrganizationRequestToken
    ) {
        resumeCompletionWaiters(for: scope) { $0.token == token }
    }

    private func resumeCompletionWaiters(
        for scope: AccountOrganizationScope,
        supersededBy token: AccountOrganizationRequestToken
    ) {
        resumeCompletionWaiters(for: scope) { $0.token.rawValue < token.rawValue }
    }

    private func resumeCompletionWaiters(
        for scope: AccountOrganizationScope,
        where shouldResume: (RefreshCompletionWaiter) -> Bool
    ) {
        guard var waiters = completionWaiters[scope] else { return }
        let resumed = waiters.filter { shouldResume($0.value) }
        for waiterID in resumed.keys {
            waiters[waiterID] = nil
        }
        if waiters.isEmpty {
            completionWaiters[scope] = nil
        } else {
            completionWaiters[scope] = waiters
        }
        for waiter in resumed.values {
            waiter.continuation.resume()
        }
    }

    private nonisolated static func interrupted(
        _ state: AccountOrganizationDurableState
    ) -> AccountOrganizationDurableState {
        AccountOrganizationDurableState(
            cachedState: state.cachedState,
            freshness: FreshnessState(
                status: .stale,
                lastSuccessfulSyncAt: state.freshness.lastSuccessfulSyncAt,
                detail: "Synchronization was cancelled before completion. Cached data is retained."
            )
        )
    }

    private func recordExternalOwnershipIfActive(
        _ schedulerState: OrganizationSchedulerState?,
        for synchronizationScope: SynchronizationScope
    ) {
        if schedulerState?.activeAttemptID != nil {
            externallyOwnedScheduleScopes.insert(synchronizationScope)
        } else {
            externallyOwnedScheduleScopes.remove(synchronizationScope)
        }
    }

    private func owns(_ activeRefresh: ActiveRefresh) -> Bool {
        activeRefreshes[activeRefresh.scope]?.token == activeRefresh.token
            && isCurrent(activeRefresh.token, for: activeRefresh.scope)
    }

    private func nextToken(
        for scope: AccountOrganizationScope
    ) throws -> AccountOrganizationRequestToken {
        let current = runtimeGenerations[scope] ?? 0
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow else {
            throw AccountOrganizationCoordinatorError.runtimeGenerationExhausted
        }
        runtimeGenerations[scope] = next
        return AccountOrganizationRequestToken(rawValue: next)
    }

    private func isCurrent(
        _ token: AccountOrganizationRequestToken,
        for scope: AccountOrganizationScope
    ) -> Bool {
        runtimeGenerations[scope] == token.rawValue
    }

    private func nextSelectionGeneration() throws -> UInt64 {
        let (next, overflow) = selectionGeneration.addingReportingOverflow(1)
        guard !overflow else {
            throw AccountOrganizationCoordinatorError.runtimeGenerationExhausted
        }
        selectionGeneration = next
        return next
    }

    private func isCurrentSelection(
        _ synchronizationScope: SynchronizationScope,
        generation: UInt64
    ) -> Bool {
        selectionGeneration == generation
            && selectedSynchronizationScopeStorage == synchronizationScope
    }

    private func currentState(
        for synchronizationScope: SynchronizationScope
    ) -> AccountOrganizationCoordinatorState? {
        let scope = Self.accountOrganizationScope(synchronizationScope)
        guard states[scope]?.synchronizationScope == synchronizationScope else {
            return nil
        }
        return states[scope]
    }

    private func loadDurableState(
        for synchronizationScope: SynchronizationScope
    ) async throws -> AccountOrganizationDurableState {
        let durableState = try await stateStore.loadState(for: synchronizationScope)
            ?? AccountOrganizationDurableState(cachedState: nil)
        guard Self.isAuthoritative(durableState, for: synchronizationScope) else {
            throw AccountOrganizationCoordinatorError.invalidCachedStateScope
        }
        return durableState
    }

    private static func isAuthoritative(
        _ durableState: AccountOrganizationDurableState,
        for synchronizationScope: SynchronizationScope
    ) -> Bool {
        guard let cachedState = durableState.cachedState else { return true }
        guard !cachedState.coverage.isEmpty else {
            return cachedState.lastSuccessfulSyncAt == nil
                && durableState.freshness.status == .stale
                && durableState.freshness.lastSuccessfulSyncAt == nil
                && durableState.freshness.nextRetryAt == nil
        }
        return isAuthoritative(cachedState, for: synchronizationScope)
    }

    private static func isAuthoritative(
        _ cachedState: AccountOrganizationCachedState,
        for synchronizationScope: SynchronizationScope
    ) -> Bool {
        cachedState.coverage.allSatisfy {
            $0.accountID == synchronizationScope.accountID
                && $0.organizationID == synchronizationScope.organizationID
                && $0.credentialRevision == synchronizationScope.credentialRevision
                && $0.capabilityRevision == synchronizationScope.capabilityRevision
        }
    }

    private static func accountOrganizationScope(
        _ synchronizationScope: SynchronizationScope
    ) -> AccountOrganizationScope {
        AccountOrganizationScope(
            accountID: synchronizationScope.accountID,
            organizationID: synchronizationScope.organizationID
        )
    }

    private static func trigger(
        for priority: AccountOrganizationRefreshPriority
    ) -> OrganizationRefreshScheduleTrigger {
        switch priority {
        case .selectedOrganization:
            .selectedOrganization
        case .manual:
            .manual
        case .activeApplication:
            .activeApplication
        case .inactiveAccount:
            .inactiveAccount
        case .fullReconciliation:
            .fullReconciliation
        }
    }

    private static func activationRank(
        _ scope: AccountOrganizationScope,
        selected: AccountOrganizationScope?,
        activeAccountID: AccountID?
    ) -> Int {
        if scope == selected { return 0 }
        if scope.accountID == activeAccountID { return 1 }
        return 2
    }
}
