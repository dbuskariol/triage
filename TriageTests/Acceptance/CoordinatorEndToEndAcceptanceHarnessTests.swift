import XCTest
@testable import Triage

/// Contract harness for the production composition boundary. The source
/// synchronizers, derived projection, and workspace observation publisher are
/// deliberately injectable so this remains deterministic while source-stream
/// integration is still being completed in parallel.
final class CoordinatorEndToEndAcceptanceHarnessTests: XCTestCase {
    func testLifecycleRefreshCommitsNormalizesDerivesThenPublishesForOneExactRevision() async throws {
        let scope = makeScope(
            credentialRevision: "credential-acceptance-v4",
            capabilityRevision: "capability-acceptance-v7"
        )
        let ledger = AcceptanceEventLedger()
        let normalized = NormalizedCommitSpy(ledger: ledger)
        let derived = DerivedRecomputeSpy(normalized: normalized, ledger: ledger)
        let observation = ObservationPublicationSpy(derived: derived, ledger: ledger)
        let pipeline = CoordinatorAcceptancePipeline(
            normalizedCommit: normalized,
            derivedRecompute: derived,
            observationPublication: observation
        )
        let runtime = CoordinatorAcceptanceRuntime(
            expectedScope: scope,
            pipeline: pipeline,
            ledger: ledger
        )
        let resolver = AcceptanceRuntimeResolver(runtime: runtime)
        let lifecycle = OrganizationRefreshLifecycleService(
            enumerateScopes: { [scope] },
            activeAccountID: { scope.accountID },
            resolveRuntime: { _ in await resolver.runtime() }
        )

        let result = try await lifecycle.applicationDidBecomeActive()
        let events = await ledger.events()

        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.refreshedAccountIDs, [scope.accountID])
        XCTAssertTrue(result.failedAccountIDs.isEmpty)
        XCTAssertEqual(events, [
            .lifecycle(scope),
            .normalizedCommit(scope),
            .derivedRecompute(scope),
            .observationPublication(scope)
        ])
        let committedScope = await normalized.committedScope()
        let recomputedScope = await derived.recomputedScope()
        let publishedScope = await observation.publishedScope()
        XCTAssertEqual(committedScope, scope)
        XCTAssertEqual(recomputedScope, scope)
        XCTAssertEqual(publishedScope, scope)
    }

    func testStaleLifecycleScopeCannotReachNormalizationDerivedOrObservation() async throws {
        let current = makeScope(
            credentialRevision: "credential-current",
            capabilityRevision: "capability-current"
        )
        let stale = SynchronizationScope(
            accountID: current.accountID,
            organizationID: current.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-stale")!,
            capabilityRevision: current.capabilityRevision
        )
        let ledger = AcceptanceEventLedger()
        let normalized = NormalizedCommitSpy(ledger: ledger)
        let derived = DerivedRecomputeSpy(normalized: normalized, ledger: ledger)
        let observation = ObservationPublicationSpy(derived: derived, ledger: ledger)
        let pipeline = CoordinatorAcceptancePipeline(
            normalizedCommit: normalized,
            derivedRecompute: derived,
            observationPublication: observation
        )
        let runtime = CoordinatorAcceptanceRuntime(
            expectedScope: current,
            pipeline: pipeline,
            ledger: ledger
        )
        let resolver = AcceptanceRuntimeResolver(runtime: runtime)
        let lifecycle = OrganizationRefreshLifecycleService(
            enumerateScopes: { [stale] },
            activeAccountID: { current.accountID },
            resolveRuntime: { _ in await resolver.runtime() }
        )

        let result = try await lifecycle.wake()
        let events = await ledger.events()

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(events.isEmpty)
        let committedScope = await normalized.committedScope()
        let recomputedScope = await derived.recomputedScope()
        let publishedScope = await observation.publishedScope()
        XCTAssertNil(committedScope)
        XCTAssertNil(recomputedScope)
        XCTAssertNil(publishedScope)
    }

    func testCancellationAfterNormalizedCommitPreventsDerivedAndObservationPublication() async throws {
        let scope = makeScope(
            credentialRevision: "credential-cancelled",
            capabilityRevision: "capability-cancelled"
        )
        let ledger = AcceptanceEventLedger()
        let normalized = NormalizedCommitSpy(ledger: ledger, cancelsAfterCommit: true)
        let derived = DerivedRecomputeSpy(normalized: normalized, ledger: ledger)
        let observation = ObservationPublicationSpy(derived: derived, ledger: ledger)
        let pipeline = CoordinatorAcceptancePipeline(
            normalizedCommit: normalized,
            derivedRecompute: derived,
            observationPublication: observation
        )
        let runtime = CoordinatorAcceptanceRuntime(
            expectedScope: scope,
            pipeline: pipeline,
            ledger: ledger
        )
        let resolver = AcceptanceRuntimeResolver(runtime: runtime)
        let lifecycle = OrganizationRefreshLifecycleService(
            enumerateScopes: { [scope] },
            activeAccountID: { scope.accountID },
            resolveRuntime: { _ in await resolver.runtime() }
        )

        let result = try await lifecycle.launch()
        let events = await ledger.events()

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(events, [.lifecycle(scope), .normalizedCommit(scope)])
        let committedScope = await normalized.committedScope()
        let recomputedScope = await derived.recomputedScope()
        let publishedScope = await observation.publishedScope()
        XCTAssertEqual(committedScope, scope)
        XCTAssertNil(recomputedScope)
        XCTAssertNil(publishedScope)
    }

    private func makeScope(
        credentialRevision: String,
        capabilityRevision: String
    ) -> SynchronizationScope {
        SynchronizationScope(
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: "acceptance-organization-\(credentialRevision)")!,
            credentialRevision: CredentialRevision(rawValue: credentialRevision)!,
            capabilityRevision: CapabilityRevision(rawValue: capabilityRevision)!
        )
    }
}

