import Foundation

enum SynchronizationReconciliationIntent: Equatable, Sendable {
    case incremental
    case fullReconciliation
}

enum OrganizationRefreshScheduleTrigger: Equatable, Sendable {
    case selectedOrganization
    case manual
    case activeApplication
    case inactiveAccount
    case fullReconciliation

    var bypassesCadence: Bool {
        switch self {
        case .selectedOrganization, .manual:
            true
        case .activeApplication, .inactiveAccount, .fullReconciliation:
            false
        }
    }

    var performsFullReconciliation: Bool {
        self == .fullReconciliation
    }

    var reconciliationIntent: SynchronizationReconciliationIntent {
        performsFullReconciliation ? .fullReconciliation : .incremental
    }
}

enum OrganizationRefreshScheduleEligibility: Equatable, Sendable {
    case eligible
    case inFlight(attemptID: UUID)
    case blocked(reason: OrganizationRefreshBlockReason)
    case rateLimited(until: Date)
    case notDue(until: Date)
}

enum OrganizationRefreshScheduleStartDecision: Equatable, Sendable {
    case started(OrganizationSchedulerState)
    case deferred(OrganizationRefreshScheduleEligibility)
    case generationExhausted
}

enum OrganizationRefreshAttemptOutcome: Equatable, Sendable {
    case completed
    case unavailable
    case transientFailure
    case rateLimited(retryAt: Date?)
    case blocked(reason: OrganizationRefreshBlockReason)
}

struct OrganizationRefreshSchedulingPolicy: Sendable {
    static let maximumGeneration = UInt64(Int64.max)
    static let maximumTransientFailureCount = 20

    let selectedCadence: RefreshCadence
    let inactiveCadence: RefreshCadence
    let fullReconciliationCadence: RefreshCadence
    let transientBackoffBase: TimeInterval
    let transientBackoffMaximum: TimeInterval
    let transientBackoffMaximumJitter: TimeInterval

    init(
        selectedCadence: RefreshCadence = .init(),
        inactiveCadence: RefreshCadence = .inactiveAccount,
        fullReconciliationCadence: RefreshCadence = .dailyFullReconciliation,
        transientBackoffBase: TimeInterval = 5 * 60,
        transientBackoffMaximum: TimeInterval = 60 * 60,
        transientBackoffMaximumJitter: TimeInterval = 60
    ) {
        precondition(transientBackoffBase > 0, "Transient backoff must be positive.")
        precondition(
            transientBackoffMaximum >= transientBackoffBase,
            "Transient backoff maximum cannot be below its base."
        )
        precondition(
            transientBackoffMaximumJitter >= 0,
            "Transient backoff jitter cannot be negative."
        )
        self.selectedCadence = selectedCadence
        self.inactiveCadence = inactiveCadence
        self.fullReconciliationCadence = fullReconciliationCadence
        self.transientBackoffBase = transientBackoffBase
        self.transientBackoffMaximum = transientBackoffMaximum
        self.transientBackoffMaximumJitter = transientBackoffMaximumJitter
    }

    func initialState(for scope: SynchronizationScope, at date: Date) -> OrganizationSchedulerState {
        OrganizationSchedulerState(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            nextIncrementalRefreshAt: date,
            nextFullReconciliationAt: date,
            rateLimitedUntil: nil,
            blockedReason: nil,
            consecutiveTransientFailureCount: 0,
            activeAttemptID: nil,
            lastAttemptAt: nil,
            lastCompletedAt: nil,
            generation: 0,
            updatedAt: date
        )
    }

    func state(
        for scope: SynchronizationScope,
        reconciling existing: OrganizationSchedulerState?,
        at date: Date
    ) -> OrganizationSchedulerState {
        guard let existing,
              existing.accountID == scope.accountID,
              existing.organizationID == scope.organizationID,
              existing.credentialRevision == scope.credentialRevision,
              existing.capabilityRevision == scope.capabilityRevision
        else {
            return initialState(for: scope, at: date)
        }
        return existing
    }

