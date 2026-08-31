import Foundation

/// The narrow lifecycle-facing surface owned by an account refresh runtime.
/// Keeping this protocol free of views and database handles makes the
/// application lifecycle testable and prevents UI code from constructing a
/// second coordinator for an encrypted vault.
protocol AccountOrganizationLifecycleRunning: Sendable {
    func applicationDidBecomeActive(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async throws

    func wake(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async throws

    func cancelAll() async throws
}

extension AccountOrganizationRefreshRuntime: AccountOrganizationLifecycleRunning {}

extension AccountOrganizationLifecycleRunning {
    /// Runtimes that do not distinguish wake from ordinary activation retain
    /// their existing behavior. The production runtime overrides this to
    /// dispatch the wake-specific high-priority incremental trigger.
    func wake(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async throws {
        try await applicationDidBecomeActive(
            synchronizationScopes: synchronizationScopes,
            activeAccountID: activeAccountID
        )
    }
}

/// An opportunistic process-alive scheduler. Implementations may use
/// `NSBackgroundActivityScheduler`, but must not imply daemon execution or
/// synchronization after the application quits.
protocol OrganizationRefreshBackgroundScheduling: Sendable {
    func schedule(
        identifier: String,
        interval: TimeInterval,
        operation: @escaping @Sendable () async -> Void
    ) async

    func cancel(identifier: String) async
}

/// Safe default when the host has not installed an opportunistic macOS
/// background scheduler. The foreground lifecycle remains fully functional.
actor DisabledOrganizationRefreshBackgroundScheduler: OrganizationRefreshBackgroundScheduling {
    func schedule(
        identifier _: String,
        interval _: TimeInterval,
        operation _: @escaping @Sendable () async -> Void
    ) {}

    func cancel(identifier _: String) async {}
}

/// Process-alive opportunistic scheduling for the production app. The system
/// may defer this work; each execution receives the same lifecycle scope and
/// cancellation fences as foreground triggers and never represents a daemon.
actor NSBackgroundOrganizationRefreshScheduler: OrganizationRefreshBackgroundScheduling {
    private var scheduler: NSBackgroundActivityScheduler?

    func schedule(
        identifier: String,
        interval: TimeInterval,
        operation: @escaping @Sendable () async -> Void
    ) async {
        scheduler?.invalidate()
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.interval = interval
        scheduler.tolerance = min(interval * 0.1, 60)
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            Task {
                await operation()
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    func cancel(identifier _: String) async {
        scheduler?.invalidate()
        scheduler = nil
    }
}

enum OrganizationRefreshLifecycleTrigger: Equatable, Sendable {
    case launch
    case applicationDidBecomeActive
    case wake
    case opportunisticBackground
}

struct OrganizationRefreshLifecycleResult: Equatable, Sendable {
    let trigger: OrganizationRefreshLifecycleTrigger
    let generation: UInt64
    let refreshedAccountIDs: [AccountID]
    let failedAccountIDs: [AccountID]
    let wasCancelled: Bool
}

enum OrganizationRefreshLifecycleServiceError: Error, Equatable, Sendable {
    case generationExhausted
}

/// Owns process-lifecycle scheduling without owning UI state. It enumerates
/// current revision-qualified scopes, retains one runtime reference per
/// account, and delegates due/full-reconciliation decisions to the existing
/// `AccountOrganizationCoordinator` through its runtime. New lifecycle
/// events supersede in-flight enumeration; explicit cancellation also asks
/// retained runtimes to durably stop their coordinator-owned work.
actor OrganizationRefreshLifecycleService {
    typealias ScopeEnumeration = @Sendable () async throws -> [SynchronizationScope]
    typealias ActiveAccountResolution = @Sendable () async -> AccountID?
    typealias RuntimeResolution = @Sendable (AccountID) async throws -> any AccountOrganizationLifecycleRunning

    static let backgroundIdentifier = "com.triage.organization-refresh"

    private let enumerateScopes: ScopeEnumeration
    private let activeAccountID: ActiveAccountResolution
    private let resolveRuntime: RuntimeResolution
    private let backgroundScheduler: any OrganizationRefreshBackgroundScheduling
    private let backgroundInterval: TimeInterval

    private var runtimes: [AccountID: any AccountOrganizationLifecycleRunning] = [:]
    private var activeTask: Task<OrganizationRefreshLifecycleResult, Never>?
    private var activeGeneration: UInt64?
    private var generation: UInt64 = 0
    private var isStopped = false

    init(
        enumerateScopes: @escaping ScopeEnumeration,
        activeAccountID: @escaping ActiveAccountResolution,
        resolveRuntime: @escaping RuntimeResolution,
        backgroundScheduler: any OrganizationRefreshBackgroundScheduling = DisabledOrganizationRefreshBackgroundScheduler(),
        backgroundInterval: TimeInterval = RefreshCadence.dailyFullReconciliation.baseInterval
    ) {
        precondition(backgroundInterval > 0, "Background refresh interval must be positive.")
        self.enumerateScopes = enumerateScopes
        self.activeAccountID = activeAccountID
        self.resolveRuntime = resolveRuntime
        self.backgroundScheduler = backgroundScheduler
        self.backgroundInterval = backgroundInterval
    }

    func launch() async throws -> OrganizationRefreshLifecycleResult {
        try await trigger(.launch)
    }

    func applicationDidBecomeActive() async throws -> OrganizationRefreshLifecycleResult {
        try await trigger(.applicationDidBecomeActive)
    }

    func wake() async throws -> OrganizationRefreshLifecycleResult {
        try await trigger(.wake)
    }

    func opportunisticBackgroundRefresh() async throws -> OrganizationRefreshLifecycleResult {
        try await trigger(.opportunisticBackground)
    }

    /// Removes one account's retained runtime after credential replacement or
    /// account deletion. Advancing the generation prevents an already-running
    /// lifecycle pass from resolving and caching a runtime after the caller
    /// has begun teardown. The background callback remains installed; its next
    /// run resolves only current scopes and therefore constructs a fresh
    /// runtime when the account remains connected.
    func evictRuntime(for accountID: AccountID) async {
        _ = advanceGeneration()
        activeTask?.cancel()
        activeTask = nil
        activeGeneration = nil
        guard let runtime = runtimes.removeValue(forKey: accountID) else { return }
        try? await runtime.cancelAll()
    }

    /// Installs only an opportunistic callback. The embedding app should call
    /// this after launch and cancel it during process termination.
    func scheduleOpportunisticBackgroundRefresh() async {
        guard !isStopped else { return }
        await backgroundScheduler.schedule(
            identifier: Self.backgroundIdentifier,
            interval: backgroundInterval,
            operation: { [weak self] in
                _ = try? await self?.opportunisticBackgroundRefresh()
            }
        )
    }

    /// Invalidates the current lifecycle pass and durably interrupts every
    /// runtime this service retained. It is intended for application shutdown,
    /// credential replacement, or account removal.
    func cancel() async {
        let cancelledGeneration = advanceGeneration()
        activeTask?.cancel()
        activeTask = nil
        activeGeneration = nil
        await backgroundScheduler.cancel(identifier: Self.backgroundIdentifier)
        let retained = runtimes.values
        runtimes.removeAll()
        for runtime in retained {
            try? await runtime.cancelAll()
        }
        guard generation == cancelledGeneration else { return }
    }

    func stop() async {
        isStopped = true
        await cancel()
    }

    private func trigger(
        _ trigger: OrganizationRefreshLifecycleTrigger
    ) async throws -> OrganizationRefreshLifecycleResult {
        guard !isStopped else {
            return OrganizationRefreshLifecycleResult(
                trigger: trigger,
                generation: generation,
                refreshedAccountIDs: [],
                failedAccountIDs: [],
                wasCancelled: true
            )
        }
        let nextGeneration = try nextGeneration()
        activeTask?.cancel()
        let task = Task { [weak self] in
            await self?.run(trigger: trigger, generation: nextGeneration)
                ?? OrganizationRefreshLifecycleResult(
                    trigger: trigger,
                    generation: nextGeneration,
                    refreshedAccountIDs: [],
                    failedAccountIDs: [],
                    wasCancelled: true
                )
        }
        activeTask = task
        activeGeneration = nextGeneration
        let result = await task.value
        if activeGeneration == nextGeneration {
            activeTask = nil
            activeGeneration = nil
        }
        return result
    }

    private func run(
        trigger: OrganizationRefreshLifecycleTrigger,
        generation expectedGeneration: UInt64
    ) async -> OrganizationRefreshLifecycleResult {
        do {
            let scopes = try await enumerateScopes()
            guard isCurrent(expectedGeneration) else {
                return cancelledResult(trigger: trigger, generation: expectedGeneration)
            }
            let activeAccount = await activeAccountID()
            guard isCurrent(expectedGeneration) else {
                return cancelledResult(trigger: trigger, generation: expectedGeneration)
            }
            let scopesByAccount = Dictionary(grouping: scopes) { $0.accountID }
            var refreshed = [AccountID]()
            var failed = [AccountID]()
            for accountID in scopesByAccount.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard isCurrent(expectedGeneration) else {
                    return cancelledResult(trigger: trigger, generation: expectedGeneration)
                }
                let accountRuntime: any AccountOrganizationLifecycleRunning
                do {
                    accountRuntime = try await self.runtime(for: accountID, generation: expectedGeneration)
                    guard isCurrent(expectedGeneration) else {
                        return cancelledResult(trigger: trigger, generation: expectedGeneration)
                    }
                    let accountScopes = (scopesByAccount[accountID] ?? []).sorted { lhs, rhs in
                            if lhs.organizationID.rawValue != rhs.organizationID.rawValue {
                                return lhs.organizationID.rawValue < rhs.organizationID.rawValue
                            }
                            if lhs.credentialRevision.rawValue != rhs.credentialRevision.rawValue {
                                return lhs.credentialRevision.rawValue < rhs.credentialRevision.rawValue
                            }
                            return lhs.capabilityRevision.rawValue < rhs.capabilityRevision.rawValue
                        }
                    switch trigger {
                    case .wake:
                        try await accountRuntime.wake(
                            synchronizationScopes: accountScopes,
                            activeAccountID: activeAccount
                        )
                    case .launch, .applicationDidBecomeActive, .opportunisticBackground:
                        try await accountRuntime.applicationDidBecomeActive(
                            synchronizationScopes: accountScopes,
                            activeAccountID: activeAccount
                        )
                    }
                    guard isCurrent(expectedGeneration) else {
                        return cancelledResult(trigger: trigger, generation: expectedGeneration)
                    }
                    refreshed.append(accountID)
                } catch is CancellationError {
                    return cancelledResult(trigger: trigger, generation: expectedGeneration)
                } catch {
                    failed.append(accountID)
                }
            }
            return OrganizationRefreshLifecycleResult(
                trigger: trigger,
                generation: expectedGeneration,
                refreshedAccountIDs: refreshed,
                failedAccountIDs: failed,
                wasCancelled: !isCurrent(expectedGeneration)
            )
        } catch is CancellationError {
            return cancelledResult(trigger: trigger, generation: expectedGeneration)
        } catch {
            return OrganizationRefreshLifecycleResult(
                trigger: trigger,
                generation: expectedGeneration,
                refreshedAccountIDs: [],
                failedAccountIDs: [],
                wasCancelled: !isCurrent(expectedGeneration)
            )
        }
    }

    private func runtime(
        for accountID: AccountID,
        generation expectedGeneration: UInt64
    ) async throws -> any AccountOrganizationLifecycleRunning {
        if let retained = runtimes[accountID] {
            return retained
        }
        let resolved = try await resolveRuntime(accountID)
        guard isCurrent(expectedGeneration) else {
            // Resolution may have opened an account vault while an account
            // replacement/removal evicted this lifecycle pass. A runtime that
            // loses that generation must be torn down before it can escape
            // this service, even when the resolver is not the production
            // coordinator's own post-factory fence.
            try? await resolved.cancelAll()
            throw CancellationError()
        }
        if let retained = runtimes[accountID] {
            // A concurrent lifecycle pass retained a different runtime while
            // this resolution was suspended. Do not leave the surplus runtime
            // alive with an open vault.
            try? await resolved.cancelAll()
            return retained
        }
        runtimes[accountID] = resolved
        return resolved
    }

    private func nextGeneration() throws -> UInt64 {
        let (next, overflow) = generation.addingReportingOverflow(1)
        guard !overflow else {
            throw OrganizationRefreshLifecycleServiceError.generationExhausted
        }
        generation = next
        return next
    }

    @discardableResult
    private func advanceGeneration() -> UInt64 {
        let (next, overflow) = generation.addingReportingOverflow(1)
        if !overflow {
            generation = next
        }
        return generation
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        !Task.isCancelled && !isStopped && generation == expectedGeneration
    }

    private func cancelledResult(
        trigger: OrganizationRefreshLifecycleTrigger,
        generation: UInt64
    ) -> OrganizationRefreshLifecycleResult {
        OrganizationRefreshLifecycleResult(
            trigger: trigger,
            generation: generation,
            refreshedAccountIDs: [],
            failedAccountIDs: [],
            wasCancelled: true
        )
    }
}
