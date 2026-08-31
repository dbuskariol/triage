import Foundation
import GRDB
import XCTest
@testable import Triage

private enum AccountOrganizationRefreshRuntimeTestError: Error {
    case timedOut(String)
}

final class AccountOrganizationRefreshRuntimeTests: XCTestCase {
    func testOperationReturnsOnlyCurrentRevisionCoverageAndExactRequestPriority() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let current = try await fixture.scope()
        let stale = fixture.scope(
            credentialRevision: CredentialRevision(rawValue: "credential-stale")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-stale")!
        )
        try await fixture.saveCoverage(for: current, stream: "current")
        try await fixture.saveCoverage(for: stale, stream: "stale")
        let calls = RuntimePipelineCalls()
        let operation = AccountOrganizationRefreshOperation(vault: fixture.vault) { account, organization, synchronizationScope, priority, intent in
            await calls.append(
                account: account,
                organization: organization,
                synchronizationScope: synchronizationScope,
                priority: priority,
                reconciliationIntent: intent
            )
        }

        let result = try await operation.refresh(
            fixture.request(for: current, priority: .manual)
        )

        XCTAssertEqual(result.coverage.map(\.streamID.rawValue), ["current"])
        XCTAssertEqual(result.lastSuccessfulSyncAt, fixture.successDate)
        let recordedCall = await calls.single()
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(call.account, fixture.account)
        XCTAssertEqual(call.organization, fixture.organization(id: fixture.primaryOrganizationID))
        XCTAssertEqual(call.synchronizationScope, current)
        XCTAssertEqual(call.priority, .selectedOrganizationRefresh)
        XCTAssertEqual(call.reconciliationIntent, .incremental)
    }

    func testOperationPassesReconciliationIntentIndependentlyOfTransportPriority() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let scope = try await fixture.scope()
        let calls = RuntimePipelineCalls()
        let operation = AccountOrganizationRefreshOperation(vault: fixture.vault) { account, organization, synchronizationScope, priority, intent in
            await calls.append(
                account: account,
                organization: organization,
                synchronizationScope: synchronizationScope,
                priority: priority,
                reconciliationIntent: intent
            )
        }

        _ = try await operation.refresh(
            fixture.request(
                for: scope,
                priority: .fullReconciliation,
                requestPriority: .selectedOrganizationRefresh,
                reconciliationIntent: .incremental
            )
        )

        let recordedCall = await calls.single()
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(call.synchronizationScope, scope)
        XCTAssertEqual(call.priority, .selectedOrganizationRefresh)
        XCTAssertEqual(call.reconciliationIntent, .incremental)
    }

    func testOperationRejectsAccountAndOrganizationScopeMismatchesBeforePipeline() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let scope = try await fixture.scope()
        let calls = RuntimePipelineCalls()
        let operation = AccountOrganizationRefreshOperation(vault: fixture.vault) { account, organization, synchronizationScope, priority, intent in
            await calls.append(account: account, organization: organization, synchronizationScope: synchronizationScope, priority: priority, reconciliationIntent: intent)
        }

        var mismatchedAccountRequest = fixture.request(for: scope, priority: .manual)
        mismatchedAccountRequest = AccountOrganizationRefreshRequest(
            synchronizationScope: scope,
            scope: AccountOrganizationScope(
                accountID: AccountID.make(),
                organizationID: scope.organizationID
            ),
            token: mismatchedAccountRequest.token,
            priority: mismatchedAccountRequest.priority,
            requestPriority: mismatchedAccountRequest.requestPriority,
            reconciliationIntent: mismatchedAccountRequest.reconciliationIntent
        )
        await assertRefreshOperationError(
            .accountScopeMismatch,
            from: operation,
            request: mismatchedAccountRequest
        )

        let unavailableScope = SynchronizationScope(
            accountID: fixture.account.id,
            organizationID: OrganizationID(rawValue: "not-persisted")!,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision
        )
        await assertRefreshOperationError(
            .organizationScopeMismatch,
            from: operation,
            request: fixture.request(for: unavailableScope, priority: .manual)
        )
        let callCount = await calls.count()
        XCTAssertEqual(callCount, 0)
    }

    func testOperationCancelsBeforePipelineWhenPersistedRevisionAlreadyChanged() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let obsoleteScope = try await fixture.scope()
        try await fixture.setCredentialRevision(CredentialRevision(rawValue: "credential-new")!)
        let calls = RuntimePipelineCalls()
        let operation = AccountOrganizationRefreshOperation(vault: fixture.vault) { account, organization, synchronizationScope, priority, intent in
            await calls.append(account: account, organization: organization, synchronizationScope: synchronizationScope, priority: priority, reconciliationIntent: intent)
        }

        await assertCancellation(from: operation, request: fixture.request(for: obsoleteScope, priority: .manual))
        let callCount = await calls.count()
        XCTAssertEqual(callCount, 0)
    }

    func testOperationCancelsBeforePipelineWhenPersistedCapabilityRevisionAlreadyChanged() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let obsoleteScope = try await fixture.scope()
        try await fixture.setCapabilityRevision(CapabilityRevision(rawValue: "capability-new")!)
        let calls = RuntimePipelineCalls()
        let operation = AccountOrganizationRefreshOperation(vault: fixture.vault) { account, organization, synchronizationScope, priority, intent in
            await calls.append(account: account, organization: organization, synchronizationScope: synchronizationScope, priority: priority, reconciliationIntent: intent)
        }

        await assertCancellation(from: operation, request: fixture.request(for: obsoleteScope, priority: .manual))
        let callCount = await calls.count()
        XCTAssertEqual(callCount, 0)
    }

    func testOperationCannotReturnAStaleRevisionAfterPipelineChangesAuthority() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let obsoleteScope = try await fixture.scope()
        try await fixture.saveCoverage(for: obsoleteScope, stream: "before-revision-change")
        let calls = RuntimePipelineCalls()
        let operation = AccountOrganizationRefreshOperation(vault: fixture.vault) { account, organization, synchronizationScope, priority, intent in
            await calls.append(account: account, organization: organization, synchronizationScope: synchronizationScope, priority: priority, reconciliationIntent: intent)
            try await fixture.setCredentialRevision(CredentialRevision(rawValue: "credential-new")!)
        }

        await assertCancellation(from: operation, request: fixture.request(for: obsoleteScope, priority: .manual))
        let callCount = await calls.count()
        XCTAssertEqual(callCount, 1)
        let durable = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        do {
            _ = try await durable.loadState(for: obsoleteScope)
            XCTFail("The operation does not own a finalizer and must not create a stale durable projection.")
        } catch AccountOrganizationDurableStateRepositoryError.staleSynchronizationScope {
            // Exact-scope validation rejected the obsolete authority.
        }
    }

    func testRuntimeCannotFinalizeAStaleRevisionAfterPipelineChangesAuthority() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let obsoleteScope = try await fixture.scope()
        let operation = AccountOrganizationRefreshOperation(vault: fixture.vault) { _, _, _, _, _ in
            try await fixture.setCredentialRevision(CredentialRevision(rawValue: "credential-new")!)
        }
        let runtime = AccountOrganizationRefreshRuntime(
            accountID: fixture.account.id,
            vault: fixture.vault,
            refreshOperation: operation
        )

        let state = try await runtime.refresh(
            organizationID: obsoleteScope.organizationID,
            priority: .manual
        )
        XCTAssertEqual(state?.phase, .idle)
        XCTAssertEqual(state?.freshness.status, .failed)

        let durable = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        do {
            _ = try await durable.loadState(for: obsoleteScope)
            XCTFail("The obsolete scope must not receive a finalized durable projection.")
        } catch AccountOrganizationDurableStateRepositoryError.staleSynchronizationScope {
            // The finalizer failed closed against the new persisted authority.
        }
        let currentScope = try await fixture.scope()
        let currentDurable = try await durable.loadState(for: currentScope)
        XCTAssertNil(currentDurable)
    }

    func testRevisionQualifiedRuntimeRefreshCancelsBeforeDispatchForObsoleteCredential() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let obsoleteScope = try await fixture.scope()
        try await fixture.setCredentialRevision(CredentialRevision(rawValue: "credential-new")!)
        let operation = RuntimeInvocationCountingOperation()
        let runtime = AccountOrganizationRefreshRuntime(
            accountID: fixture.account.id,
            vault: fixture.vault,
            refreshOperation: operation
        )

        do {
            _ = try await runtime.refresh(obsoleteScope, priority: .manual)
            XCTFail("An obsolete credential scope must cancel before dispatch.")
        } catch is CancellationError {
            // Expected.
        }

        let invocationCount = await operation.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testRevisionQualifiedRuntimeSelectCancelsBeforeDispatchForObsoleteCapability() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let obsoleteScope = try await fixture.scope()
        try await fixture.setCapabilityRevision(CapabilityRevision(rawValue: "capability-new")!)
        let operation = RuntimeInvocationCountingOperation()
        let runtime = AccountOrganizationRefreshRuntime(
            accountID: fixture.account.id,
            vault: fixture.vault,
            refreshOperation: operation
        )

        do {
            _ = try await runtime.select(obsoleteScope)
            XCTFail("An obsolete capability scope must cancel before dispatch.")
        } catch is CancellationError {
            // Expected.
        }

        let invocationCount = await operation.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testOperationUsesPersistedAccountAndOrganizationInsteadOfCallerScopeValues() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let scope = try await fixture.scope()
        let calls = RuntimePipelineCalls()
        let operation = AccountOrganizationRefreshOperation(vault: fixture.vault) { account, organization, synchronizationScope, priority, intent in
            await calls.append(account: account, organization: organization, synchronizationScope: synchronizationScope, priority: priority, reconciliationIntent: intent)
        }

        _ = try await operation.refresh(fixture.request(for: scope, priority: .selectedOrganization))

        let recordedCall = await calls.single()
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(call.account.login, "persisted-account")
        XCTAssertEqual(call.account.githubUserID, 42)
        XCTAssertEqual(call.organization.login, "persisted-organization")
        XCTAssertEqual(call.organization.githubOrganizationID, 84)
    }

    func testRuntimeSuccessPersistsCoordinatorScheduleAndProjectionAcrossVaultReopen() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let scope = try await fixture.scope()
        let operation = AccountOrganizationRefreshOperation(vault: fixture.vault) { _, _, _, _, _ in
            try await fixture.saveCoverage(for: scope, stream: "runtime-success")
        }
        let runtime = AccountOrganizationRefreshRuntime(
            accountID: fixture.account.id,
            vault: fixture.vault,
            refreshOperation: operation
        )

        let state = try await runtime.refresh(
            organizationID: scope.organizationID,
            priority: .manual
        )
        XCTAssertEqual(state?.phase, .idle)
        XCTAssertEqual(state?.freshness.status, .partial)
        XCTAssertEqual(state?.durableState.cachedState?.coverage.map(\.streamID.rawValue), ["runtime-success"])

        let reopenedRegistry = try VaultRegistry(rootDirectory: fixture.directory)
        let reopenedVault = try await reopenedRegistry.open(
            accountID: fixture.account.id,
            vaultKey: fixture.vaultKey
        )
        let reopenedScope = try await AccountRepository(vault: reopenedVault).synchronizationScope(
            for: fixture.account.id,
            organizationID: scope.organizationID
        )
        let loadedDurable = try await AccountOrganizationDurableStateRepository(vault: reopenedVault)
            .loadState(for: reopenedScope)
        let durable = try XCTUnwrap(loadedDurable)
        let loadedSchedule = try await OrganizationSchedulerStateRepository(vault: reopenedVault)
            .state(for: reopenedScope)
        let schedule = try XCTUnwrap(loadedSchedule)
        XCTAssertEqual(durable.freshness.status, .partial)
        XCTAssertEqual(durable.cachedState?.coverage.map(\.streamID.rawValue), ["runtime-success"])
        XCTAssertNil(schedule.activeAttemptID)
        XCTAssertNotNil(schedule.lastCompletedAt)
    }

    func testCallerCancellationFinalizesDurableInterruptionState() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let scope = try await fixture.scope()
        let operation = RuntimeCancellableOperation()
        let runtime = AccountOrganizationRefreshRuntime(
            accountID: fixture.account.id,
            vault: fixture.vault,
            refreshOperation: operation
        )
        let refresh = Task {
            try await runtime.refresh(
                organizationID: scope.organizationID,
                priority: .manual
            )
        }
        try await operation.awaitStart(count: 1)

        refresh.cancel()
        do {
            _ = try await refresh.value
            XCTFail("Cancelling the caller must surface CancellationError.")
        } catch is CancellationError {
            // Expected: the runtime forwards cancellation to the coordinator.
        }

        let durable = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let stored = try await awaitDurableState(durable, scope: scope)
        let loadedSchedule = try await OrganizationSchedulerStateRepository(vault: fixture.vault)
            .state(for: scope)
        let schedule = try XCTUnwrap(loadedSchedule)
        XCTAssertEqual(stored.freshness.status, .stale)
        XCTAssertNil(schedule.activeAttemptID)
    }

    func testCallerCancellationDoesNotWaitForNonCooperativeOperation() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let scope = try await fixture.scope()
        let operation = RuntimeNonCooperativeOperation { request in
            RuntimeRefreshFixture.cachedState(
                for: request.synchronizationScope,
                date: .distantFuture
            )
        }
        let runtime = AccountOrganizationRefreshRuntime(
            accountID: fixture.account.id,
            vault: fixture.vault,
            refreshOperation: operation
        )
        let refresh = Task {
            try await runtime.refresh(
                organizationID: scope.organizationID,
                priority: .manual
            )
        }
        let completion = RuntimeCancellationCompletion()
        let observer = Task {
            do {
                _ = try await refresh.value
                await completion.recordUnexpectedCompletion("refresh succeeded")
            } catch is CancellationError {
                await completion.recordCancellation()
            } catch {
                await completion.recordUnexpectedCompletion(String(describing: error))
            }
        }
        try await operation.awaitStart(count: 1)

        refresh.cancel()
        do {
            try await completion.awaitCancellation()
        } catch {
            await operation.releaseAll()
            _ = await observer.result
            throw error
        }

        let durable = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        let interrupted = try await awaitDurableState(durable, scope: scope)
        let loadedSchedule = try await OrganizationSchedulerStateRepository(vault: fixture.vault)
            .state(for: scope)
        XCTAssertEqual(interrupted.freshness.status, .stale)
        XCTAssertNil(try XCTUnwrap(loadedSchedule).activeAttemptID)

        await operation.releaseAll()
        _ = await observer.result
        let afterDelayedCompletion = try await durable.loadState(for: scope)
        XCTAssertEqual(afterDelayedCompletion?.freshness.status, .stale)
    }

    func testCancelAllFinalizesSiblingScopesAndIgnoresDelayedCompletions() async throws {
        let fixture = try await RuntimeRefreshFixture(organizationIDs: ["first", "second"])
        defer { fixture.remove() }
        let first = try await fixture.scope(organizationID: fixture.primaryOrganizationID)
        let second = try await fixture.scope(organizationID: fixture.secondaryOrganizationID!)
        let operation = RuntimeNonCooperativeOperation { request in
            RuntimeRefreshFixture.cachedState(for: request.synchronizationScope, date: .distantFuture)
        }
        let runtime = AccountOrganizationRefreshRuntime(
            accountID: fixture.account.id,
            vault: fixture.vault,
            refreshOperation: operation
        )
        let firstRefresh = Task {
            try await runtime.refresh(organizationID: first.organizationID, priority: .manual)
        }
        let secondRefresh = Task {
            try await runtime.refresh(organizationID: second.organizationID, priority: .manual)
        }
        try await operation.awaitStart(count: 2)

        try await runtime.cancelAll()
        let durable = AccountOrganizationDurableStateRepository(vault: fixture.vault)
        for scope in [first, second] {
            let state = try await awaitDurableState(durable, scope: scope)
            let loadedSchedule = try await OrganizationSchedulerStateRepository(vault: fixture.vault)
                .state(for: scope)
            let schedule = try XCTUnwrap(loadedSchedule)
            XCTAssertEqual(state.freshness.status, .stale)
            XCTAssertNil(schedule.activeAttemptID)
        }

        await operation.releaseAll()
        await assertCancellation(from: firstRefresh)
        await assertCancellation(from: secondRefresh)
        for scope in [first, second] {
            let state = try await durable.loadState(for: scope)
            XCTAssertEqual(state?.freshness.status, .stale)
        }
    }

    func testCancelAllGateRejectsScopeResolutionThatFinishesDuringTeardown() async throws {
        let fixture = try await RuntimeRefreshFixture()
        defer { fixture.remove() }
        let scope = try await fixture.scope()
        let resolver = RuntimeScopeResolverGate(scope: scope)
        let operation = RuntimeInvocationCountingOperation()
        let runtime = AccountOrganizationRefreshRuntime(
            accountID: fixture.account.id,
            vault: fixture.vault,
            refreshOperation: operation,
            scopeResolver: { accountID, organizationID in
                try await resolver.resolve(accountID: accountID, organizationID: organizationID)
            }
        )
        let refresh = Task {
            try await runtime.refresh(
                organizationID: scope.organizationID,
                priority: .manual
            )
        }
        try await resolver.awaitStart()

        try await runtime.cancelAll()
        await resolver.release()

        do {
            _ = try await refresh.value
            XCTFail("A scope resolved during teardown must not start refresh work.")
        } catch {
            XCTAssertEqual(error as? AccountOrganizationRefreshRuntimeError, .tearingDown)
        }
        let invocationCount = await operation.invocationCount()
        XCTAssertEqual(invocationCount, 0)

        do {
            _ = try await runtime.refresh(
                organizationID: scope.organizationID,
                priority: .manual
            )
            XCTFail("A torn-down runtime must reject future refreshes.")
        } catch {
            XCTAssertEqual(error as? AccountOrganizationRefreshRuntimeError, .tearingDown)
        }
    }

    func testAccountRuntimesPersistOnlyTheirOwnVaultState() async throws {
        let firstFixture = try await RuntimeRefreshFixture(organizationIDs: ["shared-organization"])
        let secondFixture = try await RuntimeRefreshFixture(organizationIDs: ["shared-organization"])
        defer {
            firstFixture.remove()
            secondFixture.remove()
        }
        let firstScope = try await firstFixture.scope()
        let secondScope = try await secondFixture.scope()
        let firstOperation = AccountOrganizationRefreshOperation(vault: firstFixture.vault) { _, _, _, _, _ in
            try await firstFixture.saveCoverage(for: firstScope, stream: "first-account")
        }
        let secondOperation = AccountOrganizationRefreshOperation(vault: secondFixture.vault) { _, _, _, _, _ in
            try await secondFixture.saveCoverage(for: secondScope, stream: "second-account")
        }
        let firstRuntime = AccountOrganizationRefreshRuntime(
            accountID: firstFixture.account.id,
            vault: firstFixture.vault,
            refreshOperation: firstOperation
        )
        let secondRuntime = AccountOrganizationRefreshRuntime(
            accountID: secondFixture.account.id,
            vault: secondFixture.vault,
            refreshOperation: secondOperation
        )

        async let firstState = firstRuntime.refresh(
            organizationID: firstScope.organizationID,
            priority: .manual
        )
        async let secondState = secondRuntime.refresh(
            organizationID: secondScope.organizationID,
            priority: .manual
        )
        let firstResult = try await firstState
        let secondResult = try await secondState
        XCTAssertEqual(firstResult?.durableState.cachedState?.coverage.map(\.streamID.rawValue), ["first-account"])
        XCTAssertEqual(secondResult?.durableState.cachedState?.coverage.map(\.streamID.rawValue), ["second-account"])

        let loadedFirstDurable = try await AccountOrganizationDurableStateRepository(vault: firstFixture.vault)
            .loadState(for: firstScope)
        let firstDurable = try XCTUnwrap(loadedFirstDurable)
        let loadedSecondDurable = try await AccountOrganizationDurableStateRepository(vault: secondFixture.vault)
            .loadState(for: secondScope)
        let secondDurable = try XCTUnwrap(loadedSecondDurable)
        XCTAssertEqual(firstDurable.cachedState?.coverage.map(\.streamID.rawValue), ["first-account"])
        XCTAssertEqual(secondDurable.cachedState?.coverage.map(\.streamID.rawValue), ["second-account"])
    }
}

