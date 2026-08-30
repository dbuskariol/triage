import Foundation
import XCTest
@testable import Triage

private enum CoordinatorTestAwaitError: Error {
    case budgetExhausted(String)
}

final class AccountOrganizationCoordinatorTests: XCTestCase {
    func testSelectionSupersessionCancelsOnlySupersededScope() async throws {
        let fixture = CoordinatorFixture()
        let first = fixture.scope(account: "account-a", organization: "organization-a")
        let second = fixture.scope(account: "account-b", organization: "organization-b")

        try await fixture.coordinator.select(first)
        let firstRequest = try await fixture.operation.request(at: 0)
        try await fixture.coordinator.select(second)
        let secondRequest = try await fixture.operation.request(at: 1)
        try await fixture.operation.awaitCancellation(of: firstRequest)
        let selectedScope = await fixture.coordinator.selectedScope()
        let firstState = await fixture.coordinator.state(for: first)
        let secondState = await fixture.coordinator.state(for: second)
        XCTAssertEqual(selectedScope, fixture.accountOrganizationScope(second))
        XCTAssertEqual(firstState?.phase, .idle)
        XCTAssertEqual(secondState?.phase, .refreshing)

        await fixture.operation.succeed(secondRequest, with: fixture.completeCachedState(for: second, at: 2))
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: second)
        await fixture.operation.finishAllCancelled()
    }

    func testStaleCompletionCannotOverwriteSupersedingRefresh() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()

        try await fixture.coordinator.select(scope)
        let staleRequest = try await fixture.operation.request(at: 0)
        await fixture.operation.ignoreCancellation(for: staleRequest)
        try await fixture.coordinator.refresh(scope, priority: .manual)
        let currentRequest = try await fixture.operation.request(at: 1)

        await fixture.operation.succeed(currentRequest, with: fixture.completeCachedState(for: scope, at: 2))
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: scope)
        await fixture.operation.succeed(staleRequest, with: fixture.completeCachedState(for: scope, at: 1))
        try await fixture.operation.awaitReturn(of: staleRequest)
        await Task.yield()

        let coordinatorState = await fixture.coordinator.state(for: scope)
        let storedState = await fixture.stateStore.state(for: scope)
        XCTAssertEqual(coordinatorState?.durableState.cachedState?.lastSuccessfulSyncAt, fixture.date(2))
        XCTAssertEqual(storedState?.cachedState?.lastSuccessfulSyncAt, fixture.date(2))
    }

    func testCachedStateActivatesBeforeNetworkRefresh() async throws {
        let scope = CoordinatorFixture.defaultScope
        let fixture = CoordinatorFixture(
            cachedStates: [
                scope: AccountOrganizationDurableState(
                    cachedState: Self.fixtureCachedState(for: scope, at: 1)
                )
            ]
        )
        let events = EventLedger()
        await fixture.operation.setOnRefresh { _ in
            await events.append(.refreshStarted)
        }
        let coordinator = fixture.makeCoordinator { _, _ in
            await events.append(.cachedActivated)
        }

        try await coordinator.select(scope)
        let request = try await fixture.operation.request(at: 0)

        let eventValues = await events.values()
        XCTAssertEqual(eventValues, [.cachedActivated, .refreshStarted])
        await fixture.operation.succeed(request, with: fixture.completeCachedState(for: scope, at: 2))
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: coordinator, scope: scope)
    }

    func testAccessFailureRemainsScopedToItsAccountOrganization() async throws {
        let fixture = CoordinatorFixture()
        let inaccessible = fixture.scope(account: "account-a", organization: "organization-a")
        let accessible = fixture.scope(account: "account-b", organization: "organization-b")

        try await fixture.coordinator.select(inaccessible)
        let inaccessibleRequest = try await fixture.operation.request(at: 0)
        await fixture.operation.fail(
            inaccessibleRequest,
            error: AccountOrganizationRefreshFailure.ssoRequired(detail: "https://github.com/orgs/example/sso")
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: inaccessible)

        try await fixture.coordinator.select(accessible)
        let accessibleRequest = try await fixture.operation.request(at: 1)
        await fixture.operation.succeed(
            accessibleRequest,
            with: fixture.completeCachedState(for: accessible, at: 2)
        )
        try await fixture.stateStore.awaitSaveAttempt(2)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: accessible)

        let inaccessibleState = await fixture.coordinator.state(for: inaccessible)
        let accessibleState = await fixture.coordinator.state(for: accessible)
        XCTAssertEqual(inaccessibleState?.freshness.status, .ssoRequired)
        XCTAssertFalse(inaccessibleState?.freshness.detail?.contains("https://") ?? true)
        XCTAssertEqual(accessibleState?.freshness.status, .fresh)
    }

    func testAttachedPriorityRegressionUsesContinuationReceiptRatherThanArrayIndexing() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()

        try await fixture.coordinator.refresh(scope, priority: .inactiveAccount)
        let inactiveRequest = try await fixture.operation.request(at: 0)
        try await fixture.coordinator.select(scope)
        let selectedRequest = try await fixture.operation.request(at: 1)

        XCTAssertEqual(inactiveRequest.priority, .inactiveAccount)
        XCTAssertEqual(inactiveRequest.requestPriority, .inactiveAccountRefresh)
        XCTAssertEqual(selectedRequest.priority, .selectedOrganization)
        XCTAssertEqual(selectedRequest.requestPriority, .selectedOrganizationRefresh)

        await fixture.operation.succeed(
            selectedRequest,
            with: fixture.completeCachedState(for: scope, at: 2)
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: scope)
        await fixture.operation.finishAllCancelled()
    }

    func testSelectedAndManualRefreshBypassCadence() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()
        await fixture.scheduleStore.install(
            fixture.schedule(scope: scope, incrementalOffset: 3_600, fullOffset: 7_200)
        )

        try await fixture.coordinator.refresh(scope, priority: .manual)
        let manualRequest = try await fixture.operation.request(at: 0)
        XCTAssertEqual(manualRequest.priority, .manual)
        try await fixture.coordinator.cancelRefresh(for: fixture.accountOrganizationScope(scope))
        try await fixture.operation.awaitCancellation(of: manualRequest)

        try await fixture.coordinator.select(scope)
        let selectedRequest = try await fixture.operation.request(at: 1)
        XCTAssertEqual(selectedRequest.priority, .selectedOrganization)
        await fixture.operation.succeed(
            selectedRequest,
            with: fixture.completeCachedState(for: scope, at: 3)
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: scope)
    }

    func testAutomaticFutureCadenceDoesNotDispatch() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()
        await fixture.scheduleStore.install(
            fixture.schedule(scope: scope, incrementalOffset: 3_600, fullOffset: 7_200)
        )

        try await fixture.coordinator.applicationDidBecomeActive(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )

        let requestCount = await fixture.operation.requestCount()
        let state = await fixture.coordinator.state(for: scope)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(state?.schedulerState?.nextIncrementalRefreshAt, fixture.date(3_600))
    }

    func testRateLimitAndEveryAccessBlockPreventAllDispatch() async throws {
        let fixture = CoordinatorFixture()
        let rateLimited = fixture.scope(organization: "rate")
        await fixture.scheduleStore.install(
            fixture.schedule(
                scope: rateLimited,
                incrementalOffset: 0,
                fullOffset: 0,
                rateLimitedUntil: fixture.date(900)
            )
        )
        try await fixture.coordinator.refresh(rateLimited, priority: .manual)
        let rateRequestCount = await fixture.operation.requestCount()
        XCTAssertEqual(rateRequestCount, 0)
        let rateState = await fixture.coordinator.state(for: rateLimited)
        XCTAssertEqual(rateState?.freshness.status, .rateLimited)
        XCTAssertEqual(rateState?.freshness.nextRetryAt, fixture.date(900))

        let cases: [(OrganizationRefreshBlockReason, FreshnessStatus)] = [
            (.authenticationRequired, .authenticationRequired),
            (.ssoRequired, .ssoRequired),
            (.approvalRequired, .approvalRequired)
        ]
        for (offset, testCase) in cases.enumerated() {
            let scope = fixture.scope(organization: "blocked-\(offset)")
            await fixture.scheduleStore.install(
                fixture.schedule(
                    scope: scope,
                    incrementalOffset: 0,
                    fullOffset: 0,
                    blockedReason: testCase.0
                )
            )
            try await fixture.coordinator.refresh(scope, priority: .manual)
            let requestCount = await fixture.operation.requestCount()
            let state = await fixture.coordinator.state(for: scope)
            XCTAssertEqual(requestCount, 0)
            XCTAssertEqual(state?.freshness.status, testCase.1)
        }
    }

    func testPartialCoverageSuccessRemainsPartialAndAdvancesScheduler() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()
        try await fixture.coordinator.select(scope)
        let request = try await fixture.operation.request(at: 0)

        await fixture.operation.succeed(request, with: fixture.partialCachedState(for: scope, at: 5))
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: scope)

        let state = await fixture.coordinator.state(for: scope)
        XCTAssertEqual(state?.freshness.status, .partial)
        XCTAssertEqual(state?.freshness.lastSuccessfulSyncAt, fixture.date(5))
        XCTAssertEqual(state?.schedulerState?.consecutiveTransientFailureCount, 0)
        XCTAssertEqual(state?.schedulerState?.nextIncrementalRefreshAt, fixture.date(240))
    }

    func testTransientBackoffPersistsAcrossReconstructedCoordinator() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()
        try await fixture.coordinator.refresh(scope, priority: .manual)
        let request = try await fixture.operation.request(at: 0)
        await fixture.operation.fail(
            request,
            error: AccountOrganizationRefreshFailure.failed(detail: "temporary")
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: scope)

        let storedFailedSchedule = try await fixture.scheduleStore.state(for: scope)
        let failedSchedule = try XCTUnwrap(storedFailedSchedule)
        XCTAssertEqual(failedSchedule.consecutiveTransientFailureCount, 1)
        XCTAssertEqual(failedSchedule.nextIncrementalRefreshAt, fixture.date(300))
        XCTAssertEqual(failedSchedule.nextFullReconciliationAt, fixture.date(300))

        let restartedOperation = ControlledRefreshOperation()
        let restarted = fixture.makeCoordinator(refreshOperation: restartedOperation)
        try await restarted.applicationDidBecomeActive(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        let restartedRequestCount = await restartedOperation.requestCount()
        XCTAssertEqual(restartedRequestCount, 0)

        fixture.clock.advance(by: 300)
        try await restarted.applicationDidBecomeActive(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        let resumed = try await restartedOperation.request(at: 0)
        XCTAssertEqual(resumed.priority, .fullReconciliation)
        await restartedOperation.finishAllCancelled()
    }

    func testOrphanedAttemptIsRecoveredBeforeNewRequestStarts() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()
        let orphanID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        await fixture.scheduleStore.install(
            fixture.schedule(
                scope: scope,
                incrementalOffset: 3_600,
                fullOffset: 7_200,
                activeAttemptID: orphanID,
                generation: 7,
                lastAttemptAt: fixture.date(-1)
            )
        )

        try await fixture.coordinator.applicationDidBecomeActive(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        let request = try await fixture.operation.request(at: 0)
        let storedSchedule = try await fixture.scheduleStore.state(for: scope)
        let schedule = try XCTUnwrap(storedSchedule)

        XCTAssertNotEqual(schedule.activeAttemptID, orphanID)
        XCTAssertEqual(schedule.activeAttemptID, fixture.attemptIDs.value(at: 0))
        XCTAssertEqual(schedule.generation, 8)
        XCTAssertEqual(request.priority, .activeApplication)
        let replaceAttempts = await fixture.scheduleStore.replaceAttemptCount()
        XCTAssertEqual(replaceAttempts, 1)
        await fixture.operation.finishAllCancelled()
    }

    func testCredentialRevisionResetClearsPersistedBackoffAndBlock() async throws {
        let fixture = CoordinatorFixture()
        let stale = fixture.scope(credential: "old", capability: "old")
        let current = fixture.scope(credential: "current", capability: "current")
        await fixture.scheduleStore.install(
            fixture.schedule(
                scope: stale,
                incrementalOffset: 3_600,
                fullOffset: 7_200,
                rateLimitedUntil: fixture.date(1_800),
                blockedReason: .ssoRequired,
                failureCount: 4
            )
        )

        try await fixture.coordinator.select(current)
        let request = try await fixture.operation.request(at: 0)
        let storedCurrentSchedule = try await fixture.scheduleStore.state(for: current)
        let currentSchedule = try XCTUnwrap(storedCurrentSchedule)

        XCTAssertEqual(request.synchronizationScope, current)
        XCTAssertEqual(currentSchedule.credentialRevision, current.credentialRevision)
        XCTAssertEqual(currentSchedule.capabilityRevision, current.capabilityRevision)
        XCTAssertNil(currentSchedule.blockedReason)
        XCTAssertNil(currentSchedule.rateLimitedUntil)
        XCTAssertEqual(currentSchedule.consecutiveTransientFailureCount, 0)
        await fixture.operation.finishAllCancelled()
    }

    func testExplicitCancellationClearsOnlyOwnedAttemptAndPreservesScheduleData() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()
        let priorCompletion = fixture.date(-60)
        await fixture.scheduleStore.install(
            fixture.schedule(
                scope: scope,
                incrementalOffset: 900,
                fullOffset: 3_600,
                failureCount: 2,
                lastCompletedAt: priorCompletion
            )
        )

        try await fixture.coordinator.refresh(scope, priority: .manual)
        let request = try await fixture.operation.request(at: 0)
        try await fixture.coordinator.cancelRefresh(for: fixture.accountOrganizationScope(scope))
        try await fixture.operation.awaitCancellation(of: request)
        let storedCancelledSchedule = try await fixture.scheduleStore.state(for: scope)
        let cancelled = try XCTUnwrap(storedCancelledSchedule)

        XCTAssertNil(cancelled.activeAttemptID)
        XCTAssertEqual(cancelled.lastCompletedAt, priorCompletion)
        XCTAssertEqual(cancelled.nextIncrementalRefreshAt, fixture.date(900))
        XCTAssertEqual(cancelled.nextFullReconciliationAt, fixture.date(3_600))
        XCTAssertEqual(cancelled.consecutiveTransientFailureCount, 2)
    }

    func testFullReconciliationRunsWhenItsDeadlineAloneIsDue() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()
        await fixture.scheduleStore.install(
            fixture.schedule(scope: scope, incrementalOffset: 600, fullOffset: -1)
        )

        try await fixture.coordinator.applicationDidBecomeActive(
            synchronizationScopes: [scope],
            activeAccountID: scope.accountID
        )
        let request = try await fixture.operation.request(at: 0)

        XCTAssertEqual(request.priority, .fullReconciliation)
        XCTAssertEqual(request.requestPriority, .fullReconciliation)
        await fixture.operation.succeed(
            request,
            with: fixture.completeCachedState(for: scope, at: 5)
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: scope)
        let storedCompletedSchedule = try await fixture.scheduleStore.state(for: scope)
        let completed = try XCTUnwrap(storedCompletedSchedule)
        XCTAssertEqual(completed.nextIncrementalRefreshAt, fixture.date(1_200))
        XCTAssertEqual(completed.nextFullReconciliationAt, fixture.date(86_400))
    }

    func testApplicationActivationClaimsSchedulesSelectedThenActiveThenInactive() async throws {
        let fixture = CoordinatorFixture()
        let selected = fixture.scope(account: "account-a", organization: "selected")
        let active = fixture.scope(account: "account-a", organization: "active")
        let inactive = fixture.scope(account: "account-b", organization: "inactive")
        await fixture.scheduleStore.install(
            fixture.schedule(
                scope: selected,
                incrementalOffset: 0,
                fullOffset: 0,
                blockedReason: .ssoRequired
            )
        )
        try await fixture.coordinator.select(selected)
        let selectedRequestCount = await fixture.operation.requestCount()
        XCTAssertEqual(selectedRequestCount, 0)
        await fixture.scheduleStore.install(fixture.schedule(scope: selected, incrementalOffset: 0, fullOffset: 0))
        await fixture.scheduleStore.install(fixture.schedule(scope: active, incrementalOffset: 0, fullOffset: 0))
        await fixture.scheduleStore.install(fixture.schedule(scope: inactive, incrementalOffset: 0, fullOffset: 0))

        try await fixture.coordinator.applicationDidBecomeActive(
            synchronizationScopes: [inactive, active, selected],
            activeAccountID: selected.accountID
        )

        let startedScopes = await fixture.scheduleStore.startedScopes()
        XCTAssertEqual(
            startedScopes,
            [
                fixture.accountOrganizationScope(selected),
                fixture.accountOrganizationScope(active),
                fixture.accountOrganizationScope(inactive)
            ]
        )
        await fixture.operation.finishAllCancelled()
    }

    func testStartClaimPersistenceFailureIsFailClosed() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()
        await fixture.scheduleStore.install(fixture.schedule(scope: scope, incrementalOffset: 0, fullOffset: 0))
        await fixture.scheduleStore.failNextClaim()

        do {
            try await fixture.coordinator.refresh(scope, priority: .manual)
            XCTFail("A failed durable schedule claim must be surfaced.")
        } catch {
            XCTAssertEqual(error as? TestStoreError, .persistence)
        }

        let requestCount = await fixture.operation.requestCount()
        let state = await fixture.coordinator.state(for: scope)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(state?.freshness.status, .failed)
    }

    func testScheduleCompletionCASFalseAndErrorFailClosed() async throws {
        let falseFixture = CoordinatorFixture()
        let falseScope = falseFixture.scope()
        try await falseFixture.coordinator.select(falseScope)
        let falseRequest = try await falseFixture.operation.request(at: 0)
        await falseFixture.scheduleStore.returnFalseForNextReplace()
        await falseFixture.operation.succeed(
            falseRequest,
            with: falseFixture.completeCachedState(for: falseScope, at: 2)
        )
        try await falseFixture.scheduleStore.awaitReplaceAttempt(1)
        let falseState = try await awaitNonRefreshingState(
            from: falseFixture.coordinator,
            scope: falseScope
        )
        XCTAssertEqual(falseState?.freshness.status, .failed)

        let errorFixture = CoordinatorFixture()
        let errorScope = errorFixture.scope()
        try await errorFixture.coordinator.select(errorScope)
        let errorRequest = try await errorFixture.operation.request(at: 0)
        await errorFixture.scheduleStore.failNextReplace()
        await errorFixture.operation.succeed(
            errorRequest,
            with: errorFixture.completeCachedState(for: errorScope, at: 2)
        )
        try await errorFixture.scheduleStore.awaitReplaceAttempt(1)
        let errorState = try await awaitNonRefreshingState(
            from: errorFixture.coordinator,
            scope: errorScope
        )
        XCTAssertEqual(errorState?.freshness.status, .failed)
    }

    func testCancellationOwnershipLossAbortsSupersedingRefreshWithoutRecoveringExternalAttempt() async throws {
        let fixture = CoordinatorFixture()
        let scope = fixture.scope()

        try await fixture.coordinator.select(scope)
        let originalRequest = try await fixture.operation.request(at: 0)
        let externalAttemptID = try XCTUnwrap(
            UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")
        )
        let externallyOwnedSchedule = fixture.schedule(
            scope: scope,
            incrementalOffset: 3_600,
            fullOffset: 7_200,
            activeAttemptID: externalAttemptID,
            generation: 8,
            lastAttemptAt: fixture.date(1)
        )
        await fixture.scheduleStore.loseOwnershipOnNextReplace(
            to: externallyOwnedSchedule
        )

        do {
            try await fixture.coordinator.refresh(scope, priority: .manual)
            XCTFail("A superseding refresh must abort when cancellation loses schedule ownership.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationCoordinatorError,
                .scheduleOwnershipLost
            )
        }

        try await fixture.operation.awaitCancellation(of: originalRequest)
        let requestCount = await fixture.operation.requestCount()
        let coordinatorState = await fixture.coordinator.state(for: scope)
        let persistedSchedule = await fixture.scheduleStore.state(
            for: fixture.accountOrganizationScope(scope)
        )
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(coordinatorState?.freshness.status, .failed)
        XCTAssertEqual(persistedSchedule, externallyOwnedSchedule)
        XCTAssertNotNil(persistedSchedule?.activeAttemptID)

        do {
            try await fixture.coordinator.refresh(scope, priority: .manual)
            XCTFail("A later call must not recover an attempt this process observed as externally owned.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationCoordinatorError,
                .scheduleOwnershipLost
            )
        }
        let requestCountAfterRetry = await fixture.operation.requestCount()
        let replaceAttemptsAfterRetry = await fixture.scheduleStore.replaceAttemptCount()
        let persistedAfterRetry = await fixture.scheduleStore.state(
            for: fixture.accountOrganizationScope(scope)
        )
        XCTAssertEqual(requestCountAfterRetry, 1)
        XCTAssertEqual(replaceAttemptsAfterRetry, 1)
        XCTAssertEqual(persistedAfterRetry, externallyOwnedSchedule)

        let externallyCompletedSchedule = fixture.schedule(
            scope: scope,
            incrementalOffset: 3_600,
            fullOffset: 7_200,
            generation: 8,
            lastAttemptAt: fixture.date(1),
            lastCompletedAt: fixture.date(2)
        )
        await fixture.scheduleStore.install(externallyCompletedSchedule)
        try await fixture.coordinator.refresh(scope, priority: .manual)
        let resumedRequest = try await fixture.operation.request(at: 1)
        XCTAssertEqual(resumedRequest.synchronizationScope, scope)
        await fixture.operation.finishAllCancelled()
    }

    func testDurableStateSaveFailureKeepsPreviouslyCachedStateAndFailsClosed() async throws {
        let scope = CoordinatorFixture.defaultScope
        let cached = Self.fixtureCachedState(for: scope, at: 1)
        let fixture = CoordinatorFixture(
            cachedStates: [
                scope: AccountOrganizationDurableState(cachedState: cached)
            ]
        )
        await fixture.stateStore.failNextSave()
        try await fixture.coordinator.select(scope)
        let request = try await fixture.operation.request(at: 0)
        await fixture.operation.succeed(
            request,
            with: fixture.completeCachedState(for: scope, at: 2)
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: scope)

        let finalState = await fixture.coordinator.state(for: scope)
        let schedulerAfterFailedFinalization = try await fixture.scheduleStore.state(for: scope)
        XCTAssertEqual(finalState?.freshness.status, .failed)
        XCTAssertEqual(finalState?.durableState.cachedState?.lastSuccessfulSyncAt, fixture.date(1))
        XCTAssertNotNil(schedulerAfterFailedFinalization?.activeAttemptID)
        XCTAssertNil(schedulerAfterFailedFinalization?.lastCompletedAt)
    }

    func testSuccessfulFinalizationCommitsCacheAndScheduleInOnePersistenceSnapshot() async throws {
        let scope = CoordinatorFixture.defaultScope
        let fixture = CoordinatorFixture(
            cachedStates: [
                scope: AccountOrganizationDurableState(
                    cachedState: Self.fixtureCachedState(for: scope, at: 1)
                )
            ]
        )

        try await fixture.coordinator.select(scope)
        let request = try await fixture.operation.request(at: 0)
        await fixture.operation.succeed(
            request,
            with: fixture.completeCachedState(for: scope, at: 2)
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: scope)

        let snapshot = await fixture.persistence.snapshot(for: scope)
        XCTAssertEqual(
            snapshot.durableState?.cachedState?.lastSuccessfulSyncAt,
            fixture.date(2)
        )
        XCTAssertEqual(snapshot.durableState?.freshness.status, .fresh)
        XCTAssertNil(snapshot.schedulerState?.activeAttemptID)
        XCTAssertNotNil(snapshot.schedulerState?.lastCompletedAt)
    }

    func testPostScheduleStagingFailureRollsBackSuccessfulFinalizationAtomically() async throws {
        let scope = CoordinatorFixture.defaultScope
        let fixture = CoordinatorFixture(
            cachedStates: [
                scope: AccountOrganizationDurableState(
                    cachedState: Self.fixtureCachedState(for: scope, at: 1)
                )
            ]
        )

        try await fixture.coordinator.select(scope)
        let request = try await fixture.operation.request(at: 0)
        let beforeFinalization = await fixture.persistence.snapshot(for: scope)
        await fixture.persistence.failNextFinalizationAfterScheduleWasStaged()
        await fixture.operation.succeed(
            request,
            with: fixture.completeCachedState(for: scope, at: 2)
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        let coordinatorState = try await awaitNonRefreshingState(
            from: fixture.coordinator,
            scope: scope
        )

        let afterFailure = await fixture.persistence.snapshot(for: scope)
        let finalizationAttempts = await fixture.persistence.finalizationAttemptCount()
        XCTAssertEqual(afterFailure, beforeFinalization)
        XCTAssertEqual(finalizationAttempts, 1)
        XCTAssertEqual(coordinatorState?.freshness.status, .failed)
        XCTAssertNotNil(afterFailure.schedulerState?.activeAttemptID)
        XCTAssertEqual(
            afterFailure.durableState?.cachedState?.lastSuccessfulSyncAt,
            fixture.date(1)
        )
    }

    func testPostScheduleStagingFailureRollsBackFailureProjectionAtomically() async throws {
        let scope = CoordinatorFixture.defaultScope
        let fixture = CoordinatorFixture()

        try await fixture.coordinator.select(scope)
        let request = try await fixture.operation.request(at: 0)
        let beforeFinalization = await fixture.persistence.snapshot(for: scope)
        await fixture.persistence.failNextFinalizationAfterScheduleWasStaged()
        await fixture.operation.fail(
            request,
            error: AccountOrganizationRefreshFailure.offline(detail: nil)
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        let coordinatorState = try await awaitNonRefreshingState(
            from: fixture.coordinator,
            scope: scope
        )

        let afterFailure = await fixture.persistence.snapshot(for: scope)
        let finalizationAttempts = await fixture.persistence.finalizationAttemptCount()
        XCTAssertEqual(afterFailure, beforeFinalization)
        XCTAssertEqual(finalizationAttempts, 1)
        XCTAssertEqual(coordinatorState?.freshness.status, .failed)
        XCTAssertNotNil(afterFailure.schedulerState?.activeAttemptID)
        XCTAssertNil(afterFailure.durableState)
    }

    func testGatedCacheLoadCannotStartSupersededSelection() async throws {
        let fixture = CoordinatorFixture()
        let first = fixture.scope(account: "account-a", organization: "first")
        let second = fixture.scope(account: "account-b", organization: "second")
        let gate = TestGate()
        await fixture.stateStore.pauseNextLoad(on: gate)

        let firstSelection = Task { try? await fixture.coordinator.select(first) }
        try await fixture.stateStore.awaitLoadAttempt(1)
        try await fixture.coordinator.select(second)
        let request = try await fixture.operation.request(at: 0)
        XCTAssertEqual(request.synchronizationScope, second)
        await gate.open()
        _ = await firstSelection.value

        let requestCount = await fixture.operation.requestCount()
        XCTAssertEqual(requestCount, 1)
        await fixture.operation.succeed(
            request,
            with: fixture.completeCachedState(for: second, at: 2)
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: second)
    }

    func testDelayedOlderSelectionCannotOverwriteNewestSelection() async throws {
        let fixture = CoordinatorFixture()
        let first = fixture.scope(account: "account-a", organization: "first")
        let middle = fixture.scope(account: "account-b", organization: "middle")
        let newest = fixture.scope(account: "account-c", organization: "newest")
        let cancellationGate = TestGate()

        try await fixture.coordinator.select(first)
        _ = try await fixture.operation.request(at: 0)
        await fixture.scheduleStore.pauseNextReplace(on: cancellationGate)

        let middleSelection = Task {
            try await fixture.coordinator.select(middle)
        }
        try await fixture.scheduleStore.awaitReplaceAttempt(1)

        try await fixture.coordinator.select(newest)
        let newestRequest = try await fixture.operation.request(at: 1)
        await cancellationGate.open()
        try await middleSelection.value

        let selectedAfterRace = await fixture.coordinator.selectedSynchronizationScope()
        let requestCountAfterRace = await fixture.operation.requestCount()
        let middleState = await fixture.coordinator.state(for: middle)
        XCTAssertEqual(selectedAfterRace, newest)
        XCTAssertEqual(requestCountAfterRace, 2)
        XCTAssertNil(middleState)

        await fixture.operation.succeed(
            newestRequest,
            with: fixture.completeCachedState(for: newest, at: 2)
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: newest)
    }

    func testSameOrganizationRevisionChangeNeverActivatesPriorRevisionCache() async throws {
        let oldScope = CoordinatorFixture.defaultScope
        let newScope = SynchronizationScope(
            accountID: oldScope.accountID,
            organizationID: oldScope.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-new")!,
            capabilityRevision: oldScope.capabilityRevision
        )
        let fixture = CoordinatorFixture(
            cachedStates: [
                oldScope: AccountOrganizationDurableState(
                    cachedState: Self.fixtureCachedState(for: oldScope, at: 1)
                ),
                newScope: AccountOrganizationDurableState(
                    cachedState: Self.fixtureCachedState(for: newScope, at: 2)
                )
            ]
        )

        try await fixture.coordinator.select(oldScope)
        _ = try await fixture.operation.request(at: 0)
        try await fixture.coordinator.select(newScope)
        let newRequest = try await fixture.operation.request(at: 1)

        let selectedRevision = await fixture.coordinator.selectedSynchronizationScope()
        let oldRevisionState = await fixture.coordinator.state(for: oldScope)
        let newRevisionState = await fixture.coordinator.state(for: newScope)
        XCTAssertEqual(selectedRevision, newScope)
        XCTAssertNil(oldRevisionState)
        XCTAssertEqual(
            newRevisionState?.freshness.lastSuccessfulSyncAt,
            CoordinatorFixture.initialDate.addingTimeInterval(2)
        )

        await fixture.operation.succeed(
            newRequest,
            with: fixture.completeCachedState(for: newScope, at: 3)
        )
        try await fixture.stateStore.awaitSaveAttempt(1)
        _ = try await awaitNonRefreshingState(from: fixture.coordinator, scope: newScope)
    }

    func testMismatchedPersistedCoverageIsRejectedBeforeActivationOrDispatch() async throws {
        let requestedScope = CoordinatorFixture.defaultScope
        let staleScope = SynchronizationScope(
            accountID: requestedScope.accountID,
            organizationID: requestedScope.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-stale")!,
            capabilityRevision: requestedScope.capabilityRevision
        )
        let fixture = CoordinatorFixture(
            cachedStates: [
                requestedScope: AccountOrganizationDurableState(
                    cachedState: Self.fixtureCachedState(for: staleScope, at: 1)
                )
            ]
        )

        do {
            try await fixture.coordinator.select(requestedScope)
            XCTFail("Revision-mismatched cached coverage must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationCoordinatorError,
                .invalidCachedStateScope
            )
        }

        let requestCount = await fixture.operation.requestCount()
        let state = await fixture.coordinator.state(for: requestedScope)
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(state)
    }

    func testRevisionUnboundSuccessfulEmptyCacheIsRejectedBeforeActivationOrDispatch() async throws {
        let scope = CoordinatorFixture.defaultScope
        let successfulAt = CoordinatorFixture.initialDate.addingTimeInterval(1)
        let fixture = CoordinatorFixture(
            cachedStates: [
                scope: AccountOrganizationDurableState(
                    cachedState: AccountOrganizationCachedState(
                        coverage: [],
                        lastSuccessfulSyncAt: successfulAt
                    )
                )
            ]
        )

        do {
            try await fixture.coordinator.select(scope)
            XCTFail("A successful projection without revision-qualified coverage must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationCoordinatorError,
                .invalidCachedStateScope
            )
        }

        let requestCount = await fixture.operation.requestCount()
        let coordinatorState = await fixture.coordinator.state(for: scope)
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(coordinatorState)
    }

    private static func fixtureCachedState(
        for scope: SynchronizationScope,
        at offset: TimeInterval
    ) -> AccountOrganizationCachedState {
        let timestamp = CoordinatorFixture.initialDate.addingTimeInterval(offset)
        return AccountOrganizationCachedState(
            coverage: [
                CoverageRecord(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    repositoryID: nil,
                    feature: .roleDiscovery,
                    streamID: SyncStreamID(rawValue: "revision-cache-\(scope.credentialRevision.rawValue)")!,
                    intervalStart: timestamp,
                    intervalEnd: timestamp,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    status: .complete,
                    lastSuccessfulAt: timestamp,
                    failureDetail: nil
                )
            ],
            lastSuccessfulSyncAt: timestamp
        )
    }

    private func awaitNonRefreshingState(
        from coordinator: AccountOrganizationCoordinator,
        scope: SynchronizationScope
    ) async throws -> AccountOrganizationCoordinatorState? {
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            let state = await coordinator.state(for: scope)
            if state?.phase != .refreshing {
                return state
            }
            await Task.yield()
        }
        XCTFail("The coordinator did not leave its refreshing phase after a terminal result.")
        throw CoordinatorTestAwaitError.budgetExhausted(
            "The coordinator remained refreshing."
        )
    }
}

