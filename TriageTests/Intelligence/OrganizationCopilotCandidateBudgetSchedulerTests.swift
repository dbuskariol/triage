import Foundation
import XCTest

@testable import Triage

final class OrganizationCopilotCandidateBudgetSchedulerTests: XCTestCase {
    func testPrioritySourceAndDailyBudgetsAreDurable() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let policy = OrganizationCopilotCandidateBudgetPolicy(
            maximumCandidatesPerUTCDate: 2,
            maximumCandidatesPerSourceFingerprint: 1,
            minimumStartInterval: 0,
            maximumConcurrentCandidates: 1,
            maximumLeaseDuration: 60
        )
        let scheduler = OrganizationCopilotCandidateBudgetScheduler(
            vault: fixture.vault,
            policy: policy,
            now: { fixture.now }
        )

        let first = try await scheduler.nextReservation(
            from: [fixture.candidate("low", priority: 1), fixture.candidate("high", priority: 10)],
            sourceFingerprint: fixture.sourceA,
            for: fixture.scope,
            eligibility: .permitted,
            at: fixture.now
        )
        XCTAssertEqual(first?.candidate.id.rawValue, "high")
        try await scheduler.finish(try XCTUnwrap(first), disposition: .completed, at: fixture.now)

        let sameSource = try await scheduler.nextReservation(
            from: [fixture.candidate("other", priority: 100)],
            sourceFingerprint: fixture.sourceA,
            for: fixture.scope,
            eligibility: .permitted,
            at: fixture.now
        )
        XCTAssertNil(sameSource)

