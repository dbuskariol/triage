import GRDB
import XCTest
@testable import Triage

final class OrganizationSchedulerStateRepositoryTests: XCTestCase {
    func testStateRoundTripsAndReplacesOnlyItsOrganizationSchedule() async throws {
        let fixture = try await SchedulerFixture()
        defer { fixture.remove() }
        let repository = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let first = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 1,
            nextIncrementalOffset: 60
        )
        let second = fixture.state(
            organizationID: fixture.secondOrganizationID,
            failureCount: 2,
            nextIncrementalOffset: 120
        )
        try await repository.save(first)
        try await repository.save(second)
        let replacement = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 0,
            nextIncrementalOffset: 300,
            generation: 2,
            lastCompletedAt: fixture.now
        )

        try await repository.save(replacement)

        let storedFirst = try await repository.state(
            for: fixture.scope(organizationID: fixture.firstOrganizationID)
        )
        XCTAssertEqual(storedFirst, replacement)
        let states = try await repository.states(for: fixture.accountID)
        XCTAssertEqual(states, [second, replacement])
    }

    func testRevisionChangeInvalidatesDeadlinesBackoffAndBlocks() async throws {
        let fixture = try await SchedulerFixture()
        defer { fixture.remove() }
        let repository = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let stale = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 4,
            nextIncrementalOffset: 3_600,
            rateLimitedUntil: fixture.now.addingTimeInterval(7_200),
            blockedReason: .ssoRequired
        )
        try await repository.save(stale)
        let currentScope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.firstOrganizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-current")!,
            capabilityRevision: fixture.capabilityRevision
        )

        let state = try await repository.state(for: currentScope)
        let remainingStates = try await repository.states(for: fixture.accountID)

        XCTAssertNil(state)
        XCTAssertTrue(remainingStates.isEmpty)
    }

    func testAttemptOwnershipRejectsStaleCompletion() async throws {
        let fixture = try await SchedulerFixture()
        defer { fixture.remove() }
        let repository = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let staleAttemptID = UUID()
        let currentAttemptID = UUID()
        let staleAttempt = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 0,
            nextIncrementalOffset: 0,
            activeAttemptID: staleAttemptID,
            generation: 1
        )
        let currentAttempt = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 0,
            nextIncrementalOffset: 0,
            activeAttemptID: currentAttemptID,
            generation: 2
        )
        try await repository.save(staleAttempt)
        try await repository.save(currentAttempt)
        let staleCompletion = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 0,
            nextIncrementalOffset: 300,
            generation: 1,
            lastCompletedAt: fixture.now
        )

        let didReplace = try await repository.replace(
            staleCompletion,
            ifOwnedBy: staleAttemptID,
            generation: 1
        )

        XCTAssertFalse(didReplace)
        let retained = try await repository.state(
            for: fixture.scope(organizationID: fixture.firstOrganizationID)
        )
        XCTAssertEqual(retained, currentAttempt)

        let currentCompletion = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 0,
            nextIncrementalOffset: 300,
            generation: 2,
            lastAttemptAt: fixture.now,
            lastCompletedAt: fixture.now
        )
        let didCompleteCurrent = try await repository.replace(
            currentCompletion,
            ifOwnedBy: currentAttemptID,
            generation: 2
        )
        XCTAssertTrue(didCompleteCurrent)
        let completed = try await repository.state(
            for: fixture.scope(organizationID: fixture.firstOrganizationID)
        )
        XCTAssertEqual(completed, currentCompletion)
    }

    func testCancellationRetainsPriorCompletionAndRequiresAttemptGeneration() async throws {
        let fixture = try await SchedulerFixture()
        defer { fixture.remove() }
        let repository = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let attemptID = UUID()
        let priorCompletion = fixture.now.addingTimeInterval(-60)
        let active = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 2,
            nextIncrementalOffset: 600,
            activeAttemptID: attemptID,
            generation: 7,
            lastAttemptAt: fixture.now,
            lastCompletedAt: priorCompletion
        )
        try await repository.save(active)
        let cancelled = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 2,
            nextIncrementalOffset: 600,
            generation: 7,
            lastAttemptAt: fixture.now,
            lastCompletedAt: priorCompletion,
            updatedAt: fixture.now.addingTimeInterval(1)
        )

        do {
            _ = try await repository.replace(
                cancelled,
                ifOwnedBy: attemptID,
                generation: 6
            )
            XCTFail("The replacement state must match its claimed attempt generation.")
        } catch {
            XCTAssertEqual(
                error as? OrganizationSchedulerStateRepositoryError,
                .staleGeneration
            )
        }
        let didCancel = try await repository.replace(
            cancelled,
            ifOwnedBy: attemptID,
            generation: 7
        )

        XCTAssertTrue(didCancel)
        let stored = try await repository.state(
            for: fixture.scope(organizationID: fixture.firstOrganizationID)
        )
        XCTAssertEqual(stored, cancelled)
    }

    func testRepositoryRejectsForeignAccountAndUnassociatedOrganization() async throws {
        let fixture = try await SchedulerFixture()
        defer { fixture.remove() }
        let repository = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let foreignAccountID = AccountID.make()
        let foreignState = fixture.state(
            accountID: foreignAccountID,
            organizationID: fixture.firstOrganizationID,
            failureCount: 0,
            nextIncrementalOffset: 0
        )

        do {
            try await repository.save(foreignState)
            XCTFail("A scheduler state cannot cross its encrypted account vault.")
        } catch {
            XCTAssertEqual(error as? OrganizationSchedulerStateRepositoryError, .accountScopeMismatch)
        }
        do {
            _ = try await repository.state(
                for: SynchronizationScope(
                    accountID: foreignAccountID,
                    organizationID: fixture.firstOrganizationID,
                    credentialRevision: fixture.credentialRevision,
                    capabilityRevision: fixture.capabilityRevision
                )
            )
            XCTFail("A scheduler state read cannot cross its encrypted account vault.")
        } catch {
            XCTAssertEqual(error as? OrganizationSchedulerStateRepositoryError, .accountScopeMismatch)
        }

        let unassociated = fixture.state(
            organizationID: OrganizationID(rawValue: "unassociated")!,
            failureCount: 0,
            nextIncrementalOffset: 0
        )
        do {
            try await repository.save(unassociated)
            XCTFail("A scheduler state requires an account-organization association.")
        } catch {
            XCTAssertEqual(error as? OrganizationSchedulerStateRepositoryError, .organizationScopeMismatch)
        }
    }

    func testRepositoryRejectsInvalidFailureCountGenerationAndTimestampOrder() async throws {
        let fixture = try await SchedulerFixture()
        defer { fixture.remove() }
        let repository = OrganizationSchedulerStateRepository(vault: fixture.vault)
        let excessiveFailures = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: OrganizationSchedulerStateRepository.maximumConsecutiveFailureCount + 1,
            nextIncrementalOffset: 60
        )
        do {
            try await repository.save(excessiveFailures)
            XCTFail("Failure progression must remain bounded.")
        } catch {
            XCTAssertEqual(error as? OrganizationSchedulerStateRepositoryError, .invalidFailureCount)
        }

        let excessiveGeneration = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 0,
            nextIncrementalOffset: 60,
            generation: UInt64(Int64.max) + 1
        )
        do {
            try await repository.save(excessiveGeneration)
            XCTFail("Persisted generations must fit SQLite's signed integer range.")
        } catch {
            XCTAssertEqual(error as? OrganizationSchedulerStateRepositoryError, .invalidGeneration)
        }

        let reversed = fixture.state(
            organizationID: fixture.firstOrganizationID,
            failureCount: 0,
            nextIncrementalOffset: 60,
            activeAttemptID: UUID(),
            lastAttemptAt: fixture.now.addingTimeInterval(2),
            lastCompletedAt: fixture.now.addingTimeInterval(3),
            updatedAt: fixture.now.addingTimeInterval(3)
        )
        do {
            try await repository.save(reversed)
            XCTFail("An active attempt cannot follow a newer completion.")
        } catch {
            XCTAssertEqual(error as? OrganizationSchedulerStateRepositoryError, .invalidTimestampOrder)
        }
    }

    func testRemovingAssociationCascadesSchedulerState() async throws {
        let fixture = try await SchedulerFixture()
        defer { fixture.remove() }
        let repository = OrganizationSchedulerStateRepository(vault: fixture.vault)
        try await repository.save(
            fixture.state(
                organizationID: fixture.firstOrganizationID,
                failureCount: 0,
                nextIncrementalOffset: 60
            )
        )

        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    DELETE FROM account_organizations
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [fixture.accountID.rawValue, fixture.firstOrganizationID.rawValue]
            )
        }

        let states = try await repository.states(for: fixture.accountID)
        XCTAssertTrue(states.isEmpty)
    }
}

