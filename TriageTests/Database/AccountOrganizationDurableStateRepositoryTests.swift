import Foundation
import GRDB
import XCTest
@testable import Triage

final class AccountOrganizationDurableStateRepositoryTests: XCTestCase {
    func testFinalizationRoundTripsExactRevisionQualifiedDurableState() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000101")
        let active = fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 5)
        let completed = fixture.completedSchedule(scope: scope, generation: 5)
        let durable = fixture.qualifiedDurableState(scope: scope)

        try await fixture.persistCoverage(from: durable)
        try await scheduler.save(active)
        let didFinalize = try await repository.finalize(
            durable,
            schedule: completed,
            for: scope,
            ifOwnedBy: attemptID,
            generation: 5
        )
        XCTAssertNotNil(didFinalize)

        let loaded = try await repository.loadState(for: scope)
        let persistedSchedule = try await scheduler.state(for: scope)
        XCTAssertEqual(loaded, didFinalize)
        XCTAssertEqual(
            loaded?.cachedState?.coverageRequirements?.count,
            14 + RoleDiscoveryStreamKind.allCases.count
        )
        XCTAssertEqual(persistedSchedule, completed)
    }

    func testRepositoryBackedManifestRetainsCanonicalOrderingAcrossReload() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        _ = try await fixture.installRepositoryBackedWorkflow()
        let requirements = try await fixture.vault.read { database in
            try CoverageRequirementProfile.build(for: scope, coverage: [], in: database)
        }
        let coverage = requirements.map { fixture.completeCoverage($0, scope: scope) }
        for record in coverage {
            try await CoverageRepository(vault: fixture.vault).save(
                record,
                attemptedAt: fixture.now
            )
        }
        let candidate = AccountOrganizationDurableState(
            cachedState: AccountOrganizationCachedState(
                coverage: coverage,
                lastSuccessfulSyncAt: fixture.successDate
            )
        )
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000122")
        try await scheduler.save(
            fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 1)
        )

        let finalized = try await repository.finalize(
            candidate,
            schedule: fixture.completedSchedule(scope: scope, generation: 1),
            for: scope,
            ifOwnedBy: attemptID,
            generation: 1
        )
        let committed = try XCTUnwrap(finalized)
        let loaded = try await repository.loadState(for: scope)

        XCTAssertEqual(loaded, committed)
        XCTAssertEqual(loaded?.cachedState?.coverageRequirements, requirements)
        XCTAssertEqual(loaded?.freshness.status, .fresh)
    }

    func testEncryptedVaultReopenRetainsDurableProjectionWithoutPlaintextPayload() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000102")
        let durable = fixture.qualifiedDurableState(
            scope: scope,
            detail: "private-projection-marker"
        )

        try await fixture.persistCoverage(from: durable)
        try await scheduler.save(fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 2))
        let didFinalize = try await repository.finalize(
            durable,
            schedule: fixture.completedSchedule(scope: scope, generation: 2),
            for: scope,
            ifOwnedBy: attemptID,
            generation: 2
        )
        XCTAssertNotNil(didFinalize)
        try await fixture.registry.closeAll()

        let encryptedBytes = try Data(contentsOf: fixture.databaseURL)
        XCTAssertFalse(encryptedBytes.contains(Data("private-projection-marker".utf8)))

        let reopenedRegistry = try VaultRegistry(rootDirectory: fixture.directory)
        let reopenedVault = try await reopenedRegistry.open(
            accountID: fixture.accountID,
            vaultKey: fixture.vaultKey
        )
        let reopened = AccountOrganizationDurableStateRepository(vault: reopenedVault)

        let reopenedState = try await reopened.loadState(for: scope)
        XCTAssertEqual(reopenedState, didFinalize)
        try await reopenedRegistry.closeAll()
    }

    func testCredentialRevisionChangeInvalidatesDurableProjection() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let oldScope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000103")
        let durable = fixture.qualifiedDurableState(scope: oldScope)

        try await fixture.persistCoverage(from: durable)
        try await scheduler.save(fixture.activeSchedule(scope: oldScope, attemptID: attemptID, generation: 1))
        let didFinalize = try await repository.finalize(
            durable,
            schedule: fixture.completedSchedule(scope: oldScope, generation: 1),
            for: oldScope,
            ifOwnedBy: attemptID,
            generation: 1
        )
        XCTAssertNotNil(didFinalize)
        let currentRevision = CredentialRevision(rawValue: "credential-current")!
        try await fixture.setCredentialRevision(currentRevision)
        let currentScope = fixture.scope(credentialRevision: currentRevision)

        do {
            _ = try await repository.loadState(for: oldScope)
            XCTFail("An obsolete credential revision must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationDurableStateRepositoryError,
                .staleSynchronizationScope
            )
        }
        let state = try await repository.loadState(for: currentScope)
        let counts = try await fixture.rawRowCounts()
        XCTAssertNil(state)
        XCTAssertEqual(counts.durable, 0)
        XCTAssertEqual(counts.scheduler, 1)
    }

    func testCapabilityRevisionChangeInvalidatesDurableProjection() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let oldScope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000104")
        let durable = fixture.qualifiedDurableState(scope: oldScope)

        try await fixture.persistCoverage(from: durable)
        try await scheduler.save(fixture.activeSchedule(scope: oldScope, attemptID: attemptID, generation: 1))
        let didFinalize = try await repository.finalize(
            durable,
            schedule: fixture.completedSchedule(scope: oldScope, generation: 1),
            for: oldScope,
            ifOwnedBy: attemptID,
            generation: 1
        )
        XCTAssertNotNil(didFinalize)
        let currentRevision = CapabilityRevision(rawValue: "capability-current")!
        try await fixture.setCapabilityRevision(currentRevision)
        let currentScope = fixture.scope(capabilityRevision: currentRevision)

        do {
            _ = try await repository.loadState(for: oldScope)
            XCTFail("An obsolete capability revision must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationDurableStateRepositoryError,
                .staleSynchronizationScope
            )
        }
        let state = try await repository.loadState(for: currentScope)
        let counts = try await fixture.rawRowCounts()
        XCTAssertNil(state)
        XCTAssertEqual(counts.durable, 0)
        XCTAssertEqual(counts.scheduler, 1)
    }

    func testStaleRevisionCannotOverwriteCurrentDurableProjection() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let staleScope = fixture.scope()
        let currentCredential = CredentialRevision(rawValue: "credential-current")!
        try await fixture.setCredentialRevision(currentCredential)
        let currentScope = fixture.scope(credentialRevision: currentCredential)
        let currentAttempt = fixture.attemptID("00000000-0000-0000-0000-000000000105")
        let currentDurable = fixture.qualifiedDurableState(scope: currentScope, successOffset: 120)
        let currentCompleted = fixture.completedSchedule(scope: currentScope, generation: 4)

        try await fixture.persistCoverage(from: currentDurable)
        try await scheduler.save(
            fixture.activeSchedule(scope: currentScope, attemptID: currentAttempt, generation: 4)
        )
        let didFinalize = try await repository.finalize(
            currentDurable,
            schedule: currentCompleted,
            for: currentScope,
            ifOwnedBy: currentAttempt,
            generation: 4
        )
        XCTAssertNotNil(didFinalize)

        let staleAttempt = fixture.attemptID("00000000-0000-0000-0000-000000000106")
        do {
            _ = try await repository.finalize(
                fixture.qualifiedDurableState(scope: staleScope, successOffset: 240),
                schedule: fixture.completedSchedule(scope: staleScope, generation: 9),
                for: staleScope,
                ifOwnedBy: staleAttempt,
                generation: 9
            )
            XCTFail("A stale revision must not replace a current durable projection.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationDurableStateRepositoryError,
                .staleSynchronizationScope
            )
        }

        let loaded = try await repository.loadState(for: currentScope)
        let retainedSchedule = try await scheduler.state(for: currentScope)
        XCTAssertEqual(loaded, didFinalize)
        XCTAssertEqual(retainedSchedule, currentCompleted)
    }

    func testSuccessfulEmptyCacheIsRejectedBeforeSchedulerMutation() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000107")
        let active = fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 3)
        let suspicious = AccountOrganizationDurableState(
            cachedState: AccountOrganizationCachedState(
                coverage: [],
                lastSuccessfulSyncAt: fixture.successDate
            ),
            freshness: FreshnessState(status: .fresh, lastSuccessfulSyncAt: fixture.successDate)
        )

        try await scheduler.save(active)
        do {
            _ = try await repository.finalize(
                suspicious,
                schedule: fixture.completedSchedule(scope: scope, generation: 3),
                for: scope,
                ifOwnedBy: attemptID,
                generation: 3
            )
            XCTFail("A successful durable state must carry revision-qualified coverage.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationDurableStateRepositoryError,
                .invalidProjection
            )
        }

        let persistedSchedule = try await scheduler.state(for: scope)
        let counts = try await fixture.rawRowCounts()
        XCTAssertEqual(persistedSchedule, active)
        XCTAssertEqual(counts.durable, 0)
    }

    func testForeignAccountAndUnassociatedOrganizationAreRejected() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let foreignScope = SynchronizationScope(
            accountID: AccountID.make(),
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        let unassociatedScope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: OrganizationID(rawValue: "unassociated")!,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )

        do {
            _ = try await repository.loadState(for: foreignScope)
            XCTFail("A durable projection cannot cross its encrypted account vault.")
        } catch {
            XCTAssertEqual(error as? AccountOrganizationDurableStateRepositoryError, .accountScopeMismatch)
        }
        do {
            _ = try await repository.finalize(
                fixture.qualifiedDurableState(scope: unassociatedScope),
                schedule: fixture.completedSchedule(scope: unassociatedScope, generation: 1),
                for: unassociatedScope,
                ifOwnedBy: fixture.attemptID("00000000-0000-0000-0000-000000000108"),
                generation: 1
            )
            XCTFail("A durable projection requires a current account-organization association.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationDurableStateRepositoryError,
                .organizationScopeMismatch
            )
        }
    }

    func testSchedulerCASLossRetainsPriorProjectionAndActiveSchedule() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let firstAttempt = fixture.attemptID("00000000-0000-0000-0000-000000000109")
        let prior = fixture.qualifiedDurableState(scope: scope, successOffset: 60)

        try await fixture.persistCoverage(from: prior)
        try await scheduler.save(fixture.activeSchedule(scope: scope, attemptID: firstAttempt, generation: 3))
        let firstFinalization = try await repository.finalize(
            prior,
            schedule: fixture.completedSchedule(scope: scope, generation: 3),
            for: scope,
            ifOwnedBy: firstAttempt,
            generation: 3
        )
        XCTAssertNotNil(firstFinalization)
        let currentAttempt = fixture.attemptID("00000000-0000-0000-0000-000000000110")
        let active = fixture.activeSchedule(scope: scope, attemptID: currentAttempt, generation: 4)
        let replacement = fixture.qualifiedDurableState(scope: scope, successOffset: 120)
        try await fixture.persistCoverage(from: replacement)
        try await scheduler.save(active)

        let didFinalize = try await repository.finalize(
            replacement,
            schedule: fixture.completedSchedule(scope: scope, generation: 4),
            for: scope,
            ifOwnedBy: fixture.attemptID("00000000-0000-0000-0000-000000000111"),
            generation: 4
        )

        XCTAssertNil(didFinalize)
        let loaded = try await repository.loadState(for: scope)
        let persistedSchedule = try await scheduler.state(for: scope)
        XCTAssertEqual(loaded?.cachedState, firstFinalization?.cachedState)
        XCTAssertEqual(loaded?.freshness.status, .stale)
        XCTAssertEqual(
            loaded?.freshness.detail,
            "A previous synchronization did not complete. Cached data is retained."
        )
        XCTAssertEqual(persistedSchedule, active)
    }

    func testMalformedRawPayloadFailsExplicitlyWithoutLeakingPayload() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let privatePayload = Data(#"{"token":"ghp_durableProjectionSecret""#.utf8)
        try await fixture.insertRawDurablePayload(privatePayload, scope: scope)

        do {
            _ = try await repository.loadState(for: scope)
            XCTFail("A malformed durable envelope must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationDurableStateRepositoryError,
                .invalidPersistedData
            )
            XCTAssertFalse(String(describing: error).contains("ghp_durableProjectionSecret"))
        }
    }

    func testProjectionWriteFailureRollsBackSchedulerCASAndRetrySucceeds() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000112")
        let active = fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 8)
        let completed = fixture.completedSchedule(scope: scope, generation: 8)
        let durable = fixture.qualifiedDurableState(scope: scope)
        try await fixture.persistCoverage(from: durable)
        try await scheduler.save(active)
        try await fixture.installRejectingDurableProjectionTrigger()

        do {
            _ = try await repository.finalize(
                durable,
                schedule: completed,
                for: scope,
                ifOwnedBy: attemptID,
                generation: 8
            )
            XCTFail("Expected the durable projection trigger to abort finalization.")
        } catch is DatabaseError {
        }

        let rolledBackSchedule = try await scheduler.state(for: scope)
        let rolledBackCounts = try await fixture.rawRowCounts()
        XCTAssertEqual(rolledBackSchedule, active)
        XCTAssertEqual(rolledBackCounts.durable, 0)

        try await fixture.removeRejectingDurableProjectionTrigger()
        let didFinalize = try await repository.finalize(
            durable,
            schedule: completed,
            for: scope,
            ifOwnedBy: attemptID,
            generation: 8
        )
        XCTAssertNotNil(didFinalize)
        let persistedSchedule = try await scheduler.state(for: scope)
        let loaded = try await repository.loadState(for: scope)
        XCTAssertEqual(persistedSchedule, completed)
        XCTAssertEqual(loaded, didFinalize)
    }

    func testAssociationDeletionCascadesSchedulerAndDurableRows() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000113")
        let durable = fixture.qualifiedDurableState(scope: scope)

        try await fixture.persistCoverage(from: durable)
        try await scheduler.save(fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 1))
        let didFinalize = try await repository.finalize(
            durable,
            schedule: fixture.completedSchedule(scope: scope, generation: 1),
            for: scope,
            ifOwnedBy: attemptID,
            generation: 1
        )
        XCTAssertNotNil(didFinalize)
        try await fixture.removeAssociation()

        let counts = try await fixture.rawRowCounts()
        XCTAssertEqual(counts.durable, 0)
        XCTAssertEqual(counts.scheduler, 0)
    }

    func testWrongGenerationIsRejectedBeforeAnyProjectionMutation() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000114")
        let active = fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 6)
        try await scheduler.save(active)

        do {
            _ = try await repository.finalize(
                fixture.qualifiedDurableState(scope: scope),
                schedule: fixture.completedSchedule(scope: scope, generation: 6),
                for: scope,
                ifOwnedBy: attemptID,
                generation: 5
            )
            XCTFail("The completion generation must equal its active schedule generation.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationDurableStateRepositoryError,
                .scheduleScopeMismatch
            )
        }

        let persistedSchedule = try await scheduler.state(for: scope)
        let counts = try await fixture.rawRowCounts()
        XCTAssertEqual(persistedSchedule, active)
        XCTAssertEqual(counts.durable, 0)
    }

    func testMismatchedNormalizedCoverageRejectsFinalizationWithoutSchedulerMutation() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000115")
        let active = fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 2)

        try await scheduler.save(active)
        do {
            _ = try await repository.finalize(
                fixture.qualifiedDurableState(scope: scope),
                schedule: fixture.completedSchedule(scope: scope, generation: 2),
                for: scope,
                ifOwnedBy: attemptID,
                generation: 2
            )
            XCTFail("Terminal state must match coverage committed by normalized source streams.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationDurableStateRepositoryError,
                .invalidProjection
            )
        }

        let retainedSchedule = try await scheduler.state(for: scope)
        let counts = try await fixture.rawRowCounts()
        XCTAssertEqual(retainedSchedule, active)
        XCTAssertEqual(counts.durable, 0)
    }

    func testFailureFinalizationSnapshotsPersistedIncompleteCoverageAtomically() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000119")
        let active = fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 7)
        let failedCoverage = CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: nil,
            feature: .repositories,
            streamID: SyncStreamID(rawValue: "durable-state-failure")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: .requiresSSO,
            lastSuccessfulAt: nil,
            failureDetail: "GitHub organization SSO authorization is required."
        )
        let candidate = AccountOrganizationDurableState(
            cachedState: nil,
            freshness: FreshnessState(
                status: .ssoRequired,
                detail: "GitHub organization SSO authorization is required."
            )
        )

        try await CoverageRepository(vault: fixture.vault).save(
            failedCoverage,
            attemptedAt: fixture.now
        )
        try await scheduler.save(active)
        let committed = try await repository.finalizeFailure(
            candidate,
            schedule: fixture.completedSchedule(scope: scope, generation: 7),
            for: scope,
            ifOwnedBy: attemptID,
            generation: 7
        )

        let committedState = try XCTUnwrap(committed)
        XCTAssertEqual(committedState.cachedState?.coverage, [failedCoverage])
        XCTAssertEqual(
            committedState.cachedState?.coverageRequirements?.count,
            14 + RoleDiscoveryStreamKind.allCases.count
        )
        XCTAssertEqual(committedState.freshness.status, .ssoRequired)
        XCTAssertNil(committedState.freshness.lastSuccessfulSyncAt)
        let loaded = try await repository.loadState(for: scope)
        let persistedSchedule = try await scheduler.state(for: scope)
        XCTAssertEqual(loaded, committedState)
        XCTAssertNil(persistedSchedule?.activeAttemptID)
    }

    func testFailureBeforeAnySourceWriteStillPersistsAuthoritativeRequirements() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000127")
        let active = fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 11)
        let candidate = AccountOrganizationDurableState(
            cachedState: nil,
            freshness: FreshnessState(
                status: .offline,
                detail: "A network connection is required."
            )
        )

        try await scheduler.save(active)
        let committed = try await repository.finalizeFailure(
            candidate,
            schedule: fixture.completedSchedule(scope: scope, generation: 11),
            for: scope,
            ifOwnedBy: attemptID,
            generation: 11
        )

        let committedState = try XCTUnwrap(committed)
        XCTAssertEqual(committedState.cachedState?.coverage, [])
        XCTAssertEqual(
            committedState.cachedState?.coverageRequirements?.count,
            14 + RoleDiscoveryStreamKind.allCases.count
        )
        XCTAssertEqual(committedState.freshness.status, .offline)
        let loaded = try await repository.loadState(for: scope)
        XCTAssertEqual(loaded, committedState)
    }

    func testCoordinatorFailureAfterCoverageWritePersistsReloadableTerminalProjection() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let scope = fixture.scope()
        let failedCoverage = CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: nil,
            feature: .repositories,
            streamID: SyncStreamID(rawValue: "coordinator-failure-integration")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: .requiresSSO,
            lastSuccessfulAt: nil,
            failureDetail: "GitHub organization SSO authorization is required."
        )
        let durableRepository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let operation = CoverageWritingFailureOperation(
            vault: fixture.vault,
            coverage: failedCoverage,
            attemptedAt: fixture.now
        )
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000120")
        let coordinator = AccountOrganizationCoordinator(
            stateStore: durableRepository,
            scheduleStore: scheduler,
            finalizer: durableRepository,
            refreshOperation: operation,
            clock: { fixture.now },
            randomUnit: { 0 },
            makeAttemptID: { attemptID }
        )

        try await coordinator.select(scope)
        let terminalState = try await fixture.awaitIdleState(
            from: coordinator,
            scope: scope
        )
        XCTAssertEqual(terminalState.durableState.cachedState?.coverage, [failedCoverage])
        XCTAssertEqual(terminalState.freshness.status, .ssoRequired)
        XCTAssertFalse(terminalState.freshness.detail?.contains("https://") ?? true)

        try await fixture.registry.closeAll()
        let reopenedRegistry = try VaultRegistry(rootDirectory: fixture.directory)
        let reopenedVault = try await reopenedRegistry.open(
            accountID: fixture.accountID,
            vaultKey: fixture.vaultKey
        )
        let reloaded = try await AccountOrganizationDurableStateRepository(
            vault: reopenedVault
        ).loadState(for: scope)
        XCTAssertEqual(reloaded, terminalState.durableState)
        try await reopenedRegistry.closeAll()
    }

    func testCoordinatorCancellationSnapshotsPartialCoverageAsStaleAcrossReopen() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let scope = fixture.scope()
        let durableRepository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let priorAttempt = fixture.attemptID("00000000-0000-0000-0000-000000000121")
        let prior = fixture.qualifiedDurableState(scope: scope)

        try await fixture.persistCoverage(from: prior)
        try await scheduler.save(
            fixture.activeSchedule(scope: scope, attemptID: priorAttempt, generation: 1)
        )
        let didFinalizePrior = try await durableRepository.finalize(
            prior,
            schedule: fixture.completedSchedule(scope: scope, generation: 1),
            for: scope,
            ifOwnedBy: priorAttempt,
            generation: 1
        )
        XCTAssertNotNil(didFinalizePrior)

        let partialCoverage = CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: nil,
            feature: .repositories,
            streamID: SyncStreamID(rawValue: "durable-state-test")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: .partial,
            lastSuccessfulAt: nil,
            failureDetail: "Refresh was cancelled before completion."
        )
        let operation = CoverageWritingCancellableOperation(
            vault: fixture.vault,
            coverage: partialCoverage,
            attemptedAt: fixture.now
        )
        let coordinator = AccountOrganizationCoordinator(
            stateStore: durableRepository,
            scheduleStore: scheduler,
            finalizer: durableRepository,
            refreshOperation: operation,
            clock: { fixture.now.addingTimeInterval(120) },
            randomUnit: { 0 },
            makeAttemptID: {
                fixture.attemptID("00000000-0000-0000-0000-000000000122")
            }
        )

        try await coordinator.select(scope)
        try await operation.awaitCoverageWrite()
        try await coordinator.cancelRefresh(
            for: AccountOrganizationScope(
                accountID: scope.accountID,
                organizationID: scope.organizationID
            )
        )

        let currentState = await coordinator.state(for: scope)
        let inMemory = try XCTUnwrap(currentState)
        XCTAssertEqual(inMemory.freshness.status, .stale)
        XCTAssertEqual(
            inMemory.durableState.cachedState?.coverage.first?.status,
            .partial
        )
        XCTAssertEqual(
            inMemory.durableState.cachedState?.coverage.first?.failureDetail,
            partialCoverage.failureDetail
        )

        try await fixture.registry.closeAll()
        let reopenedRegistry = try VaultRegistry(rootDirectory: fixture.directory)
        let reopenedVault = try await reopenedRegistry.open(
            accountID: fixture.accountID,
            vaultKey: fixture.vaultKey
        )
        let reloaded = try await AccountOrganizationDurableStateRepository(
            vault: reopenedVault
        ).loadState(for: scope)
        XCTAssertEqual(reloaded?.freshness.status, .stale)
        XCTAssertEqual(reloaded?.cachedState?.coverage.first?.status, .partial)
        XCTAssertEqual(
            reloaded?.cachedState?.coverage.first?.failureDetail,
            partialCoverage.failureDetail
        )
        try await reopenedRegistry.closeAll()
    }

    func testNewerActiveGenerationRetainsFrozenCacheButLoadsInterruptedFreshness() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let firstAttempt = fixture.attemptID("00000000-0000-0000-0000-000000000116")
        let durable = fixture.qualifiedDurableState(scope: scope)

        try await fixture.persistCoverage(from: durable)
        try await scheduler.save(
            fixture.activeSchedule(scope: scope, attemptID: firstAttempt, generation: 1)
        )
        let didFinalize = try await repository.finalize(
            durable,
            schedule: fixture.completedSchedule(scope: scope, generation: 1),
            for: scope,
            ifOwnedBy: firstAttempt,
            generation: 1
        )
        XCTAssertNotNil(didFinalize)

        let newerAttempt = fixture.attemptID("00000000-0000-0000-0000-000000000117")
        try await scheduler.save(
            fixture.activeSchedule(scope: scope, attemptID: newerAttempt, generation: 2)
        )

        let loadedState = try await repository.loadState(for: scope)
        let loaded = try XCTUnwrap(loadedState)
        XCTAssertEqual(loaded.cachedState, didFinalize?.cachedState)
        XCTAssertEqual(loaded.freshness.status, .stale)
        XCTAssertEqual(loaded.freshness.lastSuccessfulSyncAt, durable.freshness.lastSuccessfulSyncAt)
        XCTAssertNil(loaded.freshness.nextRetryAt)
        XCTAssertEqual(
            loaded.freshness.detail,
            "A previous synchronization did not complete. Cached data is retained."
        )
    }

    func testCredentialOrURLLikeFreshnessDetailsAreRejectedBeforeMutation() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000118")
        let active = fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 1)
        let durable = fixture.qualifiedDurableState(scope: scope)
        try await fixture.persistCoverage(from: durable)
        try await scheduler.save(active)
        let unsafeDetails = [
            "Authorize at https://github.example/sso?token=ghp_never-store",
            "Use ssh://github.example/private/repository",
            "Continue at github.example/private/path",
            "Authorization: token never-store-this"
        ]
        for detail in unsafeDetails {
            let unsafe = AccountOrganizationDurableState(
                cachedState: durable.cachedState,
                freshness: FreshnessState(
                    status: .fresh,
                    lastSuccessfulSyncAt: durable.freshness.lastSuccessfulSyncAt,
                    detail: detail
                )
            )
            do {
                _ = try await repository.finalize(
                    unsafe,
                    schedule: fixture.completedSchedule(scope: scope, generation: 1),
                    for: scope,
                    ifOwnedBy: attemptID,
                    generation: 1
                )
                XCTFail("Credential or URL-like material must not enter durable freshness state.")
            } catch {
                XCTAssertEqual(
                    error as? AccountOrganizationDurableStateRepositoryError,
                    .invalidProjection
                )
            }
        }

        let retainedSchedule = try await scheduler.state(for: scope)
        let counts = try await fixture.rawRowCounts()
        XCTAssertEqual(retainedSchedule, active)
        XCTAssertEqual(counts.durable, 0)
    }

    func testExtremeFinitePersistedTimestampFailsClosedWithoutProcessTrap() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let envelope = RawDurableStateEnvelope(
            formatVersion: AccountOrganizationDurableStateRepository.formatVersion,
            scope: scope,
            durableState: AccountOrganizationDurableState(
                cachedState: nil,
                freshness: FreshnessState(
                    status: .failed,
                    nextRetryAt: Date(timeIntervalSince1970: 0x1p63 / 1_000),
                    detail: "GitHub did not complete the synchronization request."
                )
            )
        )
        let payload = try JSONEncoder().encode(envelope)
        try await fixture.insertRawDurablePayload(payload, scope: scope)

        do {
            _ = try await repository.loadState(for: scope)
            XCTFail("Out-of-range finite timestamps must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationDurableStateRepositoryError,
                .invalidPersistedData
            )
        }
    }

    func testStaleRequirementManifestInvalidatesOnlyDurableAndSchedulerProjection() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let scope = fixture.scope()
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let workflow = try await fixture.installRepositoryBackedWorkflow()
        let currentRequirements = try await fixture.vault.read { database in
            try CoverageRequirementProfile.build(for: scope, coverage: [], in: database)
        }
        let staleRequirements = currentRequirements.filter {
            !($0.feature == .repositories && $0.repositoryID == workflow.repositoryID)
        }
        XCTAssertEqual(staleRequirements.count + 1, currentRequirements.count)

        let coverage = currentRequirements.map { fixture.completeCoverage($0, scope: scope) }
        for record in coverage {
            try await CoverageRepository(vault: fixture.vault).save(record, attemptedAt: fixture.now)
        }
        let cachedState = AccountOrganizationCachedState(
            coverage: coverage,
            coverageRequirements: staleRequirements,
            lastSuccessfulSyncAt: fixture.successDate
        )
        XCTAssertEqual(cachedState.freshness.status, .fresh)
        let durable = AccountOrganizationDurableState(cachedState: cachedState)
        let payload = try JSONEncoder().encode(
            RawDurableStateEnvelope(
                formatVersion: AccountOrganizationDurableStateRepository.formatVersion,
                scope: scope,
                durableState: durable
            )
        )
        try await fixture.insertRawDurablePayload(payload, scope: scope)
        try await scheduler.save(fixture.completedSchedule(scope: scope, generation: 1))

        let loaded = try await repository.loadState(for: scope)
        let counts = try await fixture.rawRowCounts()
        let retainedCoverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        let retainedWorkItems = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        let retainedWorkItem = try XCTUnwrap(retainedWorkItems.first)

        XCTAssertNil(loaded)
        XCTAssertEqual(counts.durable, 0)
        XCTAssertEqual(counts.scheduler, 0)
        XCTAssertEqual(retainedCoverage.count, coverage.count)
        XCTAssertEqual(retainedWorkItem.id, workflow.workItemID)
        XCTAssertEqual(retainedWorkItem.workflow, workflow.state)
    }

    func testConcurrentFinalizersAllowExactlyOneOwnershipWinner() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scheduler = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let attemptID = fixture.attemptID("00000000-0000-0000-0000-000000000123")
        let durable = fixture.qualifiedDurableState(scope: scope)
        let completed = fixture.completedSchedule(scope: scope, generation: 4)

        try await fixture.persistCoverage(from: durable)
        try await scheduler.save(
            fixture.activeSchedule(scope: scope, attemptID: attemptID, generation: 4)
        )
        async let first = repository.finalize(
            durable,
            schedule: completed,
            for: scope,
            ifOwnedBy: attemptID,
            generation: 4
        )
        async let second = repository.finalize(
            durable,
            schedule: completed,
            for: scope,
            ifOwnedBy: attemptID,
            generation: 4
        )
        let results = try await [first, second]
        let persistedSchedule = try await scheduler.state(for: scope)
        let persistedState = try await repository.loadState(for: scope)

        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        XCTAssertEqual(persistedSchedule, completed)
        XCTAssertEqual(persistedState, results.compactMap { $0 }.first)
    }

    func testDuplicateCoverageInDecodableEnvelopeFailsClosed() async throws {
        let fixture = try await DurableStateFixture()
        defer { fixture.remove() }
        let repository = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let scope = fixture.scope()
        let durable = fixture.qualifiedDurableState(scope: scope)
        let cached = try XCTUnwrap(durable.cachedState)
        let duplicateState = AccountOrganizationDurableState(
            cachedState: AccountOrganizationCachedState(
                coverage: cached.coverage + cached.coverage,
                lastSuccessfulSyncAt: cached.lastSuccessfulSyncAt
            ),
            freshness: durable.freshness
        )
        let payload = try JSONEncoder().encode(
            RawDurableStateEnvelope(
                formatVersion: AccountOrganizationDurableStateRepository.formatVersion,
                scope: scope,
                durableState: duplicateState
            )
        )
        try await fixture.insertRawDurablePayload(payload, scope: scope)

        do {
            _ = try await repository.loadState(for: scope)
            XCTFail("Duplicate coverage identities must fail closed after decoding.")
        } catch {
            XCTAssertEqual(
                error as? AccountOrganizationDurableStateRepositoryError,
                .invalidPersistedData
            )
        }
    }
}