        let second = try await scheduler.nextReservation(
            from: [fixture.candidate("second", priority: 1)],
            sourceFingerprint: fixture.sourceB,
            for: fixture.scope,
            eligibility: .permitted,
            at: fixture.now
        )
        XCTAssertNotNil(second)
        try await scheduler.finish(try XCTUnwrap(second), disposition: .completed, at: fixture.now)
        let hasAvailableBudget = try await scheduler.hasAvailableBudget(for: fixture.scope, at: fixture.now)
        XCTAssertFalse(hasAvailableBudget)
    }

    func testUTCResetAndOrganizationScopeAreIndependent() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let policy = OrganizationCopilotCandidateBudgetPolicy(
            maximumCandidatesPerUTCDate: 1,
            maximumCandidatesPerSourceFingerprint: 1,
            minimumStartInterval: 0,
            maximumConcurrentCandidates: 1,
            maximumLeaseDuration: 60
        )
        let scheduler = OrganizationCopilotCandidateBudgetScheduler(vault: fixture.vault, policy: policy)
        let first = try await scheduler.nextReservation(
            from: [fixture.candidate("one", priority: 1)],
            sourceFingerprint: fixture.sourceA,
            for: fixture.scope,
            eligibility: .permitted,
            at: fixture.now
        )
        try await scheduler.finish(try XCTUnwrap(first), disposition: .completed, at: fixture.now)

        let sameScopeReservation = try await scheduler.nextReservation(
            from: [fixture.candidate("two", priority: 1)],
            sourceFingerprint: fixture.sourceB,
            for: fixture.scope,
            eligibility: .permitted,
            at: fixture.now
        )
        XCTAssertNil(sameScopeReservation)

        let otherOrganizationReservation = try await scheduler.nextReservation(
            from: [fixture.candidate("other-org", priority: 1)],
            sourceFingerprint: fixture.sourceA,
            for: fixture.otherScope,
            eligibility: .permitted,
            at: fixture.now
        )
        XCTAssertNotNil(otherOrganizationReservation)

        let tomorrow = fixture.now.addingTimeInterval(24 * 60 * 60)
        let tomorrowReservation = try await scheduler.nextReservation(
            from: [fixture.candidate("tomorrow", priority: 1)],
            sourceFingerprint: fixture.sourceB,
            for: fixture.scope,
            eligibility: .permitted,
            at: tomorrow
        )
        XCTAssertNotNil(tomorrowReservation)
    }

    func testInjectedClockDrivesNoDateOverloads() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let clock = TestClock(fixture.now)
        let scheduler = OrganizationCopilotCandidateBudgetScheduler(
            vault: fixture.vault,
            policy: .init(
                maximumCandidatesPerUTCDate: 1,
                maximumCandidatesPerSourceFingerprint: 1,
                minimumStartInterval: 0,
                maximumConcurrentCandidates: 1,
                maximumLeaseDuration: 60
            ),
            now: { clock.value }
        )
        let first = try await scheduler.nextReservation(
            from: [fixture.candidate("clock-first", priority: 1)],
            sourceFingerprint: fixture.sourceA,
            for: fixture.scope,
            eligibility: .permitted
        )
        try await scheduler.finish(try XCTUnwrap(first), disposition: .completed)
        let hasBudgetToday = try await scheduler.hasAvailableBudget(for: fixture.scope)
        XCTAssertFalse(hasBudgetToday)

        clock.value = fixture.now.addingTimeInterval(24 * 60 * 60)
        let hasBudgetTomorrow = try await scheduler.hasAvailableBudget(for: fixture.scope)
        XCTAssertTrue(hasBudgetTomorrow)
    }

    func testEligibilityAndRateGateFailClosed() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let policy = OrganizationCopilotCandidateBudgetPolicy(
            maximumCandidatesPerUTCDate: 4,
            maximumCandidatesPerSourceFingerprint: 4,
            minimumStartInterval: 60,
            maximumConcurrentCandidates: 1,
            maximumLeaseDuration: 60
        )
        let scheduler = OrganizationCopilotCandidateBudgetScheduler(vault: fixture.vault, policy: policy)
        let blockedReservation = try await scheduler.nextReservation(
            from: [fixture.candidate("blocked", priority: 1)],
            sourceFingerprint: fixture.sourceA,
            for: fixture.scope,
            eligibility: .unavailable,
            at: fixture.now
        )
        XCTAssertNil(blockedReservation)

        let first = try await scheduler.nextReservation(
            from: [fixture.candidate("first", priority: 1)],
            sourceFingerprint: fixture.sourceA,
            for: fixture.scope,
            eligibility: .permitted,
            at: fixture.now
        )
        try await scheduler.finish(try XCTUnwrap(first), disposition: .completed, at: fixture.now)
        let rateLimitedReservation = try await scheduler.nextReservation(
            from: [fixture.candidate("rate-limited", priority: 1)],
            sourceFingerprint: fixture.sourceB,
            for: fixture.scope,
            eligibility: .permitted,
            at: fixture.now.addingTimeInterval(59)
        )
        XCTAssertNil(rateLimitedReservation)
    }

    func testRateGateSpansUTCMidnight() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let policy = OrganizationCopilotCandidateBudgetPolicy(
            maximumCandidatesPerUTCDate: 4,
            maximumCandidatesPerSourceFingerprint: 4,
            minimumStartInterval: 60,
            maximumConcurrentCandidates: 1,
            maximumLeaseDuration: 60
        )
        let scheduler = OrganizationCopilotCandidateBudgetScheduler(vault: fixture.vault, policy: policy)
        let beforeMidnight = Date(timeIntervalSince1970: 1_735_775_970) // 2025-01-01 23:59:30 UTC
        let first = try await scheduler.nextReservation(
            from: [fixture.candidate("before-midnight", priority: 1)],
            sourceFingerprint: fixture.sourceA,
            for: fixture.scope,
            eligibility: .permitted,
            at: beforeMidnight
        )
        try await scheduler.finish(try XCTUnwrap(first), disposition: .completed, at: beforeMidnight)

        let afterMidnight = beforeMidnight.addingTimeInterval(31)
        let crossingReservation = try await scheduler.nextReservation(
            from: [fixture.candidate("after-midnight", priority: 1)],
            sourceFingerprint: fixture.sourceB,
            for: fixture.scope,
            eligibility: .permitted,
            at: afterMidnight
        )
        XCTAssertNil(crossingReservation)
    }

    func testCancellationCompletionReleasesConcurrencyWithoutErasingDurableAttempt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let policy = OrganizationCopilotCandidateBudgetPolicy(
            maximumCandidatesPerUTCDate: 3,
            maximumCandidatesPerSourceFingerprint: 3,
            minimumStartInterval: 0,
            maximumConcurrentCandidates: 1,
            maximumLeaseDuration: 60
        )
        let scheduler = OrganizationCopilotCandidateBudgetScheduler(vault: fixture.vault, policy: policy)
        let first = try await scheduler.nextReservation(
            from: [fixture.candidate("first", priority: 2)],
            sourceFingerprint: fixture.sourceA,
            for: fixture.scope,
            eligibility: .permitted,
            at: fixture.now
        )
        let reservation = try XCTUnwrap(first)
        let cancelledFinish = Task {
            try await scheduler.finish(reservation, disposition: .cancelled, at: fixture.now)
        }
        cancelledFinish.cancel()
        try await cancelledFinish.value
        let next = try await scheduler.nextReservation(
            from: [fixture.candidate("second", priority: 1)],
            sourceFingerprint: fixture.sourceA,
            for: fixture.scope,
            eligibility: .permitted,
            at: fixture.now
        )
        XCTAssertEqual(next?.candidate.id.rawValue, "second")
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID(rawValue: "00000000-0000-4000-8000-000000000257")!
        let organizationID = OrganizationID(rawValue: "copilot-budget-org")!
        let otherOrganizationID = OrganizationID(rawValue: "copilot-budget-other")!
        let now = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC
        let vault: AccountVault

        let sourceA = String(repeating: "a", count: 64)
        let sourceB = String(repeating: "b", count: 64)

        var scope: SynchronizationScope { makeScope(organizationID) }
        var otherScope: SynchronizationScope { makeScope(otherOrganizationID) }

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "copilot-budget-\(UUID().uuidString)")
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            let account = GitHubAccount(
                id: accountID,
                githubUserID: 257,
                nodeID: GitHubNodeID(rawValue: "copilot-budget-user")!,
                login: "budget-user",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: now,
                lastValidatedAt: now
            )
            try await AccountRepository(vault: vault).save(
                account,
                credentialRevision: CredentialRevision(rawValue: "credential")!
            )
            for (index, organizationID) in [self.organizationID, otherOrganizationID].enumerated() {
                try await AccountRepository(vault: vault).save(
                    GitHubOrganization(
                        id: organizationID,
                        githubOrganizationID: UInt64(index + 1),
                        nodeID: GitHubNodeID(rawValue: "copilot-budget-node-\(index)")!,
                        login: organizationID.rawValue
                    ),
                    access: OrganizationAccess(
                        accountID: accountID,
                        organizationID: organizationID,
                        state: .available,
                        capabilityRevision: CapabilityRevision(rawValue: "capability")!,
                        capabilities: [],
                        checkedAt: now
                    ),
                    selectedAt: now
                )
            }
        }

        func candidate(_ id: String, priority: Int) -> OrganizationCopilotBudgetCandidate {
            .init(id: AIRequestID(rawValue: id)!, priority: priority)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        private func makeScope(_ organizationID: OrganizationID) -> SynchronizationScope {
            .init(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: CredentialRevision(rawValue: "credential")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability")!
            )
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Date

        init(_ value: Date) { storedValue = value }

        var value: Date {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedValue
            }
            set {
                lock.lock()
                storedValue = newValue
                lock.unlock()
            }
        }
    }
}