private final class SchedulerFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let firstOrganizationID = OrganizationID(rawValue: "first")!
    let secondOrganizationID = OrganizationID(rawValue: "second")!
    let credentialRevision = CredentialRevision(rawValue: "credential")!
    let capabilityRevision = CapabilityRevision(rawValue: "capability")!
    let now = Date(timeIntervalSinceReferenceDate: 10_000)
    let vault: AccountVault

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: now,
            lastValidatedAt: now
        )
        let repository = AccountRepository(vault: vault)
        try await repository.save(account, credentialRevision: credentialRevision)
        try await repository.save(
            organization(firstOrganizationID, githubID: 10),
            access: access(firstOrganizationID),
            selectedAt: now
        )
        try await repository.save(
            organization(secondOrganizationID, githubID: 20),
            access: access(secondOrganizationID),
            selectedAt: nil
        )
    }

    func scope(organizationID: OrganizationID) -> SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
    }

    func state(
        accountID: AccountID? = nil,
        organizationID: OrganizationID,
        failureCount: Int,
        nextIncrementalOffset: TimeInterval,
        rateLimitedUntil: Date? = nil,
        blockedReason: OrganizationRefreshBlockReason? = nil,
        activeAttemptID: UUID? = nil,
        generation: UInt64 = 1,
        lastAttemptAt: Date? = nil,
        lastCompletedAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> OrganizationSchedulerState {
        OrganizationSchedulerState(
            accountID: accountID ?? self.accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            nextIncrementalRefreshAt: now.addingTimeInterval(nextIncrementalOffset),
            nextFullReconciliationAt: now.addingTimeInterval(24 * 60 * 60),
            rateLimitedUntil: rateLimitedUntil,
            blockedReason: blockedReason,
            consecutiveTransientFailureCount: failureCount,
            activeAttemptID: activeAttemptID,
            lastAttemptAt: lastAttemptAt ?? (activeAttemptID == nil ? nil : now),
            lastCompletedAt: lastCompletedAt,
            generation: generation,
            updatedAt: updatedAt ?? [now, lastAttemptAt ?? now, lastCompletedAt ?? now].max()!
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func organization(_ id: OrganizationID, githubID: UInt64) -> GitHubOrganization {
        GitHubOrganization(
            id: id,
            githubOrganizationID: githubID,
            nodeID: GitHubNodeID(rawValue: "organization-\(githubID)")!,
            login: id.rawValue
        )
    }

    private func access(_ organizationID: OrganizationID) -> OrganizationAccess {
        OrganizationAccess(
            accountID: accountID,
            organizationID: organizationID,
            state: .available,
            capabilityRevision: capabilityRevision,
            capabilities: [],
            checkedAt: now
        )
    }
}
