import XCTest
@testable import Triage

final class OrganizationRefreshCompletionCoordinatorTests: XCTestCase {
    private let scope = SynchronizationScope(
        accountID: AccountID(rawValue: "completion-account")!,
        organizationID: OrganizationID(rawValue: "completion-organization")!,
        credentialRevision: CredentialRevision(rawValue: "credential-r4")!,
        capabilityRevision: CapabilityRevision(rawValue: "capability-r2")!
    )
    private let evaluatedAt = Date(timeIntervalSinceReferenceDate: 100_000)

    func testDerivedProjectionStartsOnlyAfterNormalizedCommit() async throws {
        let ledger = CompletionEventLedger()
        let normalized = NormalizedCommitter(ledger: ledger)
        let gate = CompletionScopeGate(ledger: ledger)
        let coordinator = makeCoordinator(ledger: ledger, normalized: normalized, gate: gate)

        try await normalized.commit(scope: scope)
        let outcome = try await coordinator.finalizeAfterNormalizedCommit(
            for: scope,
            evaluatedAt: evaluatedAt
        )

        guard case .published = outcome else {
            return XCTFail("Expected a published derived projection.")
        }
        let events = await ledger.events()
        XCTAssertEqual(events, [
            .normalizedCommit(scope),
            .scopeValidation(scope),
            .projection(scope),
            .scopeValidation(scope)
        ])
    }

    func testStaleScopeAfterNormalizedCommitCannotStartOrPublishProjection() async throws {
        let ledger = CompletionEventLedger()
        let normalized = NormalizedCommitter(ledger: ledger)
        let gate = CompletionScopeGate(ledger: ledger, cancellationAtValidation: 1)
        let coordinator = makeCoordinator(ledger: ledger, normalized: normalized, gate: gate)

        try await normalized.commit(scope: scope)
        let acceptedOutcome: OrganizationDerivedIntelligenceProjectionOutcome?
        do {
            acceptedOutcome = try await coordinator.finalizeAfterNormalizedCommit(
                for: scope,
                evaluatedAt: evaluatedAt
            )
            XCTFail("Expected stale scope cancellation.")
        } catch is CancellationError {
            acceptedOutcome = nil
        }

        XCTAssertNil(acceptedOutcome)
        let events = await ledger.events()
        XCTAssertEqual(events, [.normalizedCommit(scope), .scopeValidation(scope)])
    }

    func testCancellationAfterProjectionDoesNotReturnAPublishableOutcome() async throws {
        let ledger = CompletionEventLedger()
        let normalized = NormalizedCommitter(ledger: ledger)
        let gate = CompletionScopeGate(ledger: ledger, cancellationAtValidation: 2)
        let coordinator = makeCoordinator(ledger: ledger, normalized: normalized, gate: gate)

        try await normalized.commit(scope: scope)
        let acceptedOutcome: OrganizationDerivedIntelligenceProjectionOutcome?
        do {
            acceptedOutcome = try await coordinator.finalizeAfterNormalizedCommit(
                for: scope,
                evaluatedAt: evaluatedAt
            )
            XCTFail("Expected cancellation after projection.")
        } catch is CancellationError {
            acceptedOutcome = nil
        }

        XCTAssertNil(acceptedOutcome)
        let events = await ledger.events()
        XCTAssertEqual(events, [
            .normalizedCommit(scope),
            .scopeValidation(scope),
            .projection(scope),
            .scopeValidation(scope)
        ])
    }

    func testSourceStreamFailureKeepsItsCommittedPartialStateAndStillDerives() async throws {
        let ledger = CompletionEventLedger()
        let normalized = NormalizedCommitter(ledger: ledger)
        let gate = CompletionScopeGate(ledger: ledger)
        let coordinator = makeCoordinator(
            ledger: ledger,
            normalized: normalized,
            gate: gate,
            projectionOutcome: .partial(publication())
        )

        try await normalized.recordSourceStreamFailureAndCommit(scope: scope, streamID: "reviews")
        let outcome = try await coordinator.finalizeAfterNormalizedCommit(
            for: scope,
            evaluatedAt: evaluatedAt
        )

        guard case .partial = outcome else {
            return XCTFail("Partial source coverage must produce a partial projection.")
        }
        let events = await ledger.events()
        XCTAssertEqual(events, [
            .sourceStreamFailure(scope, "reviews"),
            .normalizedCommit(scope),
            .scopeValidation(scope),
            .projection(scope),
            .scopeValidation(scope)
        ])
    }

