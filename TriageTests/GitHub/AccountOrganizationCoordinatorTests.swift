import XCTest
@testable import Triage

final class AccountOrganizationCoordinatorTests: XCTestCase {
    func testSelectionSupersessionCancelsOnlySupersededScope() async throws {
        let store = TestStateStore()
        let operation = ControlledRefreshOperation()
        let coordinator = AccountOrganizationCoordinator(
            stateStore: store,
            refreshOperation: operation
        )
        let first = scope(account: "account-a", organization: "organization-a")
        let second = scope(account: "account-b", organization: "organization-b")

        try await coordinator.select(first)
        let firstToken = (await operation.request(at: 0)).token

        try await coordinator.select(second)
        let secondToken = (await operation.request(at: 1)).token
        await waitUntil {
            await operation.cancelledTokens().contains(firstToken)
        }

        let cancelledTokens = await operation.cancelledTokens()
        let selectedScope = await coordinator.selectedScope()
        let firstState = await coordinator.state(for: first)
        let secondState = await coordinator.state(for: second)
        XCTAssertEqual(cancelledTokens, [firstToken])
        XCTAssertEqual(selectedScope, second)
        XCTAssertEqual(firstState?.phase, .idle)
        XCTAssertEqual(secondState?.phase, .refreshing)

        await operation.succeed(token: secondToken, with: cachedState(at: 2))
    }

    func testStaleCompletionCannotOverwriteSupersedingRefresh() async throws {
        let store = TestStateStore()
        let operation = ControlledRefreshOperation()
        let coordinator = AccountOrganizationCoordinator(
            stateStore: store,
            refreshOperation: operation
        )
        let selected = scope(account: "account", organization: "organization")

        try await coordinator.select(selected)
        let staleToken = (await operation.request(at: 0)).token
        try await coordinator.refresh(selected, priority: .manual)
        let currentToken = (await operation.request(at: 1)).token

        await operation.succeed(token: currentToken, with: cachedState(at: 2))
        await waitUntil {
            await coordinator.state(for: selected)?.durableState.cachedState?.lastSuccessfulSyncAt
                == Date(timeIntervalSinceReferenceDate: 2)
        }
        await operation.succeed(token: staleToken, with: cachedState(at: 1))
        await Task.yield()

        let coordinatorState = await coordinator.state(for: selected)
        let storedState = await store.state(for: selected)
        XCTAssertEqual(
            coordinatorState?.durableState.cachedState?.lastSuccessfulSyncAt,
            Date(timeIntervalSinceReferenceDate: 2)
        )
        XCTAssertEqual(
            storedState?.cachedState?.lastSuccessfulSyncAt,
            Date(timeIntervalSinceReferenceDate: 2)
        )
    }

    func testCachedStateActivatesBeforeNetworkRefresh() async throws {
        let selected = scope(account: "account", organization: "organization")
        let store = TestStateStore(states: [
            selected: AccountOrganizationDurableState(cachedState: cachedState(at: 1))
        ])
        let operation = ControlledRefreshOperation()
        let events = EventLog()
        let coordinator = AccountOrganizationCoordinator(
            stateStore: store,
            refreshOperation: operation,
            activateCachedState: { _, _ in
                await events.append("cached")
            }
        )
        await operation.setOnRefresh {
            await events.append("refresh")
        }

        try await coordinator.select(selected)

        let token = (await operation.request(at: 0)).token
        let eventValues = await events.values()
        XCTAssertEqual(eventValues, ["cached", "refresh"])
        await operation.succeed(token: token, with: cachedState(at: 2))
    }

    func testAccessFailureRemainsScopedToItsAccountOrganization() async throws {
        let store = TestStateStore()
        let operation = ControlledRefreshOperation()
        let coordinator = AccountOrganizationCoordinator(
            stateStore: store,
            refreshOperation: operation
        )
        let inaccessible = scope(account: "account-a", organization: "organization-a")
        let accessible = scope(account: "account-b", organization: "organization-b")

        try await coordinator.select(inaccessible)
        let inaccessibleToken = (await operation.request(at: 0)).token
        await operation.fail(
            token: inaccessibleToken,
            error: AccountOrganizationRefreshFailure.ssoRequired(detail: "Authorize this organization.")
        )
        await waitUntil {
            await coordinator.state(for: inaccessible)?.freshness.status == .ssoRequired
        }

        try await coordinator.select(accessible)
        let accessibleToken = (await operation.request(at: 1)).token
        await operation.succeed(token: accessibleToken, with: completeCachedState(for: accessible, at: 2))
        await waitUntil {
            await coordinator.state(for: accessible)?.freshness.status == .fresh
        }

        let inaccessibleState = await coordinator.state(for: inaccessible)
        let accessibleState = await coordinator.state(for: accessible)
        XCTAssertEqual(inaccessibleState?.freshness.status, .ssoRequired)
        XCTAssertEqual(accessibleState?.freshness.status, .fresh)
    }

