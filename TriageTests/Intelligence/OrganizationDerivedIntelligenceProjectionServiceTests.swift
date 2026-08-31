import Foundation
import XCTest
@testable import Triage

final class OrganizationDerivedIntelligenceProjectionServiceTests: XCTestCase {
    private let accountID = AccountID(rawValue: "account")!
    private let organizationID = OrganizationID(rawValue: "organization")!
    private let evaluatedAt = Date(timeIntervalSinceReferenceDate: 50_000)

    func testCommittedTrustedSnapshotValidatesAroundEverySuspensionAndPublishes() async throws {
        let log = EventLog()
        let gate = ScopeGate(log: log)
        let snapshot = makeSnapshot(isProvisional: false, completeCoverage: true)
        let recomputes = RecomputeCounter()
        let service = makeService(log: log, gate: gate, snapshot: snapshot, recomputes: recomputes)

        let outcome = try await service.recomputeAfterNormalizedCommit(
            for: scope,
            aiPolicy: policy,
            evaluatedAt: evaluatedAt
        )

        guard case let .published(publication) = outcome else {
            return XCTFail("Expected a trusted publication, got \(outcome).")
        }
        XCTAssertEqual(publication.scope, scope)
        XCTAssertEqual(publication.sourceRevision, "source-v1")
        XCTAssertEqual(publication.coverageState, .trusted)
        XCTAssertFalse(publication.isProvisional)
        XCTAssertEqual(recomputes.value, 1)
        let events = await log.values()
        XCTAssertEqual(
            events,
            ["validate", "snapshot", "validate", "validate", "persist", "validate"]
        )
    }

    func testProvisionalSnapshotIsPersistedButReportedAsPartial() async throws {
        let log = EventLog()
        let gate = ScopeGate(log: log)
        let snapshot = makeSnapshot(isProvisional: true, completeCoverage: false)
        let service = makeService(log: log, gate: gate, snapshot: snapshot)

        let outcome = try await service.recomputeAfterNormalizedCommit(
            for: scope,
            aiPolicy: policy,
            evaluatedAt: evaluatedAt
        )

        guard case let .partial(publication) = outcome else {
            return XCTFail("Expected a partial publication, got \(outcome).")
        }
        XCTAssertEqual(publication.coverageState, .incomplete)
        XCTAssertTrue(publication.isProvisional)
        let persistedSourceRevisions = await log.persistedSourceRevisions()
        XCTAssertEqual(persistedSourceRevisions, ["source-v1"])
    }

    func testStaleScopeAfterAdapterSnapshotCancelsBeforePersistence() async throws {
        let log = EventLog()
        let gate = ScopeGate(log: log, cancellationAtValidation: 2)
        let service = makeService(log: log, gate: gate, snapshot: makeSnapshot())

        do {
            _ = try await service.recomputeAfterNormalizedCommit(
                for: scope,
                aiPolicy: policy,
                evaluatedAt: evaluatedAt
            )
            XCTFail("Expected stale scope cancellation.")
        } catch is CancellationError {}

        let events = await log.values()
        let persistedSourceRevisions = await log.persistedSourceRevisions()
        XCTAssertEqual(events, ["validate", "snapshot", "validate"])
        XCTAssertTrue(persistedSourceRevisions.isEmpty)
    }

    func testStaleScopeAfterRepositoryReplaceFailsClosedWithoutOutcome() async throws {
        let log = EventLog()
        let gate = ScopeGate(log: log, cancellationAtValidation: 4)
        let service = makeService(log: log, gate: gate, snapshot: makeSnapshot())

        do {
            _ = try await service.recomputeAfterNormalizedCommit(
                for: scope,
                aiPolicy: policy,
                evaluatedAt: evaluatedAt
            )
            XCTFail("Expected stale scope cancellation.")
        } catch is CancellationError {}

        let events = await log.values()
        let persistedSourceRevisions = await log.persistedSourceRevisions()
        XCTAssertEqual(
            events,
            ["validate", "snapshot", "validate", "validate", "persist", "validate"]
        )
        XCTAssertEqual(persistedSourceRevisions, ["source-v1"])
    }