private final class CoordinatorFixture: @unchecked Sendable {
    static let initialDate = Date(timeIntervalSinceReferenceDate: 50_000)
    static let defaultScope = SynchronizationScope(
        accountID: AccountID(rawValue: "account")!,
        organizationID: OrganizationID(rawValue: "organization")!,
        credentialRevision: CredentialRevision(rawValue: "credential")!,
        capabilityRevision: CapabilityRevision(rawValue: "capability")!
    )

    let clock: TestClock
    let attemptIDs: DeterministicUUIDSequence
    let persistence: TestPersistence
    let stateStore: TestStateStore
    let scheduleStore: TestScheduleStore
    let finalizer: TestFinalizer
    let operation: ControlledRefreshOperation
    let coordinator: AccountOrganizationCoordinator

    init(
        cachedStates: [SynchronizationScope: AccountOrganizationDurableState] = [:],
        schedules: [AccountOrganizationScope: OrganizationSchedulerState] = [:]
    ) {
        let testClock = TestClock(Self.initialDate)
        let uuidSequence = DeterministicUUIDSequence()
        let testPersistence = TestPersistence(
            durableStates: cachedStates,
            schedules: schedules
        )
        clock = testClock
        attemptIDs = uuidSequence
        persistence = testPersistence
        stateStore = TestStateStore(persistence: testPersistence)
        scheduleStore = TestScheduleStore(persistence: testPersistence)
        finalizer = TestFinalizer(
            persistence: testPersistence,
            stateStore: stateStore,
            scheduleStore: scheduleStore
        )
        operation = ControlledRefreshOperation()
        coordinator = AccountOrganizationCoordinator(
            stateStore: stateStore,
            scheduleStore: scheduleStore,
            finalizer: finalizer,
            refreshOperation: operation,
            clock: { testClock.now() },
            randomUnit: { 0 },
            makeAttemptID: { uuidSequence.next() }
        )
    }