    func testSelectedOrganizationUsesHigherRequestPriorityThanInactiveRefresh() async throws {
        let store = TestStateStore()
        let operation = ControlledRefreshOperation()
        let coordinator = AccountOrganizationCoordinator(
            stateStore: store,
            refreshOperation: operation
        )
        let selected = scope(account: "account", organization: "organization")

        try await coordinator.refresh(selected, priority: .inactiveAccount)
        let inactiveRequest = await operation.request(at: 0)

        try await coordinator.select(selected)
        let selectedRequest = await operation.request(at: 1)

        XCTAssertEqual(inactiveRequest.priority, .inactiveAccount)
        XCTAssertEqual(inactiveRequest.requestPriority, .inactiveAccountRefresh)
        XCTAssertEqual(selectedRequest.priority, .selectedOrganization)
        XCTAssertEqual(selectedRequest.requestPriority, .selectedOrganizationRefresh)

        await operation.succeed(token: inactiveRequest.token, with: cachedState(at: 1))
        await operation.succeed(token: selectedRequest.token, with: cachedState(at: 2))
    }

    private func scope(account: String, organization: String) -> AccountOrganizationScope {
        AccountOrganizationScope(
            accountID: AccountID(rawValue: account)!,
            organizationID: OrganizationID(rawValue: organization)!
        )
    }

    private func cachedState(at referenceDate: TimeInterval) -> AccountOrganizationCachedState {
        AccountOrganizationCachedState(
            coverage: [],
            lastSuccessfulSyncAt: Date(timeIntervalSinceReferenceDate: referenceDate)
        )
    }

    private func completeCachedState(
        for scope: AccountOrganizationScope,
        at referenceDate: TimeInterval
    ) -> AccountOrganizationCachedState {
        let date = Date(timeIntervalSinceReferenceDate: referenceDate)
        return AccountOrganizationCachedState(
            coverage: [
                CoverageRecord(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    repositoryID: nil,
                    feature: .roleDiscovery,
                    streamID: SyncStreamID(rawValue: "role-discovery-\(scope.organizationID.rawValue)")!,
                    intervalStart: date,
                    intervalEnd: date,
                    credentialRevision: CredentialRevision(rawValue: "credential")!,
                    capabilityRevision: CapabilityRevision(rawValue: "capability")!,
                    status: .complete,
                    lastSuccessfulAt: date,
                    failureDetail: nil
                )
            ],
            lastSuccessfulSyncAt: date
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied.", file: file, line: line)
    }

}

private actor TestStateStore: AccountOrganizationCachedStateStoring {
    private var states: [AccountOrganizationScope: AccountOrganizationDurableState]

    init(states: [AccountOrganizationScope: AccountOrganizationDurableState] = [:]) {
        self.states = states
    }

    func loadState(for scope: AccountOrganizationScope) -> AccountOrganizationDurableState? {
        states[scope]
    }

    func saveState(_ state: AccountOrganizationDurableState, for scope: AccountOrganizationScope) {
        states[scope] = state
    }

    func state(for scope: AccountOrganizationScope) -> AccountOrganizationDurableState? {
        states[scope]
    }
}

private actor ControlledRefreshOperation: AccountOrganizationRefreshOperating {
    private var storedRequests: [AccountOrganizationRefreshRequest] = []
    private var requestContinuations: [Int: [CheckedContinuation<AccountOrganizationRefreshRequest, Never>]] = [:]
    private var continuations: [AccountOrganizationRequestToken: CheckedContinuation<AccountOrganizationCachedState, Error>] = [:]
    private var terminalResults: [AccountOrganizationRequestToken: Result<AccountOrganizationCachedState, Error>] = [:]
    private var storedCancelledTokens: [AccountOrganizationRequestToken] = []
    private var cancelledRequestTokens: Set<AccountOrganizationRequestToken> = []
    private var onRefresh: (@Sendable () async -> Void)?

    func refresh(_ request: AccountOrganizationRefreshRequest) async throws -> AccountOrganizationCachedState {
        storedRequests.append(request)
        let requestIndex = storedRequests.count - 1
        for continuation in requestContinuations.removeValue(forKey: requestIndex) ?? [] {
            continuation.resume(returning: request)
        }
        await onRefresh?()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result = terminalResults.removeValue(forKey: request.token) {
                    continuation.resume(with: result)
                } else {
                    continuations[request.token] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.recordCancellation(for: request.token)
            }
        }
    }

    func request(at index: Int) async -> AccountOrganizationRefreshRequest {
        precondition(index >= 0)
        if storedRequests.indices.contains(index) {
            let request = storedRequests[index]
            return request
        }
        return await withCheckedContinuation { continuation in
            requestContinuations[index, default: []].append(continuation)
        }
    }

    func cancelledTokens() -> [AccountOrganizationRequestToken] {
        storedCancelledTokens
    }

    func setOnRefresh(_ action: @escaping @Sendable () async -> Void) {
        onRefresh = action
    }

    func succeed(token: AccountOrganizationRequestToken, with state: AccountOrganizationCachedState) {
        resolve(token: token, with: .success(state))
    }

    func fail(token: AccountOrganizationRequestToken, error: Error) {
        resolve(token: token, with: .failure(error))
    }

    private func recordCancellation(for token: AccountOrganizationRequestToken) {
        if cancelledRequestTokens.insert(token).inserted {
            storedCancelledTokens.append(token)
        }
        resolve(token: token, with: .failure(CancellationError()))
    }

    private func resolve(
        token: AccountOrganizationRequestToken,
        with result: Result<AccountOrganizationCachedState, Error>
    ) {
        if let continuation = continuations.removeValue(forKey: token) {
            continuation.resume(with: result)
        } else {
            terminalResults[token] = result
        }
    }
}

private actor EventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}