private struct RawDurableStateEnvelope: Encodable {
    let formatVersion: Int
    let scope: SynchronizationScope
    let durableState: AccountOrganizationDurableState
}

private final class DurableStateFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "durable-org")!
    let credentialRevision = CredentialRevision(rawValue: "credential-initial")!
    let capabilityRevision = CapabilityRevision(rawValue: "capability-initial")!
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let vaultKey: VaultKey
    let registry: VaultRegistry
    let vault: AccountVault

    var successDate: Date { now.addingTimeInterval(60) }
    var databaseURL: URL { VaultPaths(rootDirectory: directory, accountID: accountID).database }

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-durable-state-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        vaultKey = try VaultKey.generate()
        registry = try VaultRegistry(rootDirectory: directory)
        vault = try await registry.open(accountID: accountID, vaultKey: vaultKey)

        let accounts = AccountRepository(vault: vault)
        try await accounts.save(
            GitHubAccount(
                id: accountID,
                githubUserID: 2,
                nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjI=")!,
                login: "durable-octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: now,
                lastValidatedAt: now
            ),
            credentialRevision: credentialRevision
        )
        try await accounts.save(
            GitHubOrganization(
                id: organizationID,
                githubOrganizationID: 20,
                nodeID: GitHubNodeID(rawValue: "durable-organization")!,
                login: organizationID.rawValue
            ),
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: now
            ),
            selectedAt: now
        )
    }

    func scope(
        credentialRevision: CredentialRevision? = nil,
        capabilityRevision: CapabilityRevision? = nil
    ) -> SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision ?? self.credentialRevision,
            capabilityRevision: capabilityRevision ?? self.capabilityRevision
        )
    }

    func attemptID(_ rawValue: String) -> UUID {
        UUID(uuidString: rawValue)!
    }

    func activeSchedule(
        scope: SynchronizationScope,
        attemptID: UUID,
        generation: UInt64
    ) -> OrganizationSchedulerState {
        OrganizationSchedulerState(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            nextIncrementalRefreshAt: now,
            nextFullReconciliationAt: now.addingTimeInterval(86_400),
            rateLimitedUntil: nil,
            blockedReason: nil,
            consecutiveTransientFailureCount: 0,
            activeAttemptID: attemptID,
            lastAttemptAt: now,
            lastCompletedAt: nil,
            generation: generation,
            updatedAt: now
        )
    }

    func completedSchedule(
        scope: SynchronizationScope,
        generation: UInt64
    ) -> OrganizationSchedulerState {
        OrganizationSchedulerState(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            nextIncrementalRefreshAt: successDate.addingTimeInterval(300),
            nextFullReconciliationAt: now.addingTimeInterval(86_400),
            rateLimitedUntil: nil,
            blockedReason: nil,
            consecutiveTransientFailureCount: 0,
            activeAttemptID: nil,
            lastAttemptAt: now,
            lastCompletedAt: successDate,
            generation: generation,
            updatedAt: successDate
        )
    }

    func qualifiedDurableState(
        scope: SynchronizationScope,
        successOffset: TimeInterval = 60,
        detail: String? = nil
    ) -> AccountOrganizationDurableState {
        let successfulAt = now.addingTimeInterval(successOffset)
        let coverage = CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: nil,
            feature: .repositories,
            streamID: SyncStreamID(rawValue: "durable-state-test")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: successfulAt,
            failureDetail: nil
        )
        let cachedState = AccountOrganizationCachedState(
            coverage: [coverage],
            coverageRequirements: [
                CoverageRequirement(
                    feature: coverage.feature,
                    repositoryID: coverage.repositoryID,
                    streamID: coverage.streamID,
                    intervalStart: coverage.intervalStart,
                    intervalEnd: coverage.intervalEnd
                )
            ],
            lastSuccessfulSyncAt: successfulAt
        )
        return AccountOrganizationDurableState(
            cachedState: cachedState,
            freshness: FreshnessState(
                status: cachedState.freshness.status,
                lastSuccessfulSyncAt: successfulAt,
                detail: detail
            )
        )
    }

    func completeCoverage(
        _ requirement: CoverageRequirement,
        scope: SynchronizationScope
    ) -> CoverageRecord {
        CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: requirement.repositoryID,
            feature: requirement.feature,
            streamID: requirement.streamID,
            intervalStart: requirement.intervalStart,
            intervalEnd: requirement.intervalEnd,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: successDate,
            failureDetail: nil
        )
    }

    func installRepositoryBackedWorkflow() async throws -> (
        repositoryID: RepositoryID,
        workItemID: WorkItemID,
        state: WorkflowState
    ) {
        let repositoryID = RepositoryID(rawValue: "R_durable_repository")!
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id,
                        owner_login, name, is_private, is_archived, has_discussions,
                        html_url, updated_at_ms, archived_at_ms, has_discussions_known
                    ) VALUES (?, ?, '900', ?, 'durable-org', 'retained', 1, 0, 1, ?, ?, NULL, 1)
                    """,
                arguments: [
                    repositoryID.rawValue,
                    organizationID.rawValue,
                    repositoryID.rawValue,
                    "https://github.com/durable-org/retained",
                    Int64(now.timeIntervalSince1970 * 1_000)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_repository_access (
                        account_id, repository_id, access_state, observed_at_ms
                    ) VALUES (?, ?, 'available', ?)
                    """,
                arguments: [
                    accountID.rawValue,
                    repositoryID.rawValue,
                    Int64(now.timeIntervalSince1970 * 1_000)
                ]
            )
        }
        let node = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "I_durable_retained")!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            kind: .issue,
            numericID: "901",
            number: 1,
            title: "Retained work item",
            state: .open,
            url: URL(string: "https://github.com/durable-org/retained/issues/1")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: now,
            updatedAt: now,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "retained-v1",
            observedAt: now,
            accessibility: .accessible
        )
        try await GitHubNodeRepository(vault: vault).save(node)
        let workItemID = try await WorkItemRepository(vault: vault).ensureWorkItem(for: node)
        let state = WorkflowState(
            status: .waiting,
            isPinned: true,
            priority: .high,
            localNote: "Keep this local workflow state.",
            updatedAt: successDate
        )
        try await WorkflowRepository(vault: vault).save(state, for: workItemID)
        return (repositoryID, workItemID, state)
    }

    func persistCoverage(from state: AccountOrganizationDurableState) async throws {
        let repository = CoverageRepository(vault: vault)
        for record in state.cachedState?.coverage ?? [] {
            try await repository.save(record, attemptedAt: now)
        }
    }

    func setCredentialRevision(_ revision: CredentialRevision) async throws {
        try await vault.write { database in
            try database.execute(
                sql: "UPDATE accounts SET credential_revision = ? WHERE id = ?",
                arguments: [revision.rawValue, accountID.rawValue]
            )
        }
    }

    func setCapabilityRevision(_ revision: CapabilityRevision) async throws {
        try await vault.write { database in
            try database.execute(
                sql: """
                    UPDATE account_organizations
                    SET capability_revision = ?
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [revision.rawValue, accountID.rawValue, organizationID.rawValue]
            )
        }
    }

    func insertRawDurablePayload(_ payload: Data, scope: SynchronizationScope) async throws {
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO account_organization_durable_states (
                        account_id, organization_id, credential_revision,
                        capability_revision, scheduler_generation, format_version,
                        state_payload, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    scope.accountID.rawValue,
                    scope.organizationID.rawValue,
                    scope.credentialRevision.rawValue,
                    scope.capabilityRevision.rawValue,
                    1,
                    AccountOrganizationDurableStateRepository.formatVersion,
                    payload,
                    Int64(now.timeIntervalSince1970 * 1_000)
                ]
            )
        }
    }

    func installRejectingDurableProjectionTrigger() async throws {
        try await vault.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_durable_projection_insert
                BEFORE INSERT ON account_organization_durable_states
                BEGIN
                    SELECT RAISE(ABORT, 'injected durable projection failure');
                END
                """)
        }
    }

    func removeRejectingDurableProjectionTrigger() async throws {
        try await vault.write { database in
            try database.execute(sql: "DROP TRIGGER reject_durable_projection_insert")
        }
    }

    func removeAssociation() async throws {
        try await vault.write { database in
            try database.execute(
                sql: "DELETE FROM account_organizations WHERE account_id = ? AND organization_id = ?",
                arguments: [accountID.rawValue, organizationID.rawValue]
            )
        }
    }

    func rawRowCounts() async throws -> (durable: Int, scheduler: Int) {
        try await vault.read { database in
            (
                durable: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM account_organization_durable_states"
                ) ?? 0,
                scheduler: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM organization_scheduler_states"
                ) ?? 0
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func awaitIdleState(
        from coordinator: AccountOrganizationCoordinator,
        scope: SynchronizationScope
    ) async throws -> AccountOrganizationCoordinatorState {
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            if let state = await coordinator.state(for: scope), state.phase == .idle {
                return state
            }
            await Task.yield()
        }
        throw DurableStateFixtureError.coordinatorDidNotBecomeIdle
    }
}