private final class RuntimeRefreshFixture: @unchecked Sendable {
    let directory: URL
    let registry: VaultRegistry
    let vaultKey: VaultKey
    let vault: AccountVault
    let account: GitHubAccount
    let credentialRevision = CredentialRevision(rawValue: "credential-initial")!
    let capabilityRevision = CapabilityRevision(rawValue: "capability-initial")!
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let organizationIDs: [OrganizationID]

    var primaryOrganizationID: OrganizationID { organizationIDs[0] }
    var secondaryOrganizationID: OrganizationID? { organizationIDs.dropFirst().first }
    var successDate: Date { now.addingTimeInterval(60) }

    init(organizationIDs: [String] = ["persisted-organization"]) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-runtime-refresh-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        registry = try VaultRegistry(rootDirectory: directory)
        vaultKey = try VaultKey.generate()
        let accountID = AccountID.make()
        vault = try await registry.open(accountID: accountID, vaultKey: vaultKey)
        account = GitHubAccount(
            id: accountID,
            githubUserID: 42,
            nodeID: GitHubNodeID(rawValue: "U_runtime_42")!,
            login: "persisted-account",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: now,
            lastValidatedAt: now
        )
        self.organizationIDs = organizationIDs.compactMap(OrganizationID.init(rawValue:))
        precondition(self.organizationIDs.count == organizationIDs.count && !self.organizationIDs.isEmpty)
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(account, credentialRevision: credentialRevision)
        for (index, organizationID) in self.organizationIDs.enumerated() {
            try await accounts.save(
                organization(id: organizationID, index: index),
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
    }

    func organization(id: OrganizationID, index: Int = 0) -> GitHubOrganization {
        GitHubOrganization(
            id: id,
            githubOrganizationID: UInt64(84 + index),
            nodeID: GitHubNodeID(rawValue: "O_runtime_\(index)")!,
            login: id.rawValue
        )
    }

    func scope(
        organizationID: OrganizationID? = nil,
        credentialRevision: CredentialRevision? = nil,
        capabilityRevision: CapabilityRevision? = nil
    ) -> SynchronizationScope {
        SynchronizationScope(
            accountID: account.id,
            organizationID: organizationID ?? primaryOrganizationID,
            credentialRevision: credentialRevision ?? self.credentialRevision,
            capabilityRevision: capabilityRevision ?? self.capabilityRevision
        )
    }

    func scope(organizationID: OrganizationID? = nil) async throws -> SynchronizationScope {
        try await AccountRepository(vault: vault).synchronizationScope(
            for: account.id,
            organizationID: organizationID ?? primaryOrganizationID
        )
    }

    func request(
        for scope: SynchronizationScope,
        priority: AccountOrganizationRefreshPriority,
        requestPriority: GitHubRequestPriority? = nil,
        reconciliationIntent: SynchronizationReconciliationIntent? = nil
    ) -> AccountOrganizationRefreshRequest {
        AccountOrganizationRefreshRequest(
            synchronizationScope: scope,
            scope: AccountOrganizationScope(
                accountID: scope.accountID,
                organizationID: scope.organizationID
            ),
            token: AccountOrganizationRequestToken(rawValue: 1),
            priority: priority,
            requestPriority: requestPriority ?? priority.requestPriority,
            reconciliationIntent: reconciliationIntent
                ?? (priority == .fullReconciliation ? .fullReconciliation : .incremental)
        )
    }

    func saveCoverage(for scope: SynchronizationScope, stream: String) async throws {
        try await CoverageRepository(vault: vault).save(
            Self.coverage(scope: scope, stream: stream, date: successDate),
            attemptedAt: now
        )
    }

    func setCredentialRevision(_ revision: CredentialRevision) async throws {
        try await vault.write { database in
            try database.execute(
                sql: "UPDATE accounts SET credential_revision = ? WHERE id = ?",
                arguments: [revision.rawValue, account.id.rawValue]
            )
        }
    }

    func setCapabilityRevision(_ revision: CapabilityRevision) async throws {
        try await vault.write { database in
            try database.execute(
                sql: "UPDATE account_organizations SET capability_revision = ? WHERE account_id = ? AND organization_id = ?",
                arguments: [revision.rawValue, account.id.rawValue, primaryOrganizationID.rawValue]
            )
        }
    }

    static func coverage(
        scope: SynchronizationScope,
        stream: String,
        date: Date
    ) -> CoverageRecord {
        CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: nil,
            feature: .repositories,
            streamID: SyncStreamID(rawValue: stream)!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: date,
            failureDetail: nil
        )
    }

