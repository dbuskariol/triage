import XCTest
@testable import Triage

final class OrganizationRefreshLifecycleServiceTests: XCTestCase {
    func testLaunchGroupsScopesByAccountAndRetainsOneRuntimePerAccount() async throws {
        let accountA = AccountID(rawValue: "account-a")!
        let accountB = AccountID(rawValue: "account-b")!
        let scopeAOne = scope(accountID: accountA, organizationID: "organization-a-one")
        let scopeATwo = scope(accountID: accountA, organizationID: "organization-a-two")
        let scopeB = scope(accountID: accountB, organizationID: "organization-b")
        let runtimeA = LifecycleRuntimeSpy()
        let runtimeB = LifecycleRuntimeSpy()
        let resolver = LifecycleRuntimeResolver([accountA: runtimeA, accountB: runtimeB])
        let service = OrganizationRefreshLifecycleService(
            enumerateScopes: { [scopeB, scopeATwo, scopeAOne] },
            activeAccountID: { accountA },
            resolveRuntime: { accountID in try await resolver.runtime(for: accountID) }
        )

        let first = try await service.launch()
        let second = try await service.applicationDidBecomeActive()

        XCTAssertEqual(first.trigger, .launch)
        XCTAssertEqual(first.refreshedAccountIDs, [accountA, accountB])
        XCTAssertTrue(first.failedAccountIDs.isEmpty)
        XCTAssertEqual(second.trigger, .applicationDidBecomeActive)
        let accountAResolutionCount = await resolver.resolveCount(for: accountA)
        let accountBResolutionCount = await resolver.resolveCount(for: accountB)
        XCTAssertEqual(accountAResolutionCount, 1)
        XCTAssertEqual(accountBResolutionCount, 1)

        let callsA = await runtimeA.calls()
        XCTAssertEqual(callsA.count, 2)
        XCTAssertEqual(callsA[0].activeAccountID, accountA)
        XCTAssertEqual(
            callsA[0].scopes.map(\.organizationID.rawValue),
            [scopeAOne, scopeATwo].map(\.organizationID.rawValue).sorted()
        )
        let callsB = await runtimeB.calls()
        XCTAssertEqual(callsB.count, 2)
    }

    func testSourceFailureIsScopedAndDoesNotPreventOtherAccountsFromScheduling() async throws {
        let accountA = AccountID.make()
        let accountB = AccountID.make()
        let failedRuntime = LifecycleRuntimeSpy(shouldFail: true)
        let healthyRuntime = LifecycleRuntimeSpy()
        let resolver = LifecycleRuntimeResolver([accountA: failedRuntime, accountB: healthyRuntime])
        let scopeA = scope(accountID: accountA)
        let scopeB = scope(accountID: accountB)
        let service = OrganizationRefreshLifecycleService(
            enumerateScopes: { [scopeB, scopeA] },
            activeAccountID: { accountA },
            resolveRuntime: { accountID in try await resolver.runtime(for: accountID) }
        )

        let result = try await service.wake()

        XCTAssertEqual(result.trigger, .wake)
        XCTAssertEqual(result.refreshedAccountIDs, [accountB])
        XCTAssertEqual(result.failedAccountIDs, [accountA])
        let healthyCalls = await healthyRuntime.calls()
        XCTAssertEqual(healthyCalls.count, 1)
    }