    func testFailedProjectionCannotBeReportedAsRefreshCompletion() async throws {
        let ledger = CompletionEventLedger()
        let normalized = NormalizedCommitter(ledger: ledger)
        let gate = CompletionScopeGate(ledger: ledger)
        let coordinator = makeCoordinator(
            ledger: ledger,
            normalized: normalized,
            gate: gate,
            projectionOutcome: .failed(.persistenceFailed)
        )

        try await normalized.commit(scope: scope)
        do {
            _ = try await coordinator.finalizeAfterNormalizedCommit(for: scope, evaluatedAt: evaluatedAt)
            XCTFail("A failed projection must fail refresh completion.")
        } catch let error as OrganizationRefreshCompletionCoordinatorError {
            XCTAssertEqual(error, .derivedProjectionFailed(.persistenceFailed))
        }
    }

    private func makeCoordinator(
        ledger: CompletionEventLedger,
        normalized: NormalizedCommitter,
        gate: CompletionScopeGate,
        projectionOutcome: OrganizationDerivedIntelligenceProjectionOutcome? = nil
    ) -> OrganizationRefreshCompletionCoordinator {
        let defaultPublication = publication()
        return OrganizationRefreshCompletionCoordinator(
            validateScope: { scope in
                try await gate.validate(scope)
            },
            project: { scope, _, _ in
                guard await normalized.isCommitted(scope) else {
                    throw CompletionTestError.missingNormalizedCommit
                }
                await ledger.append(.projection(scope))
                return projectionOutcome ?? .published(defaultPublication)
            }
        )
    }

    private func publication() -> OrganizationDerivedIntelligenceProjectionPublication {
        OrganizationDerivedIntelligenceProjectionPublication(
            scope: scope,
            sourceRevision: "source-r9",
            evaluatedAt: evaluatedAt,
            coverageState: .trusted,
            isProvisional: false
        )
    }
}

private enum CompletionTestError: Error, Sendable {
    case missingNormalizedCommit
}

private enum CompletionEvent: Equatable, Sendable {
    case sourceStreamFailure(SynchronizationScope, String)
    case normalizedCommit(SynchronizationScope)
    case scopeValidation(SynchronizationScope)
    case projection(SynchronizationScope)
}

private actor CompletionEventLedger {
    private var storage = [CompletionEvent]()

    func append(_ event: CompletionEvent) {
        storage.append(event)
    }

    func events() -> [CompletionEvent] {
        storage
    }
}

private actor NormalizedCommitter {
    private let ledger: CompletionEventLedger
    private var committedScopes = Set<SynchronizationScope>()

    init(ledger: CompletionEventLedger) {
        self.ledger = ledger
    }

    func commit(scope: SynchronizationScope) async throws {
        committedScopes.insert(scope)
        await ledger.append(.normalizedCommit(scope))
    }

    func recordSourceStreamFailureAndCommit(scope: SynchronizationScope, streamID: String) async throws {
        await ledger.append(.sourceStreamFailure(scope, streamID))
        try await commit(scope: scope)
    }

    func isCommitted(_ scope: SynchronizationScope) -> Bool {
        committedScopes.contains(scope)
    }
}

private actor CompletionScopeGate {
    private let ledger: CompletionEventLedger
    private let cancellationAtValidation: Int?
    private var count = 0

    init(ledger: CompletionEventLedger, cancellationAtValidation: Int? = nil) {
        self.ledger = ledger
        self.cancellationAtValidation = cancellationAtValidation
    }

    func validate(_ scope: SynchronizationScope) async throws {
        count += 1
        await ledger.append(.scopeValidation(scope))
        if count == cancellationAtValidation {
            throw CancellationError()
        }
    }
}