private enum DurableStateFixtureError: Error {
    case coordinatorDidNotBecomeIdle
}

private actor CoverageWritingFailureOperation: AccountOrganizationRefreshOperating {
    private let vault: AccountVault
    private let coverage: CoverageRecord
    private let attemptedAt: Date

    init(vault: AccountVault, coverage: CoverageRecord, attemptedAt: Date) {
        self.vault = vault
        self.coverage = coverage
        self.attemptedAt = attemptedAt
    }

    func refresh(
        _ request: AccountOrganizationRefreshRequest
    ) async throws -> AccountOrganizationCachedState {
        guard request.synchronizationScope == SynchronizationScope(
            accountID: coverage.accountID,
            organizationID: coverage.organizationID,
            credentialRevision: coverage.credentialRevision,
            capabilityRevision: coverage.capabilityRevision
        ) else {
            throw AccountOrganizationDurableStateRepositoryError.invalidProjection
        }
        try await CoverageRepository(vault: vault).save(
            coverage,
            attemptedAt: attemptedAt
        )
        throw AccountOrganizationRefreshFailure.ssoRequired(
            detail: "https://github.example/organizations/authorize"
        )
    }
}

private actor CoverageWritingCancellableOperation: AccountOrganizationRefreshOperating {
    private let vault: AccountVault
    private let coverage: CoverageRecord
    private let attemptedAt: Date
    private var didWriteCoverage = false

    init(vault: AccountVault, coverage: CoverageRecord, attemptedAt: Date) {
        self.vault = vault
        self.coverage = coverage
        self.attemptedAt = attemptedAt
    }

    func refresh(
        _ request: AccountOrganizationRefreshRequest
    ) async throws -> AccountOrganizationCachedState {
        try await CoverageRepository(vault: vault).save(
            coverage,
            attemptedAt: attemptedAt
        )
        didWriteCoverage = true
        try await Task.sleep(nanoseconds: UInt64.max)
        throw CancellationError()
    }

    func awaitCoverageWrite() async throws {
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            if didWriteCoverage { return }
            await Task.yield()
        }
        throw DurableStateFixtureError.coordinatorDidNotBecomeIdle
    }
}
