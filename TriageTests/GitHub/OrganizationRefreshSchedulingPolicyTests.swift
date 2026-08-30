import XCTest
@testable import Triage

final class OrganizationRefreshSchedulingPolicyTests: XCTestCase {
    private let policy = OrganizationRefreshSchedulingPolicy()
    private let now = Date(timeIntervalSinceReferenceDate: 50_000)

    func testInitialAndRevisionChangedStatesAreImmediatelyDueAndClearOldControlState() {
        let oldScope = makeScope(credential: "old", capability: "old")
        let old = makeState(
            scope: oldScope,
            incrementalOffset: 3_600,
            fullOffset: 7_200,
            rateLimitedOffset: 1_800,
            blockedReason: .ssoRequired,
            failureCount: 4,
            generation: 7
        )
        let currentScope = makeScope(credential: "current", capability: "current")

        let reconciled = policy.state(for: currentScope, reconciling: old, at: now)

        XCTAssertEqual(reconciled, policy.initialState(for: currentScope, at: now))
        XCTAssertEqual(
            policy.eligibility(of: reconciled, for: .activeApplication, at: now),
            .eligible
        )
    }

    func testSelectedAndManualBypassCadenceButNeverRateLimitOrAccessBlock() {
        let future = makeState(incrementalOffset: 3_600, fullOffset: 7_200)
        XCTAssertEqual(
            policy.eligibility(of: future, for: .selectedOrganization, at: now),
            .eligible
        )
        XCTAssertEqual(
            policy.eligibility(of: future, for: .manual, at: now),
            .eligible
        )
        XCTAssertEqual(
            policy.eligibility(of: future, for: .activeApplication, at: now),
            .notDue(until: now.addingTimeInterval(3_600))
        )

        let limited = makeState(
            incrementalOffset: 3_600,
            fullOffset: 7_200,
            rateLimitedOffset: 900
        )
        XCTAssertEqual(
            policy.eligibility(of: limited, for: .manual, at: now),
            .rateLimited(until: now.addingTimeInterval(900))
        )
        let blocked = makeState(
            incrementalOffset: 0,
            fullOffset: 0,
            blockedReason: .approvalRequired
        )
        XCTAssertEqual(
            policy.eligibility(of: blocked, for: .selectedOrganization, at: now),
            .blocked(reason: .approvalRequired)
        )
    }

    func testFullReconciliationWaitsForBothFullDeadlineAndTransientIncrementalFloor() {
        let state = makeState(incrementalOffset: 600, fullOffset: -1)

        XCTAssertEqual(
            policy.eligibility(of: state, for: .fullReconciliation, at: now),
            .notDue(until: now.addingTimeInterval(600))
        )
        XCTAssertEqual(
            policy.eligibility(
                of: state,
                for: .fullReconciliation,
                at: now.addingTimeInterval(600)
            ),
            .eligible
        )
    }

    func testStartRecordsOwnedAttemptAndMonotonicGenerationWithoutWrapping() throws {
        let attemptID = UUID()
        let state = makeState(incrementalOffset: 0, fullOffset: 0, generation: 41)
        let decision = policy.start(
            state,
            trigger: .activeApplication,
            attemptID: attemptID,
            at: now
        )
        guard case let .started(started) = decision else {
            return XCTFail("A due schedule should start.")
        }
        XCTAssertEqual(started.activeAttemptID, attemptID)
        XCTAssertEqual(started.lastAttemptAt, now)
        XCTAssertEqual(started.generation, 42)

        let exhausted = makeState(
            incrementalOffset: 0,
            fullOffset: 0,
            generation: OrganizationRefreshSchedulingPolicy.maximumGeneration
        )
        XCTAssertEqual(
            policy.start(
                exhausted,
                trigger: .manual,
                attemptID: UUID(),
                at: now
            ),
            .generationExhausted
        )
    }

    func testSuccessfulCompletionResetsBackoffAndUsesTriggerCadence() throws {
        let attemptID = UUID()
        let started = try startedState(
            makeState(
                incrementalOffset: 0,
                fullOffset: 3_600,
                rateLimitedOffset: -1,
                failureCount: 3
            ),
            trigger: .selectedOrganization,
            attemptID: attemptID
        )

        let completed = try XCTUnwrap(
            policy.finish(
                started,
                ownedBy: attemptID,
                generation: started.generation,
                trigger: .selectedOrganization,
                outcome: .completed,
                at: now.addingTimeInterval(10),
                randomUnit: 0.5
            )
        )

        XCTAssertNil(completed.activeAttemptID)
        XCTAssertNil(completed.rateLimitedUntil)
        XCTAssertNil(completed.blockedReason)
        XCTAssertEqual(completed.consecutiveTransientFailureCount, 0)
        XCTAssertEqual(completed.lastCompletedAt, now.addingTimeInterval(10))
        XCTAssertEqual(completed.nextIncrementalRefreshAt, now.addingTimeInterval(280))
        XCTAssertEqual(completed.nextFullReconciliationAt, now.addingTimeInterval(3_600))
    }