    func testSnapshotFailureReturnsExplicitFailureWithoutPersistence() async throws {
        let log = EventLog()
        let gate = ScopeGate(log: log)
        let service = OrganizationDerivedIntelligenceProjectionService(
            validateScope: { scope in
                try await gate.validate(scope)
            },
            loadSnapshot: { _, _, _, _, _ in
                await log.append("snapshot")
                throw ProjectionTestError.expected
            },
            recompute: { _ in
                throw ProjectionTestError.expected
            },
            persist: { durableSnapshot in
                await log.persist(sourceRevision: durableSnapshot.sourceRevision)
            }
        )

        let outcome = try await service.recomputeAfterNormalizedCommit(
            for: scope,
            aiPolicy: policy,
            evaluatedAt: evaluatedAt
        )

        XCTAssertEqual(outcome, .failed(.snapshotFailed))
        let events = await log.values()
        let persistedSourceRevisions = await log.persistedSourceRevisions()
        XCTAssertEqual(events, ["validate", "snapshot"])
        XCTAssertTrue(persistedSourceRevisions.isEmpty)
    }

    private var scope: SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability")!
        )
    }

    private var policy: DerivedAIPolicy {
        DerivedAIPolicy(
            isOrganizationConsentActive: true,
            isAuthenticationValid: true,
            isEntitled: true,
            hasAvailableBudget: true
        )
    }

    private func makeService(
        log: EventLog,
        gate: ScopeGate,
        snapshot: DerivedIntelligenceInputSnapshot,
        recomputes: RecomputeCounter = .init()
    ) -> OrganizationDerivedIntelligenceProjectionService {
        OrganizationDerivedIntelligenceProjectionService(
            validateScope: { scope in
                try await gate.validate(scope)
            },
            loadSnapshot: { _, _, _, _, _ in
                await log.append("snapshot")
                return snapshot
            },
            recompute: { input in
                recomputes.increment()
                return try DerivedIntelligenceCoordinator().recompute(input)
            },
            persist: { durableSnapshot in
                await log.persist(sourceRevision: durableSnapshot.sourceRevision)
            }
        )
    }

    private func makeSnapshot(
        isProvisional: Bool = false,
        completeCoverage: Bool = true
    ) -> DerivedIntelligenceInputSnapshot {
        let requirement = CoverageRequirement(
            feature: .reviews,
            repositoryID: nil,
            streamID: SyncStreamID(rawValue: "reviews")!
        )
        let record = CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            feature: .reviews,
            streamID: SyncStreamID(rawValue: "reviews")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: completeCoverage ? .complete : .partial,
            lastSuccessfulAt: evaluatedAt,
            failureDetail: nil
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return DerivedIntelligenceInputSnapshot(
            input: DerivedIntelligenceInput(
                scope: scope,
                currentUserNodeID: GitHubNodeID(rawValue: "current-user")!,
                visibleTeamNodeIDs: [],
                coverageRequirements: [requirement],
                coverageRecords: [record],
                calendar: calendar,
                aiPolicy: policy,
                evaluatedAt: evaluatedAt,
                items: []
            ),
            sourceStates: [],
            sourceRevisions: [:],
            aggregateSourceRevision: "source-v1",
            isProvisional: isProvisional
        )
    }
}

private enum ProjectionTestError: Error, Sendable {
    case expected
}

private actor ScopeGate {
    private let log: EventLog
    private let cancellationAtValidation: Int?
    private var validationCount = 0

    init(log: EventLog, cancellationAtValidation: Int? = nil) {
        self.log = log
        self.cancellationAtValidation = cancellationAtValidation
    }

    func validate(_: SynchronizationScope) async throws {
        validationCount += 1
        await log.append("validate")
        if validationCount == cancellationAtValidation {
            throw CancellationError()
        }
    }
}

private actor EventLog {
    private var events = [String]()
    private var sourceRevisions = [String]()

    func append(_ event: String) {
        events.append(event)
    }

    func persist(sourceRevision: String) {
        events.append("persist")
        sourceRevisions.append(sourceRevision)
    }

    func values() -> [String] {
        events
    }

    func persistedSourceRevisions() -> [String] {
        sourceRevisions
    }
}

private final class RecomputeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