    func testNewLifecycleTriggerSupersedesAnInFlightGeneration() async throws {
        let accountID = AccountID.make()
        let runtime = SuspendingLifecycleRuntime()
        let resolver = LifecycleRuntimeResolver([accountID: runtime])
        let scope = scope(accountID: accountID)
        let service = OrganizationRefreshLifecycleService(
            enumerateScopes: { [scope] },
            activeAccountID: { accountID },
            resolveRuntime: { accountID in try await resolver.runtime(for: accountID) }
        )

        let first = Task { try? await service.launch() }
        await runtime.waitForFirstCall()
        let second = try await service.applicationDidBecomeActive()
        await runtime.releaseFirstCall()
        let firstResult = await first.value

        XCTAssertFalse(second.wasCancelled)
        XCTAssertEqual(second.trigger, .applicationDidBecomeActive)
        XCTAssertEqual(firstResult?.wasCancelled, true)
        let callCount = await runtime.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testOpportunisticBackgroundHookUsesInjectedSchedulerAndStopsCleanly() async throws {
        let accountID = AccountID.make()
        let runtime = LifecycleRuntimeSpy()
        let resolver = LifecycleRuntimeResolver([accountID: runtime])
        let scheduler = BackgroundSchedulerSpy()
        let scope = scope(accountID: accountID)
        let service = OrganizationRefreshLifecycleService(
            enumerateScopes: { [scope] },
            activeAccountID: { accountID },
            resolveRuntime: { accountID in try await resolver.runtime(for: accountID) },
            backgroundScheduler: scheduler,
            backgroundInterval: 123
        )

        await service.scheduleOpportunisticBackgroundRefresh()
        let scheduledIdentifier = await scheduler.scheduledIdentifier()
        let scheduledInterval = await scheduler.scheduledInterval()
        XCTAssertEqual(scheduledIdentifier, OrganizationRefreshLifecycleService.backgroundIdentifier)
        XCTAssertEqual(scheduledInterval, 123)
        await scheduler.fire()
        let runtimeCalls = await runtime.calls()
        XCTAssertEqual(runtimeCalls.first?.scopes.count, 1)

        await service.stop()
        let cancelledIdentifier = await scheduler.cancelledIdentifier()
        let cancelCount = await runtime.cancelCount()
        XCTAssertEqual(cancelledIdentifier, OrganizationRefreshLifecycleService.backgroundIdentifier)
        XCTAssertEqual(cancelCount, 1)
    }

    private func scope(
        accountID: AccountID,
        organizationID: String? = nil
    ) -> SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: OrganizationID(
                rawValue: organizationID ?? "organization-\(accountID.rawValue)"
            )!,
            credentialRevision: CredentialRevision(rawValue: "credential-\(UUID().uuidString.lowercased())")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-\(UUID().uuidString.lowercased())")!
        )
    }
}

private enum TestError: Error {
    case expected
}

private actor LifecycleRuntimeResolver {
    private let runtimes: [AccountID: any AccountOrganizationLifecycleRunning]
    private var counts: [AccountID: Int] = [:]

    init(_ runtimes: [AccountID: any AccountOrganizationLifecycleRunning]) {
        self.runtimes = runtimes
    }

    func runtime(for accountID: AccountID) throws -> any AccountOrganizationLifecycleRunning {
        counts[accountID, default: 0] += 1
        guard let runtime = runtimes[accountID] else { throw TestError.expected }
        return runtime
    }

    func resolveCount(for accountID: AccountID) -> Int {
        counts[accountID, default: 0]
    }
}

private actor LifecycleRuntimeSpy: AccountOrganizationLifecycleRunning {
    struct Call: Sendable {
        let scopes: [SynchronizationScope]
        let activeAccountID: AccountID?
    }

    private let shouldFail: Bool
    private var recordedCalls = [Call]()
    private var recordedCancelCount = 0

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func applicationDidBecomeActive(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID: AccountID?
    ) async throws {
        recordedCalls.append(.init(scopes: synchronizationScopes, activeAccountID: activeAccountID))
        if shouldFail { throw TestError.expected }
    }

    func cancelAll() async throws {
        recordedCancelCount += 1
    }

    func calls() -> [Call] { recordedCalls }
    func cancelCount() -> Int { recordedCancelCount }
}

private actor SuspendingLifecycleRuntime: AccountOrganizationLifecycleRunning {
    private var count = 0
    private var firstCallWaiter: CheckedContinuation<Void, Never>?
    private var firstCallRelease: CheckedContinuation<Void, Never>?

    func applicationDidBecomeActive(
        synchronizationScopes _: [SynchronizationScope],
        activeAccountID _: AccountID?
    ) async throws {
        count += 1
        guard count == 1 else { return }
        firstCallWaiter?.resume()
        firstCallWaiter = nil
        await withCheckedContinuation { continuation in
            firstCallRelease = continuation
        }
    }

    func cancelAll() async throws {}

    func waitForFirstCall() async {
        if count > 0 { return }
        await withCheckedContinuation { continuation in
            firstCallWaiter = continuation
        }
    }

    func releaseFirstCall() {
        firstCallRelease?.resume()
        firstCallRelease = nil
    }

    func callCount() -> Int { count }
}

private actor BackgroundSchedulerSpy: OrganizationRefreshBackgroundScheduling {
    private var identifier: String?
    private var interval: TimeInterval?
    private var operation: (@Sendable () async -> Void)?
    private var cancelled: String?

    func schedule(
        identifier: String,
        interval: TimeInterval,
        operation: @escaping @Sendable () async -> Void
    ) async {
        self.identifier = identifier
        self.interval = interval
        self.operation = operation
    }

    func cancel(identifier: String) async {
        cancelled = identifier
        operation = nil
    }

    func fire() async {
        await operation?()
    }

    func scheduledIdentifier() -> String? { identifier }
    func scheduledInterval() -> TimeInterval? { interval }
    func cancelledIdentifier() -> String? { cancelled }
}