    func eligibility(
        of state: OrganizationSchedulerState,
        for trigger: OrganizationRefreshScheduleTrigger,
        at date: Date
    ) -> OrganizationRefreshScheduleEligibility {
        if let activeAttemptID = state.activeAttemptID {
            return .inFlight(attemptID: activeAttemptID)
        }
        if let blockedReason = state.blockedReason {
            return .blocked(reason: blockedReason)
        }
        if let rateLimitedUntil = state.rateLimitedUntil, rateLimitedUntil > date {
            return .rateLimited(until: rateLimitedUntil)
        }
        if trigger.bypassesCadence {
            return .eligible
        }
        let deadline: Date
        if trigger.performsFullReconciliation {
            deadline = state.nextFullReconciliationAt
        } else {
            deadline = state.nextIncrementalRefreshAt
        }
        guard deadline <= date else {
            return .notDue(until: deadline)
        }
        return .eligible
    }

    func start(
        _ state: OrganizationSchedulerState,
        trigger: OrganizationRefreshScheduleTrigger,
        attemptID: UUID,
        at date: Date
    ) -> OrganizationRefreshScheduleStartDecision {
        let eligibility = eligibility(of: state, for: trigger, at: date)
        guard eligibility == .eligible else {
            return .deferred(eligibility)
        }
        guard state.generation < Self.maximumGeneration else {
            return .generationExhausted
        }
        let eventDate = monotonicDate(date, for: state)
        return .started(
            replacing(
                state,
                activeAttemptID: attemptID,
                lastAttemptAt: eventDate,
                generation: state.generation + 1,
                updatedAt: eventDate
            )
        )
    }

    func finish(
        _ state: OrganizationSchedulerState,
        ownedBy attemptID: UUID,
        generation expectedGeneration: UInt64,
        trigger: OrganizationRefreshScheduleTrigger,
        outcome: OrganizationRefreshAttemptOutcome,
        at date: Date,
        randomUnit: Double
    ) -> OrganizationSchedulerState? {
        guard state.activeAttemptID == attemptID,
              state.generation == expectedGeneration
        else {
            return nil
        }
        let eventDate = monotonicDate(date, for: state)
        var nextIncrementalRefreshAt = state.nextIncrementalRefreshAt
        var nextFullReconciliationAt = state.nextFullReconciliationAt
        var rateLimitedUntil: Date?
        var blockedReason: OrganizationRefreshBlockReason?
        var failureCount = state.consecutiveTransientFailureCount

        switch outcome {
        case .completed:
            failureCount = 0
            nextIncrementalRefreshAt = eventDate.addingTimeInterval(
                incrementalCadence(for: trigger).nextInterval(randomUnit: randomUnit)
            )
            if trigger.performsFullReconciliation {
                nextFullReconciliationAt = eventDate.addingTimeInterval(
                    fullReconciliationCadence.nextInterval(randomUnit: randomUnit)
                )
            }
        case .unavailable:
            failureCount = 0
            let unavailableDeadline = eventDate.addingTimeInterval(
                inactiveCadence.nextInterval(randomUnit: randomUnit)
            )
            nextIncrementalRefreshAt = unavailableDeadline
            nextFullReconciliationAt = max(
                nextFullReconciliationAt,
                unavailableDeadline
            )
        case .transientFailure:
            failureCount = incrementedFailureCount(failureCount)
            let backoffDeadline = eventDate.addingTimeInterval(
                transientBackoffInterval(failureCount: failureCount, randomUnit: randomUnit)
            )
            nextIncrementalRefreshAt = backoffDeadline
            nextFullReconciliationAt = max(nextFullReconciliationAt, backoffDeadline)
        case let .rateLimited(retryAt):
            failureCount = incrementedFailureCount(failureCount)
            let backoffDeadline = eventDate.addingTimeInterval(
                transientBackoffInterval(failureCount: failureCount, randomUnit: randomUnit)
            )
            let retryDeadline = retryAt.map { max($0, eventDate) } ?? backoffDeadline
            let conservativeDeadline = max(backoffDeadline, retryDeadline)
            rateLimitedUntil = conservativeDeadline
            nextIncrementalRefreshAt = conservativeDeadline
        case let .blocked(reason):
            blockedReason = reason
            rateLimitedUntil = state.rateLimitedUntil
        }

        return replacing(
            state,
            nextIncrementalRefreshAt: nextIncrementalRefreshAt,
            nextFullReconciliationAt: nextFullReconciliationAt,
            rateLimitedUntil: .some(rateLimitedUntil),
            blockedReason: .some(blockedReason),
            consecutiveTransientFailureCount: failureCount,
            activeAttemptID: .some(nil),
            lastCompletedAt: .some(eventDate),
            updatedAt: eventDate
        )
    }