    func makeCoordinator(
        refreshOperation: ControlledRefreshOperation? = nil,
        activateCachedState: @escaping AccountOrganizationCoordinator.CachedStateActivation = { _, _ in }
    ) -> AccountOrganizationCoordinator {
        AccountOrganizationCoordinator(
            stateStore: stateStore,
            scheduleStore: scheduleStore,
            finalizer: finalizer,
            refreshOperation: refreshOperation ?? operation,
            activateCachedState: activateCachedState,
            clock: { self.clock.now() },
            randomUnit: { 0 },
            makeAttemptID: { self.attemptIDs.next() }
        )
    }

    func scope(
        account: String = "account",
        organization: String = "organization",
        credential: String = "credential",
        capability: String = "capability"
    ) -> SynchronizationScope {
        SynchronizationScope(
            accountID: AccountID(rawValue: account)!,
            organizationID: OrganizationID(rawValue: organization)!,
            credentialRevision: CredentialRevision(rawValue: credential)!,
            capabilityRevision: CapabilityRevision(rawValue: capability)!
        )
    }

    func accountOrganizationScope(_ scope: SynchronizationScope) -> AccountOrganizationScope {
        AccountOrganizationScope(accountID: scope.accountID, organizationID: scope.organizationID)
    }

    func date(_ offset: TimeInterval) -> Date {
        Self.initialDate.addingTimeInterval(offset)
    }