    func testFullCompletionAdvancesBothDeadlinesWithBoundedJitter() throws {
        let attemptID = UUID()
        let started = try startedState(
            makeState(incrementalOffset: 0, fullOffset: 0),
            trigger: .fullReconciliation,
            attemptID: attemptID
        )
        let completedAt = now.addingTimeInterval(5)
        let completed = try XCTUnwrap(
            policy.finish(
                started,
                ownedBy: attemptID,
                generation: started.generation,
                trigger: .fullReconciliation,
                outcome: .completed,
                at: completedAt,
                randomUnit: 1
            )
        )

        XCTAssertEqual(
            completed.nextIncrementalRefreshAt,
            completedAt.addingTimeInterval(25 * 60)
        )
        XCTAssertEqual(
            completed.nextFullReconciliationAt,
            completedAt.addingTimeInterval(25 * 60 * 60)
        )
    }

    func testTransientBackoffProgressionIsDeterministicBoundedAndCapped() throws {
        XCTAssertEqual(policy.transientBackoffInterval(failureCount: 1, randomUnit: 0), 300)
        XCTAssertEqual(policy.transientBackoffInterval(failureCount: 1, randomUnit: 1), 360)
        XCTAssertEqual(policy.transientBackoffInterval(failureCount: 2, randomUnit: 1), 660)
        XCTAssertEqual(policy.transientBackoffInterval(failureCount: 4, randomUnit: 1), 2_460)
        XCTAssertEqual(policy.transientBackoffInterval(failureCount: 5, randomUnit: 1), 3_600)
        XCTAssertEqual(policy.transientBackoffInterval(failureCount: 20, randomUnit: 1), 3_600)

        let attemptID = UUID()
        let started = try startedState(
            makeState(incrementalOffset: 0, fullOffset: 0, failureCount: 19),
            trigger: .manual,
            attemptID: attemptID
        )
        let failed = try XCTUnwrap(
            policy.finish(
                started,
                ownedBy: attemptID,
                generation: started.generation,
                trigger: .manual,
                outcome: .transientFailure,
                at: now,
                randomUnit: 1
            )
        )
        XCTAssertEqual(failed.consecutiveTransientFailureCount, 20)
        XCTAssertEqual(failed.nextIncrementalRefreshAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(failed.lastCompletedAt, now)
    }

    func testRateLimitUsesConservativeMaximumOfRetryAndTransientBackoff() throws {
        let firstAttemptID = UUID()
        let first = try startedState(
            makeState(incrementalOffset: 0, fullOffset: 0),
            trigger: .manual,
            attemptID: firstAttemptID
        )
        let remoteRetry = now.addingTimeInterval(1_800)
        let limited = try XCTUnwrap(
            policy.finish(
                first,
                ownedBy: firstAttemptID,
                generation: first.generation,
                trigger: .manual,
                outcome: .rateLimited(retryAt: remoteRetry),
                at: now,
                randomUnit: 0
            )
        )
        XCTAssertEqual(limited.rateLimitedUntil, remoteRetry)
        XCTAssertEqual(limited.nextIncrementalRefreshAt, remoteRetry)
        XCTAssertEqual(
            policy.eligibility(of: limited, for: .manual, at: now),
            .rateLimited(until: remoteRetry)
        )

        let secondAttemptID = UUID()
        let second = try startedState(
            makeState(incrementalOffset: 0, fullOffset: 0),
            trigger: .manual,
            attemptID: secondAttemptID
        )
        let conservative = try XCTUnwrap(
            policy.finish(
                second,
                ownedBy: secondAttemptID,
                generation: second.generation,
                trigger: .manual,
                outcome: .rateLimited(retryAt: now.addingTimeInterval(60)),
                at: now,
                randomUnit: 0
            )
        )
        XCTAssertEqual(conservative.rateLimitedUntil, now.addingTimeInterval(300))
    }

    func testAccessBlockStopsAllTriggersUntilExplicitRecovery() throws {
        let attemptID = UUID()
        let started = try startedState(
            makeState(incrementalOffset: 0, fullOffset: 0, failureCount: 2),
            trigger: .manual,
            attemptID: attemptID
        )
        let blocked = try XCTUnwrap(
            policy.finish(
                started,
                ownedBy: attemptID,
                generation: started.generation,
                trigger: .manual,
                outcome: .blocked(reason: .authenticationRequired),
                at: now,
                randomUnit: 0
            )
        )
        XCTAssertEqual(blocked.blockedReason, .authenticationRequired)
        XCTAssertEqual(blocked.consecutiveTransientFailureCount, 2)
        XCTAssertEqual(
            policy.eligibility(of: blocked, for: .manual, at: now),
            .blocked(reason: .authenticationRequired)
        )

        let recovered = policy.clearBlockAndMakeDue(
            in: blocked,
            at: now.addingTimeInterval(60)
        )
        XCTAssertNil(recovered.blockedReason)
        XCTAssertNil(recovered.rateLimitedUntil)
        XCTAssertEqual(recovered.consecutiveTransientFailureCount, 0)
        XCTAssertEqual(
            policy.eligibility(
                of: recovered,
                for: .activeApplication,
                at: now.addingTimeInterval(60)
            ),
            .eligible
        )
    }

    func testCancellationAndRestartClearOnlyOwnedAttemptWithoutRecordingCompletion() throws {
        let attemptID = UUID()
        let state = makeState(
            incrementalOffset: 900,
            fullOffset: 3_600,
            failureCount: 2,
            lastCompletedAt: now.addingTimeInterval(-60)
        )
        let started = try startedState(
            state,
            trigger: .manual,
            attemptID: attemptID
        )
        XCTAssertNil(
            policy.cancel(
                started,
                ownedBy: UUID(),
                generation: started.generation,
                at: now.addingTimeInterval(5)
            )
        )
        XCTAssertNil(
            policy.cancel(
                started,
                ownedBy: attemptID,
                generation: started.generation - 1,
                at: now.addingTimeInterval(5)
            )
        )
        let cancelled = try XCTUnwrap(
            policy.cancel(
                started,
                ownedBy: attemptID,
                generation: started.generation,
                at: now.addingTimeInterval(5)
            )
        )
        XCTAssertNil(cancelled.activeAttemptID)
        XCTAssertEqual(cancelled.lastAttemptAt, now)
        XCTAssertEqual(cancelled.lastCompletedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(cancelled.nextIncrementalRefreshAt, state.nextIncrementalRefreshAt)
        XCTAssertEqual(cancelled.consecutiveTransientFailureCount, 2)

        let interrupted = policy.recoverInterruptedAttempt(
            in: started,
            at: now.addingTimeInterval(10)
        )
        XCTAssertNil(interrupted.activeAttemptID)
        XCTAssertEqual(interrupted.lastCompletedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(interrupted.nextIncrementalRefreshAt, now.addingTimeInterval(10))
    }

    func testStaleCompletionCannotMutateNewAttemptAndClockRollbackIsClamped() throws {
        let attemptID = UUID()
        let future = now.addingTimeInterval(100)
        let state = makeState(
            incrementalOffset: 0,
            fullOffset: 0,
            updatedAt: future
        )
        let started = try startedState(
            state,
            trigger: .manual,
            attemptID: attemptID,
            at: now
        )
        XCTAssertEqual(started.lastAttemptAt, future)
        XCTAssertNil(
            policy.finish(
                started,
                ownedBy: UUID(),
                generation: started.generation,
                trigger: .manual,
                outcome: .completed,
                at: now,
                randomUnit: 0
            )
        )
        XCTAssertNil(
            policy.finish(
                started,
                ownedBy: attemptID,
                generation: started.generation - 1,
                trigger: .manual,
                outcome: .completed,
                at: now,
                randomUnit: 0
            )
        )
        let completed = try XCTUnwrap(
            policy.finish(
                started,
                ownedBy: attemptID,
                generation: started.generation,
                trigger: .manual,
                outcome: .completed,
                at: now,
                randomUnit: 0
            )
        )
        XCTAssertEqual(completed.lastCompletedAt, future)
        XCTAssertEqual(completed.updatedAt, future)
    }

    private func startedState(
        _ state: OrganizationSchedulerState,
        trigger: OrganizationRefreshScheduleTrigger,
        attemptID: UUID,
        at date: Date? = nil
    ) throws -> OrganizationSchedulerState {
        guard case let .started(started) = policy.start(
            state,
            trigger: trigger,
            attemptID: attemptID,
            at: date ?? now
        ) else {
            throw TestFailure.notStarted
        }
        return started
    }

    private func makeScope(
        credential: String = "credential",
        capability: String = "capability"
    ) -> SynchronizationScope {
        SynchronizationScope(
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "organization")!,
            credentialRevision: CredentialRevision(rawValue: credential)!,
            capabilityRevision: CapabilityRevision(rawValue: capability)!
        )
    }

    private func makeState(
        scope: SynchronizationScope? = nil,
        incrementalOffset: TimeInterval,
        fullOffset: TimeInterval,
        rateLimitedOffset: TimeInterval? = nil,
        blockedReason: OrganizationRefreshBlockReason? = nil,
        failureCount: Int = 0,
        generation: UInt64 = 0,
        lastCompletedAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> OrganizationSchedulerState {
        let scope = scope ?? makeScope()
        return OrganizationSchedulerState(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            nextIncrementalRefreshAt: now.addingTimeInterval(incrementalOffset),
            nextFullReconciliationAt: now.addingTimeInterval(fullOffset),
            rateLimitedUntil: rateLimitedOffset.map(now.addingTimeInterval),
            blockedReason: blockedReason,
            consecutiveTransientFailureCount: failureCount,
            activeAttemptID: nil,
            lastAttemptAt: nil,
            lastCompletedAt: lastCompletedAt,
            generation: generation,
            updatedAt: updatedAt ?? now
        )
    }
}

private enum TestFailure: Error {
    case notStarted
}