    static func cachedState(for scope: SynchronizationScope, date: Date) -> AccountOrganizationCachedState {
        AccountOrganizationCachedState(
            coverage: [coverage(scope: scope, stream: "non-cooperative", date: date)],
            lastSuccessfulSyncAt: date
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RuntimePipelineCalls {
    struct Call: Sendable {
        let account: GitHubAccount
        let organization: GitHubOrganization
        let synchronizationScope: SynchronizationScope
        let priority: GitHubRequestPriority
        let reconciliationIntent: SynchronizationReconciliationIntent
    }

    private var values: [Call] = []

    func append(
        account: GitHubAccount,
        organization: GitHubOrganization,
        synchronizationScope: SynchronizationScope,
        priority: GitHubRequestPriority,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) {
        values.append(
            Call(
                account: account,
                organization: organization,
                synchronizationScope: synchronizationScope,
                priority: priority,
                reconciliationIntent: reconciliationIntent
            )
        )
    }

    func count() -> Int { values.count }
    func single() -> Call? { values.count == 1 ? values[0] : nil }
}

private actor RuntimeCancellableOperation: AccountOrganizationRefreshOperating {
    private var started = 0

    func refresh(_ request: AccountOrganizationRefreshRequest) async throws -> AccountOrganizationCachedState {
        started += 1
        try await Task.sleep(nanoseconds: UInt64.max)
        throw CancellationError()
    }

    func awaitStart(count: Int) async throws {
        for _ in 0..<100_000 {
            if started >= count { return }
            await Task.yield()
        }
        throw AccountOrganizationRefreshRuntimeTestError.timedOut("cancellable operation did not start")
    }
}

private actor RuntimeNonCooperativeOperation: AccountOrganizationRefreshOperating {
    typealias StateFactory = @Sendable (AccountOrganizationRefreshRequest) -> AccountOrganizationCachedState

    private let stateFactory: StateFactory
    private var startedScopes: Set<AccountOrganizationScope> = []
    private var released = false

    init(stateFactory: @escaping StateFactory) {
        self.stateFactory = stateFactory
    }

    func refresh(_ request: AccountOrganizationRefreshRequest) async throws -> AccountOrganizationCachedState {
        startedScopes.insert(request.scope)
        while !released {
            await Task.yield()
        }
        return stateFactory(request)
    }

    func awaitStart(count: Int) async throws {
        for _ in 0..<100_000 {
            if startedScopes.count >= count { return }
            await Task.yield()
        }
        throw AccountOrganizationRefreshRuntimeTestError.timedOut("non-cooperative operation did not start")
    }

    func releaseAll() {
        released = true
    }
}

private actor RuntimeCancellationCompletion {
    private var wasCancelled = false
    private var unexpectedCompletion: String?

    func recordCancellation() {
        wasCancelled = true
    }

    func recordUnexpectedCompletion(_ detail: String) {
        unexpectedCompletion = detail
    }

    func awaitCancellation() async throws {
        for _ in 0..<100_000 {
            if wasCancelled { return }
            if let unexpectedCompletion {
                throw AccountOrganizationRefreshRuntimeTestError.timedOut(
                    "unexpected refresh completion: \(unexpectedCompletion)"
                )
            }
            await Task.yield()
        }
        throw AccountOrganizationRefreshRuntimeTestError.timedOut(
            "cancelled runtime refresh did not return promptly"
        )
    }
}

private actor RuntimeScopeResolverGate {
    private let scope: SynchronizationScope
    private var started = false
    private var released = false

    init(scope: SynchronizationScope) {
        self.scope = scope
    }

    func resolve(
        accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> SynchronizationScope {
        guard accountID == scope.accountID,
              organizationID == scope.organizationID
        else {
            throw AccountOrganizationRefreshOperationError.organizationScopeMismatch
        }
        started = true
        while !released {
            await Task.yield()
        }
        return scope
    }

    func awaitStart() async throws {
        for _ in 0..<100_000 {
            if started { return }
            await Task.yield()
        }
        throw AccountOrganizationRefreshRuntimeTestError.timedOut(
            "scope resolver did not start"
        )
    }

    func release() {
        released = true
    }
}

private actor RuntimeInvocationCountingOperation: AccountOrganizationRefreshOperating {
    private var invocations = 0

    func refresh(
        _ request: AccountOrganizationRefreshRequest
    ) async throws -> AccountOrganizationCachedState {
        invocations += 1
        return RuntimeRefreshFixture.cachedState(
            for: request.synchronizationScope,
            date: .distantFuture
        )
    }

    func invocationCount() -> Int {
        invocations
    }
}

private func assertRefreshOperationError(
    _ expected: AccountOrganizationRefreshOperationError,
    from operation: AccountOrganizationRefreshOperation,
    request: AccountOrganizationRefreshRequest,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation.refresh(request)
        XCTFail("Expected refresh operation error \(expected).", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? AccountOrganizationRefreshOperationError, expected, file: file, line: line)
    }
}

private func assertCancellation(
    from operation: AccountOrganizationRefreshOperation,
    request: AccountOrganizationRefreshRequest,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation.refresh(request)
        XCTFail("Expected CancellationError.", file: file, line: line)
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("Expected CancellationError, received \(error).", file: file, line: line)
    }
}

private func assertCancellation(
    from task: Task<AccountOrganizationCoordinatorState?, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await task.value
        XCTFail("Expected CancellationError.", file: file, line: line)
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("Expected CancellationError, received \(error).", file: file, line: line)
    }
}

private func awaitDurableState(
    _ repository: AccountOrganizationDurableStateRepository,
    scope: SynchronizationScope
) async throws -> AccountOrganizationDurableState {
    for _ in 0..<100_000 {
        if let state = try await repository.loadState(for: scope) {
            return state
        }
        await Task.yield()
    }
    throw AccountOrganizationRefreshRuntimeTestError.timedOut("durable interruption was not persisted")
}