    func schedule(
        scope: SynchronizationScope,
        incrementalOffset: TimeInterval,
        fullOffset: TimeInterval,
        rateLimitedUntil: Date? = nil,
        blockedReason: OrganizationRefreshBlockReason? = nil,
        failureCount: Int = 0,
        activeAttemptID: UUID? = nil,
        generation: UInt64 = 0,
        lastAttemptAt: Date? = nil,
        lastCompletedAt: Date? = nil
    ) -> OrganizationSchedulerState {
        OrganizationSchedulerState(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            nextIncrementalRefreshAt: date(incrementalOffset),
            nextFullReconciliationAt: date(fullOffset),
            rateLimitedUntil: rateLimitedUntil,
            blockedReason: blockedReason,
            consecutiveTransientFailureCount: failureCount,
            activeAttemptID: activeAttemptID,
            lastAttemptAt: lastAttemptAt,
            lastCompletedAt: lastCompletedAt,
            generation: generation,
            updatedAt: max(date(0), max(lastAttemptAt ?? date(0), lastCompletedAt ?? date(0)))
        )
    }

    static func cachedState(at referenceDate: TimeInterval) -> AccountOrganizationCachedState {
        AccountOrganizationCachedState(
            coverage: [],
            lastSuccessfulSyncAt: initialDate.addingTimeInterval(referenceDate)
        )
    }