    func cancel(
        _ state: OrganizationSchedulerState,
        ownedBy attemptID: UUID,
        generation expectedGeneration: UInt64,
        at date: Date
    ) -> OrganizationSchedulerState? {
        guard state.activeAttemptID == attemptID,
              state.generation == expectedGeneration
        else {
            return nil
        }
        return replacing(
            state,
            activeAttemptID: .some(nil),
            updatedAt: monotonicDate(date, for: state)
        )
    }

    func recoverInterruptedAttempt(
        in state: OrganizationSchedulerState,
        at date: Date
    ) -> OrganizationSchedulerState {
        guard state.activeAttemptID != nil else { return state }
        let eventDate = monotonicDate(date, for: state)
        return replacing(
            state,
            nextIncrementalRefreshAt: min(state.nextIncrementalRefreshAt, eventDate),
            activeAttemptID: .some(nil),
            updatedAt: eventDate
        )
    }

    func clearBlockAndMakeDue(
        in state: OrganizationSchedulerState,
        at date: Date
    ) -> OrganizationSchedulerState {
        let eventDate = monotonicDate(date, for: state)
        return replacing(
            state,
            nextIncrementalRefreshAt: min(state.nextIncrementalRefreshAt, eventDate),
            rateLimitedUntil: .some(nil),
            blockedReason: .some(nil),
            consecutiveTransientFailureCount: 0,
            updatedAt: eventDate
        )
    }

    func transientBackoffInterval(failureCount: Int, randomUnit: Double) -> TimeInterval {
        let boundedFailureCount = min(
            max(failureCount, 1),
            Self.maximumTransientFailureCount
        )
        let exponent = min(boundedFailureCount - 1, 62)
        var interval = transientBackoffBase
        for _ in 0..<exponent {
            guard interval < transientBackoffMaximum else { break }
            interval = min(interval * 2, transientBackoffMaximum)
        }
        let boundedRandomUnit = min(max(randomUnit, 0), 1)
        return min(
            interval + (boundedRandomUnit * transientBackoffMaximumJitter),
            transientBackoffMaximum
        )
    }

    private func incrementalCadence(
        for trigger: OrganizationRefreshScheduleTrigger
    ) -> RefreshCadence {
        switch trigger {
        case .selectedOrganization, .manual, .activeApplication:
            selectedCadence
        case .inactiveAccount, .fullReconciliation:
            inactiveCadence
        }
    }

    private func incrementedFailureCount(_ failureCount: Int) -> Int {
        min(
            max(failureCount, 0) + 1,
            Self.maximumTransientFailureCount
        )
    }

    private func monotonicDate(_ date: Date, for state: OrganizationSchedulerState) -> Date {
        max(
            max(date, state.updatedAt),
            max(state.lastAttemptAt ?? date, state.lastCompletedAt ?? date)
        )
    }

    private func replacing(
        _ state: OrganizationSchedulerState,
        nextIncrementalRefreshAt: Date? = nil,
        nextFullReconciliationAt: Date? = nil,
        rateLimitedUntil: Date?? = nil,
        blockedReason: OrganizationRefreshBlockReason?? = nil,
        consecutiveTransientFailureCount: Int? = nil,
        activeAttemptID: UUID?? = nil,
        lastAttemptAt: Date?? = nil,
        lastCompletedAt: Date?? = nil,
        generation: UInt64? = nil,
        updatedAt: Date? = nil
    ) -> OrganizationSchedulerState {
        OrganizationSchedulerState(
            accountID: state.accountID,
            organizationID: state.organizationID,
            credentialRevision: state.credentialRevision,
            capabilityRevision: state.capabilityRevision,
            nextIncrementalRefreshAt: nextIncrementalRefreshAt ?? state.nextIncrementalRefreshAt,
            nextFullReconciliationAt: nextFullReconciliationAt ?? state.nextFullReconciliationAt,
            rateLimitedUntil: rateLimitedUntil ?? state.rateLimitedUntil,
            blockedReason: blockedReason ?? state.blockedReason,
            consecutiveTransientFailureCount: consecutiveTransientFailureCount
                ?? state.consecutiveTransientFailureCount,
            activeAttemptID: activeAttemptID ?? state.activeAttemptID,
            lastAttemptAt: lastAttemptAt ?? state.lastAttemptAt,
            lastCompletedAt: lastCompletedAt ?? state.lastCompletedAt,
            generation: generation ?? state.generation,
            updatedAt: updatedAt ?? state.updatedAt
        )
    }
}