private enum AcceptanceEvent: Equatable, Sendable {
    case lifecycle(SynchronizationScope)
    case normalizedCommit(SynchronizationScope)
    case derivedRecompute(SynchronizationScope)
    case observationPublication(SynchronizationScope)
}

private actor AcceptanceEventLedger {
    private var values = [AcceptanceEvent]()

    func append(_ value: AcceptanceEvent) {
        values.append(value)
    }

    func events() -> [AcceptanceEvent] {
        values
    }
}

private protocol AcceptanceNormalizedCommitting: Sendable {
    func commit(scope: SynchronizationScope) async throws
    func committedScope() async -> SynchronizationScope?
}

private protocol AcceptanceDerivedRecomputing: Sendable {
    func recompute(scope: SynchronizationScope) async throws
    func recomputedScope() async -> SynchronizationScope?
}

private protocol AcceptanceObservationPublishing: Sendable {
    func publish(scope: SynchronizationScope) async throws
    func publishedScope() async -> SynchronizationScope?
}

private actor CoordinatorAcceptancePipeline {
    private let normalizedCommit: any AcceptanceNormalizedCommitting
    private let derivedRecompute: any AcceptanceDerivedRecomputing
    private let observationPublication: any AcceptanceObservationPublishing

    init(
        normalizedCommit: any AcceptanceNormalizedCommitting,
        derivedRecompute: any AcceptanceDerivedRecomputing,
        observationPublication: any AcceptanceObservationPublishing
    ) {
        self.normalizedCommit = normalizedCommit
        self.derivedRecompute = derivedRecompute
        self.observationPublication = observationPublication
    }

    func refresh(scope: SynchronizationScope) async throws {
        try Task.checkCancellation()
        try await normalizedCommit.commit(scope: scope)
        try Task.checkCancellation()
        try await derivedRecompute.recompute(scope: scope)
        try Task.checkCancellation()
        try await observationPublication.publish(scope: scope)
    }
}

private actor CoordinatorAcceptanceRuntime: AccountOrganizationLifecycleRunning {
    private let expectedScope: SynchronizationScope
    private let pipeline: CoordinatorAcceptancePipeline
    private let ledger: AcceptanceEventLedger

    init(
        expectedScope: SynchronizationScope,
        pipeline: CoordinatorAcceptancePipeline,
        ledger: AcceptanceEventLedger
    ) {
        self.expectedScope = expectedScope
        self.pipeline = pipeline
        self.ledger = ledger
    }

    func applicationDidBecomeActive(
        synchronizationScopes: [SynchronizationScope],
        activeAccountID _: AccountID?
    ) async throws {
        for scope in synchronizationScopes {
            guard scope == expectedScope else { throw CancellationError() }
            await ledger.append(.lifecycle(scope))
            try await pipeline.refresh(scope: scope)
        }
    }

    func cancelAll() async throws {}
}

private actor AcceptanceRuntimeResolver {
    private let value: any AccountOrganizationLifecycleRunning

    init(runtime: any AccountOrganizationLifecycleRunning) {
        value = runtime
    }

    func runtime() -> any AccountOrganizationLifecycleRunning {
        value
    }
}

private actor NormalizedCommitSpy: AcceptanceNormalizedCommitting {
    private let ledger: AcceptanceEventLedger
    private let cancelsAfterCommit: Bool
    private var scope: SynchronizationScope?

    init(ledger: AcceptanceEventLedger, cancelsAfterCommit: Bool = false) {
        self.ledger = ledger
        self.cancelsAfterCommit = cancelsAfterCommit
    }

    func commit(scope: SynchronizationScope) async throws {
        self.scope = scope
        await ledger.append(.normalizedCommit(scope))
        if cancelsAfterCommit { throw CancellationError() }
    }

    func committedScope() -> SynchronizationScope? {
        scope
    }
}

private actor DerivedRecomputeSpy: AcceptanceDerivedRecomputing {
    private let normalized: any AcceptanceNormalizedCommitting
    private let ledger: AcceptanceEventLedger
    private var scope: SynchronizationScope?

    init(normalized: any AcceptanceNormalizedCommitting, ledger: AcceptanceEventLedger) {
        self.normalized = normalized
        self.ledger = ledger
    }

    func recompute(scope: SynchronizationScope) async throws {
        guard await normalized.committedScope() == scope else {
            throw AcceptanceHarnessError.missingNormalizedCommit
        }
        self.scope = scope
        await ledger.append(.derivedRecompute(scope))
    }

    func recomputedScope() -> SynchronizationScope? {
        scope
    }
}

private actor ObservationPublicationSpy: AcceptanceObservationPublishing {
    private let derived: any AcceptanceDerivedRecomputing
    private let ledger: AcceptanceEventLedger
    private var scope: SynchronizationScope?

    init(derived: any AcceptanceDerivedRecomputing, ledger: AcceptanceEventLedger) {
        self.derived = derived
        self.ledger = ledger
    }

    func publish(scope: SynchronizationScope) async throws {
        guard await derived.recomputedScope() == scope else {
            throw AcceptanceHarnessError.missingDerivedRecompute
        }
        self.scope = scope
        await ledger.append(.observationPublication(scope))
    }

    func publishedScope() -> SynchronizationScope? {
        scope
    }
}

private enum AcceptanceHarnessError: Error {
    case missingNormalizedCommit
    case missingDerivedRecompute
}