    func completeCachedState(
        for scope: SynchronizationScope,
        at referenceDate: TimeInterval
    ) -> AccountOrganizationCachedState {
        cachedState(for: scope, at: referenceDate, status: .complete)
    }

    func partialCachedState(
        for scope: SynchronizationScope,
        at referenceDate: TimeInterval
    ) -> AccountOrganizationCachedState {
        cachedState(for: scope, at: referenceDate, status: .partial)
    }

    private func cachedState(
        for scope: SynchronizationScope,
        at referenceDate: TimeInterval,
        status: CoverageStatus
    ) -> AccountOrganizationCachedState {
        let success = date(referenceDate)
        return AccountOrganizationCachedState(
            coverage: [
                CoverageRecord(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    repositoryID: nil,
                    feature: .roleDiscovery,
                    streamID: SyncStreamID(rawValue: "role-discovery-\(scope.organizationID.rawValue)")!,
                    intervalStart: success,
                    intervalEnd: success,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    status: status,
                    lastSuccessfulAt: success,
                    failureDetail: status == .partial ? "One discovery role remains incomplete." : nil
                )
            ],
            lastSuccessfulSyncAt: success
        )
    }
}

private enum TestStoreError: Error, Equatable {
    case persistence
    case staleGeneration
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class DeterministicUUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var nextOrdinal: UInt64 = 1

    func next() -> UUID {
        lock.lock()
        let value = nextOrdinal
        nextOrdinal += 1
        lock.unlock()
        return self.value(at: value - 1)
    }

    func value(at zeroBasedIndex: UInt64) -> UUID {
        let suffix = String(format: "%012llx", zeroBasedIndex + 1)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

private actor TestGate {
    private var isOpen = false

    func wait() async throws {
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            if isOpen { return }
            await Task.yield()
        }
        throw CoordinatorTestAwaitError.budgetExhausted("A test gate remained closed.")
    }

    func open() {
        isOpen = true
    }
}

private struct TestPersistenceSnapshot: Equatable {
    let durableState: AccountOrganizationDurableState?
    let schedulerState: OrganizationSchedulerState?
}

/// One actor models the single encrypted-vault transaction boundary used by
/// production persistence. The protocol-specific fakes below only provide
/// controllable suspension and failure points before delegating mutations here.
private actor TestPersistence {
    private var durableStates: [SynchronizationScope: AccountOrganizationDurableState]
    private var savedGenerations: [SynchronizationScope: UInt64] = [:]
    private var schedules: [AccountOrganizationScope: OrganizationSchedulerState]
    private var failFinalizationAfterScheduleStaging = false
    private var finalizationAttempts = 0

    init(
        durableStates: [SynchronizationScope: AccountOrganizationDurableState],
        schedules: [AccountOrganizationScope: OrganizationSchedulerState]
    ) {
        self.durableStates = durableStates
        self.schedules = schedules
    }

    func loadDurableState(
        for scope: SynchronizationScope
    ) -> AccountOrganizationDurableState? {
        durableStates[scope]
    }

    func scheduleState(
        for scope: SynchronizationScope
    ) -> OrganizationSchedulerState? {
        let key = accountOrganizationScope(scope)
        guard let state = schedules[key] else { return nil }
        guard state.credentialRevision == scope.credentialRevision,
              state.capabilityRevision == scope.capabilityRevision
        else {
            schedules[key] = nil
            return nil
        }
        return state
    }

    func scheduleState(
        for scope: AccountOrganizationScope
    ) -> OrganizationSchedulerState? {
        schedules[scope]
    }

    func install(_ state: OrganizationSchedulerState) {
        schedules[accountOrganizationScope(state)] = state
    }

    func createIfAbsent(
        _ state: OrganizationSchedulerState
    ) -> OrganizationSchedulerState {
        let key = accountOrganizationScope(state)
        if let existing = schedules[key],
           existing.credentialRevision == state.credentialRevision,
           existing.capabilityRevision == state.capabilityRevision {
            return existing
        }
        schedules[key] = state
        return state
    }

    func claim(
        _ state: OrganizationSchedulerState,
        replacingIdleGeneration expectedGeneration: UInt64
    ) throws -> Bool {
        guard state.activeAttemptID != nil,
              state.generation == expectedGeneration + 1
        else {
            throw TestStoreError.staleGeneration
        }
        let key = accountOrganizationScope(state)
        guard let existing = schedules[key],
              existing.credentialRevision == state.credentialRevision,
              existing.capabilityRevision == state.capabilityRevision,
              existing.generation == expectedGeneration,
              existing.activeAttemptID == nil
        else {
            return false
        }
        schedules[key] = state
        return true
    }

    func replace(
        _ state: OrganizationSchedulerState,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) throws -> Bool {
        guard state.generation == expectedGeneration else {
            throw TestStoreError.staleGeneration
        }
        let key = accountOrganizationScope(state)
        guard let existing = schedules[key],
              existing.activeAttemptID == expectedAttemptID,
              existing.generation == expectedGeneration
        else {
            return false
        }
        schedules[key] = state
        return true
    }

    func finalize(
        _ state: AccountOrganizationDurableState,
        schedule: OrganizationSchedulerState,
        for scope: SynchronizationScope,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) throws -> Bool {
        finalizationAttempts += 1
        let key = accountOrganizationScope(scope)
        guard schedule.accountID == scope.accountID,
              schedule.organizationID == scope.organizationID,
              schedule.credentialRevision == scope.credentialRevision,
              schedule.capabilityRevision == scope.capabilityRevision,
              schedule.generation == expectedGeneration,
              let existing = schedules[key],
              existing.activeAttemptID == expectedAttemptID,
              existing.generation == expectedGeneration,
              schedule.generation >= (savedGenerations[scope] ?? 0)
        else {
            return false
        }

        var proposedSchedules = schedules
        proposedSchedules[key] = schedule
        if failFinalizationAfterScheduleStaging {
            failFinalizationAfterScheduleStaging = false
            throw TestStoreError.persistence
        }

        var proposedDurableStates = durableStates
        proposedDurableStates[scope] = state
        var proposedSavedGenerations = savedGenerations
        proposedSavedGenerations[scope] = schedule.generation

        schedules = proposedSchedules
        durableStates = proposedDurableStates
        savedGenerations = proposedSavedGenerations
        return true
    }

    func snapshot(for scope: SynchronizationScope) -> TestPersistenceSnapshot {
        TestPersistenceSnapshot(
            durableState: durableStates[scope],
            schedulerState: schedules[accountOrganizationScope(scope)]
        )
    }

    func failNextFinalizationAfterScheduleWasStaged() {
        failFinalizationAfterScheduleStaging = true
    }

    func finalizationAttemptCount() -> Int {
        finalizationAttempts
    }

    private func accountOrganizationScope(
        _ scope: SynchronizationScope
    ) -> AccountOrganizationScope {
        AccountOrganizationScope(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )
    }

    private func accountOrganizationScope(
        _ state: OrganizationSchedulerState
    ) -> AccountOrganizationScope {
        AccountOrganizationScope(
            accountID: state.accountID,
            organizationID: state.organizationID
        )
    }
}

private actor TestStateStore: AccountOrganizationCachedStateStoring {
    private let persistence: TestPersistence
    private var saveAttemptCount = 0
    private var loadAttemptCount = 0
    private var nextSaveError: TestStoreError?
    private var nextLoadGate: TestGate?

    init(persistence: TestPersistence) {
        self.persistence = persistence
    }

    func loadState(for scope: SynchronizationScope) async throws -> AccountOrganizationDurableState? {
        loadAttemptCount += 1
        let gate = nextLoadGate
        nextLoadGate = nil
        try await gate?.wait()
        return await persistence.loadDurableState(for: scope)
    }

    func prepareSave(
        for scope: SynchronizationScope,
        schedulerGeneration: UInt64
    ) async throws -> Bool {
        saveAttemptCount += 1
        if let error = nextSaveError {
            nextSaveError = nil
            throw error
        }
        return true
    }

    func state(for scope: SynchronizationScope) async -> AccountOrganizationDurableState? {
        await persistence.loadDurableState(for: scope)
    }

    func failNextSave() {
        nextSaveError = .persistence
    }

    func pauseNextLoad(on gate: TestGate) {
        nextLoadGate = gate
    }

    func awaitSaveAttempt(_ number: Int) async throws {
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            if saveAttemptCount >= number { return }
            await Task.yield()
        }
        throw CoordinatorTestAwaitError.budgetExhausted("A durable-state save was not attempted.")
    }

    func awaitLoadAttempt(_ number: Int) async throws {
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            if loadAttemptCount >= number { return }
            await Task.yield()
        }
        throw CoordinatorTestAwaitError.budgetExhausted("A durable-state load was not attempted.")
    }
}

private actor TestFinalizer: AccountOrganizationRefreshFinalizing {
    private let persistence: TestPersistence
    private let stateStore: TestStateStore
    private let scheduleStore: TestScheduleStore

    init(
        persistence: TestPersistence,
        stateStore: TestStateStore,
        scheduleStore: TestScheduleStore
    ) {
        self.persistence = persistence
        self.stateStore = stateStore
        self.scheduleStore = scheduleStore
    }

    func finalize(
        _ state: AccountOrganizationDurableState,
        schedule: OrganizationSchedulerState,
        for scope: SynchronizationScope,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) async throws -> Bool {
        guard try await stateStore.prepareSave(
            for: scope,
            schedulerGeneration: schedule.generation
        ) else {
            return false
        }
        guard try await scheduleStore.prepareFinalizationReplacement(for: schedule) else {
            return false
        }
        return try await persistence.finalize(
            state,
            schedule: schedule,
            for: scope,
            ifOwnedBy: expectedAttemptID,
            generation: expectedGeneration
        )
    }
}

private actor TestScheduleStore: OrganizationSchedulerStateStoring {
    private let persistence: TestPersistence
    private var started: [AccountOrganizationScope] = []
    private var replaceAttempts = 0
    private var nextClaimError: TestStoreError?
    private var nextReplaceError: TestStoreError?
    private var nextReplaceReturnsFalse = false
    private var nextExternallyOwnedState: OrganizationSchedulerState?
    private var nextReplaceGate: TestGate?

    init(persistence: TestPersistence) {
        self.persistence = persistence
    }

    func state(for scope: SynchronizationScope) async throws -> OrganizationSchedulerState? {
        await persistence.scheduleState(for: scope)
    }

    func state(for scope: AccountOrganizationScope) async -> OrganizationSchedulerState? {
        await persistence.scheduleState(for: scope)
    }

    func install(_ state: OrganizationSchedulerState) async {
        await persistence.install(state)
    }

    func createIfAbsent(
        _ state: OrganizationSchedulerState
    ) async throws -> OrganizationSchedulerState {
        await persistence.createIfAbsent(state)
    }

    func claim(
        _ state: OrganizationSchedulerState,
        replacingIdleGeneration expectedGeneration: UInt64
    ) async throws -> Bool {
        if let error = nextClaimError {
            nextClaimError = nil
            throw error
        }
        let claimed = try await persistence.claim(
            state,
            replacingIdleGeneration: expectedGeneration
        )
        if claimed {
            started.append(accountOrganizationScope(state))
        }
        return claimed
    }

    func replace(
        _ state: OrganizationSchedulerState,
        ifOwnedBy expectedAttemptID: UUID,
        generation expectedGeneration: UInt64
    ) async throws -> Bool {
        guard try await prepareReplacement(for: state) else {
            return false
        }
        return try await persistence.replace(
            state,
            ifOwnedBy: expectedAttemptID,
            generation: expectedGeneration
        )
    }

    func prepareFinalizationReplacement(
        for state: OrganizationSchedulerState
    ) async throws -> Bool {
        try await prepareReplacement(for: state)
    }

    func startedScopes() -> [AccountOrganizationScope] {
        started
    }

    func replaceAttemptCount() -> Int {
        replaceAttempts
    }

    func failNextClaim() {
        nextClaimError = .persistence
    }

    func failNextReplace() {
        nextReplaceError = .persistence
    }

    func returnFalseForNextReplace() {
        nextReplaceReturnsFalse = true
    }

    func loseOwnershipOnNextReplace(to state: OrganizationSchedulerState) {
        nextExternallyOwnedState = state
    }

    func pauseNextReplace(on gate: TestGate) {
        nextReplaceGate = gate
    }

    func awaitReplaceAttempt(_ number: Int) async throws {
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            if replaceAttempts >= number { return }
            await Task.yield()
        }
        throw CoordinatorTestAwaitError.budgetExhausted("A scheduler replacement was not attempted.")
    }

    private func prepareReplacement(
        for state: OrganizationSchedulerState
    ) async throws -> Bool {
        replaceAttempts += 1
        let replaceGate = nextReplaceGate
        nextReplaceGate = nil
        try await replaceGate?.wait()
        if let error = nextReplaceError {
            nextReplaceError = nil
            throw error
        }
        if let externallyOwnedState = nextExternallyOwnedState {
            nextExternallyOwnedState = nil
            await persistence.install(externallyOwnedState)
            return false
        }
        if nextReplaceReturnsFalse {
            nextReplaceReturnsFalse = false
            return false
        }
        return true
    }

    private func accountOrganizationScope(_ scope: SynchronizationScope) -> AccountOrganizationScope {
        AccountOrganizationScope(accountID: scope.accountID, organizationID: scope.organizationID)
    }

    private func accountOrganizationScope(
        _ state: OrganizationSchedulerState
    ) -> AccountOrganizationScope {
        AccountOrganizationScope(
            accountID: state.accountID,
            organizationID: state.organizationID
        )
    }
}

private actor ControlledRefreshOperation: AccountOrganizationRefreshOperating {
    private struct OperationKey: Hashable {
        let scope: AccountOrganizationScope
        let token: AccountOrganizationRequestToken
    }

    private var requests: [AccountOrganizationRefreshRequest] = []
    private var resultContinuations: [OperationKey: CheckedContinuation<AccountOrganizationCachedState, Error>] = [:]
    private var terminalResults: [OperationKey: Result<AccountOrganizationCachedState, Error>] = [:]
    private var completedRequests: Set<OperationKey> = []
    private var cancelledRequests: Set<OperationKey> = []
    private var ignoredCancellationRequests: Set<OperationKey> = []
    private var returnedRequests: Set<OperationKey> = []
    private var onRefresh: (@Sendable (AccountOrganizationRefreshRequest) async -> Void)?

    func refresh(_ request: AccountOrganizationRefreshRequest) async throws -> AccountOrganizationCachedState {
        let operationKey = key(for: request)
        await onRefresh?(request)
        do {
            let state = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let result = terminalResults.removeValue(forKey: operationKey) {
                        continuation.resume(with: result)
                    } else {
                        resultContinuations[operationKey] = continuation
                    }
                    publish(request)
                }
            } onCancel: {
                Task { await self.recordCancellation(of: request) }
            }
            recordReturn(of: request)
            return state
        } catch {
            recordReturn(of: request)
            throw error
        }
    }

    private func publish(_ request: AccountOrganizationRefreshRequest) {
        requests.append(request)
    }

    func request(at ordinal: Int) async throws -> AccountOrganizationRefreshRequest {
        precondition(ordinal >= 0, "A request ordinal cannot be negative.")
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            if requests.indices.contains(ordinal) {
                return requests[ordinal]
            }
            await Task.yield()
        }
        throw CoordinatorTestAwaitError.budgetExhausted("A refresh request was not published.")
    }

    func requestCount() -> Int {
        requests.count
    }

    func setOnRefresh(_ action: @escaping @Sendable (AccountOrganizationRefreshRequest) async -> Void) {
        onRefresh = action
    }

    func ignoreCancellation(for request: AccountOrganizationRefreshRequest) {
        ignoredCancellationRequests.insert(key(for: request))
    }

    func awaitCancellation(of request: AccountOrganizationRefreshRequest) async throws {
        let operationKey = key(for: request)
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            if cancelledRequests.contains(operationKey) { return }
            await Task.yield()
        }
        throw CoordinatorTestAwaitError.budgetExhausted("A refresh request was not cancelled.")
    }

    func awaitReturn(of request: AccountOrganizationRefreshRequest) async throws {
        let operationKey = key(for: request)
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            if returnedRequests.contains(operationKey) { return }
            await Task.yield()
        }
        throw CoordinatorTestAwaitError.budgetExhausted("A refresh request did not return.")
    }

    func succeed(_ request: AccountOrganizationRefreshRequest, with state: AccountOrganizationCachedState) {
        resolve(request: request, result: .success(state))
    }

    func fail(_ request: AccountOrganizationRefreshRequest, error: Error) {
        resolve(request: request, result: .failure(error))
    }

    func finishAllCancelled() {
        for request in requests {
            recordCancellation(of: request)
        }
    }

    private func recordCancellation(of request: AccountOrganizationRefreshRequest) {
        let operationKey = key(for: request)
        cancelledRequests.insert(operationKey)
        guard !ignoredCancellationRequests.contains(operationKey) else { return }
        resolve(request: request, result: .failure(CancellationError()))
    }

    private func recordReturn(of request: AccountOrganizationRefreshRequest) {
        let operationKey = key(for: request)
        returnedRequests.insert(operationKey)
    }

    private func resolve(
        request: AccountOrganizationRefreshRequest,
        result: Result<AccountOrganizationCachedState, Error>
    ) {
        let operationKey = key(for: request)
        guard completedRequests.insert(operationKey).inserted else { return }
        if let continuation = resultContinuations.removeValue(forKey: operationKey) {
            continuation.resume(with: result)
        } else {
            terminalResults[operationKey] = result
        }
    }

    private func key(for request: AccountOrganizationRefreshRequest) -> OperationKey {
        OperationKey(scope: request.scope, token: request.token)
    }
}

private actor EventLedger {
    enum Event: Equatable {
        case cachedActivated
        case refreshStarted
    }

    private var events: [Event] = []

    func append(_ event: Event) {
        events.append(event)
    }

    func values() -> [Event] {
        events
    }
}
