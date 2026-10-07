import Foundation
import XCTest
@testable import Triage

final class TriageEngineTests: XCTestCase {
    func testRefreshSavesItemsAndAnalyzesMostUrgentFirstInBoundedBatches() async throws {
        let items = (0..<7).map { engineItem("I\($0)", relationship: $0 < 2 ? .reviewRequested : .mentioned) }
        let store = MemoryStore()
        let decider = RecordingDecider(batchSize: 3)
        let engine = engine(store: store, items: items, decider: decider)
        await engine.start(scope)
        try await waitUntil { await store.decidedCount() == 7 }
        let batches = await decider.batches
        XCTAssertEqual(batches.map(\.count).sorted(by: >), [3, 3, 1])
        XCTAssertTrue(batches.flatMap { $0 }.prefix(3).contains { $0 == "I0" || $0 == "I1" })
        let saved = await store.savedItemIDs()
        XCTAssertEqual(saved, Set(items.map(\.id.rawValue)))
        await engine.stop()
    }

    func testGitHubFailureStillAnalyzesSavedWorkAndReportsProblem() async throws {
        let store = MemoryStore()
        try await store.replaceItems([engineItem("saved", relationship: .assigned)], scope: scope, at: .now)
        let decider = RecordingDecider(batchSize: 5)
        let engine = TriageEngine(
            store: store, makeDiscovery: { _ in FailingDiscovery() }, decider: decider,
            refreshInterval: .seconds(3_600)
        )
        let statuses = await engine.statusUpdates()
        await engine.start(scope)
        try await waitUntil { await store.decidedCount() == 1 }
        var sawProblem = false
        for await status in statuses {
            if case .gitHubUnavailable = status.problem { sawProblem = true }
            if sawProblem, status.phase == .idle { break }
        }
        XCTAssertTrue(sawProblem)
        await engine.stop()
    }

    func testCopilotUnavailableKeepsItemsPendingInsteadOfFailingThem() async throws {
        let store = MemoryStore()
        let engine = engine(
            store: store, items: [engineItem("a", relationship: .assigned), engineItem("b", relationship: .assigned)],
            decider: UnavailableDecider()
        )
        let statuses = await engine.statusUpdates()
        await engine.start(scope)
        for await status in statuses {
            if case .copilotUnavailable(let message) = status.problem {
                XCTAssertEqual(message, "Connect Copilot in Settings.")
                break
            }
        }
        let failures = await store.failureCount()
        XCTAssertEqual(failures, 0)
        let pending = try await store.itemsNeedingAnalysis(scope: scope, rulesDigest: "", at: .now, limit: 10)
        XCTAssertEqual(pending.count, 2)
        await engine.stop()
    }

    func testBatchFailureRecordsRetryForOnlyThatBatch() async throws {
        let store = MemoryStore()
        let decider = RecordingDecider(batchSize: 1, failingIDs: ["bad"])
        let engine = engine(
            store: store, items: [engineItem("good", relationship: .assigned), engineItem("bad", relationship: .assigned)],
            decider: decider
        )
        await engine.start(scope)
        try await waitUntil { let decided = await store.decidedCount(); let failed = await store.failureCount(); return decided == 1 && failed == 1 }
        let pending = try await store.itemsNeedingAnalysis(
            scope: scope, rulesDigest: TriageRules.empty.digest, at: .now, limit: 10
        )
        XCTAssertTrue(pending.isEmpty, "A failed item waits for its retry time.")
        await engine.stop()
    }

    func testMutedItemsAreNeverSentToCopilotAndChangedInstructionsReanalyze() async throws {
        let store = MemoryStore()
        try await store.saveRules(TriageRules(instructions: "", rules: [.quick(.mute, .author, "bot")]), scope: scope)
        let items = [engineItem("kept", relationship: .assigned), engineItem("noise", relationship: .assigned, author: "bot")]
        let decider = RecordingDecider(batchSize: 5)
        let engine = engine(store: store, items: items, decider: decider)
        await engine.start(scope)
        try await waitUntil { await store.decidedCount() == 1 }
        let firstBatches = await decider.batches
        XCTAssertEqual(firstBatches.flatMap { $0 }, ["kept"])

        try await store.saveRules(
            TriageRules(instructions: "Security first.", rules: [.quick(.mute, .author, "bot")]), scope: scope
        )
        await engine.refreshNow()
        try await waitUntil { await decider.batches.count == 2 }
        let secondBatches = await decider.batches
        XCTAssertEqual(secondBatches.last, ["kept"])
        await engine.stop()
    }

    func testRefreshNowStartsAnotherCycleBeforeTheInterval() async throws {
        let store = MemoryStore()
        let discovery = CountingDiscovery(items: [engineItem("x", relationship: .assigned)])
        let engine = TriageEngine(
            store: store, makeDiscovery: { _ in discovery }, decider: RecordingDecider(batchSize: 5),
            refreshInterval: .seconds(3_600)
        )
        await engine.start(scope)
        try await waitUntil { await discovery.calls == 1 }
        try await Task.sleep(for: .milliseconds(50))
        await engine.refreshNow()
        try await waitUntil { await discovery.calls == 2 }
        await engine.stop()
    }

    func testManualModeWaitsAndShorterIntervalRefreshesLive() async throws {
        let store = MemoryStore()
        let discovery = CountingDiscovery(items: [engineItem("x", relationship: .assigned)])
        let engine = TriageEngine(
            store: store, makeDiscovery: { _ in discovery }, decider: RecordingDecider(batchSize: 5),
            refreshInterval: nil
        )
        await engine.start(scope)
        try await waitUntil { await discovery.calls == 1 }
        try await Task.sleep(for: .milliseconds(200))
        let manualCalls = await discovery.calls
        XCTAssertEqual(manualCalls, 1, "Manual mode must not refresh on its own.")

        await engine.setRefreshInterval(.milliseconds(50))
        try await waitUntil { await discovery.calls >= 3 }
        await engine.stop()
    }

    // MARK: Fixtures

    private let scope = WorkspaceScope(
        accountID: AccountID(rawValue: "engine-account")!,
        organizationID: OrganizationID(rawValue: "engine-org")!,
        organizationLogin: "github", viewerLogin: "octocat"
    )

    private func engine(store: MemoryStore, items: [PersonalWorkItem], decider: any TriageDeciding) -> TriageEngine {
        TriageEngine(
            store: store, makeDiscovery: { _ in StaticDiscovery(items: items) }, decider: decider,
            refreshInterval: .seconds(3_600)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5), _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout.")
    }
}

fileprivate func engineItem(
    _ id: String, relationship: WorkRelationship, updatedAt: Date = .now, author: String = "octocat"
) -> PersonalWorkItem {
    PersonalWorkItem(
        id: GitHubNodeID(rawValue: id)!, kind: .issue, repository: "github/triage", number: 1,
        title: "Item \(id)", url: URL(string: "https://github.com/github/triage/issues/1")!,
        state: .open, author: author, createdAt: updatedAt, updatedAt: updatedAt,
        relationships: [relationship], labels: [], assignees: [], body: "",
        pullRequest: nil, recentActivity: []
    )
}

private struct StaticDiscovery: PersonalWorkDiscovering {
    let items: [PersonalWorkItem]
    func discover(
        scope: WorkspaceScope, progress: @escaping @Sendable (DiscoveryProgress) async -> Void
    ) async throws -> [PersonalWorkItem] {
        await progress(.init(relationship: .assigned, found: items.count))
        return items
    }
}

private actor CountingDiscovery: PersonalWorkDiscovering {
    let items: [PersonalWorkItem]
    private(set) var calls = 0
    init(items: [PersonalWorkItem]) { self.items = items }
    func discover(
        scope: WorkspaceScope, progress: @escaping @Sendable (DiscoveryProgress) async -> Void
    ) async throws -> [PersonalWorkItem] {
        calls += 1
        return items
    }
}

private struct FailingDiscovery: PersonalWorkDiscovering {
    func discover(
        scope: WorkspaceScope, progress: @escaping @Sendable (DiscoveryProgress) async -> Void
    ) async throws -> [PersonalWorkItem] {
        throw URLError(.notConnectedToInternet)
    }
}

private struct CopilotUnavailable: TriageAvailabilityError {
    var pausesAnalysis: Bool { true }
    var userMessage: String { "Connect Copilot in Settings." }
}

private struct UnavailableDecider: TriageDeciding {
    let maximumBatchSize = 5
    func decide(_ items: [PersonalWorkItem], scope: WorkspaceScope, rules: TriageRules) async throws -> [TriageDecision] {
        throw CopilotUnavailable()
    }
}

private actor RecordingDecider: TriageDeciding {
    nonisolated let maximumBatchSize: Int
    let failingIDs: Set<String>
    private(set) var batches: [[String]] = []

    init(batchSize: Int, failingIDs: Set<String> = []) {
        maximumBatchSize = batchSize
        self.failingIDs = failingIDs
    }

    func decide(_ items: [PersonalWorkItem], scope: WorkspaceScope, rules: TriageRules) async throws -> [TriageDecision] {
        batches.append(items.map(\.id.rawValue))
        if items.contains(where: { failingIDs.contains($0.id.rawValue) }) {
            throw URLError(.badServerResponse)
        }
        return items.map {
            TriageDecision(
                itemID: $0.id, disposition: .act, priority: 50, confidence: 0.9,
                summary: "s", reason: "r", nextAction: nil, fingerprint: $0.fingerprint,
                modelID: "test", decidedAt: .now, rulesDigest: rules.digest
            )
        }
    }
}

/// In-memory `TriageStore` with the same selection semantics as the real one.
actor MemoryStore: TriageStore {
    private var items: [GitHubNodeID: PersonalWorkItem] = [:]
    private var decisions: [GitHubNodeID: TriageDecision] = [:]
    private var failures: [GitHubNodeID: (fingerprint: String, retryAt: Date)] = [:]
    private var local: [GitHubNodeID: LocalStatus] = [:]
    private var refreshedAt: Date?
    private var savedRules = TriageRules.empty

    func rules(scope: WorkspaceScope) async throws -> TriageRules { savedRules }
    func saveRules(_ rules: TriageRules, scope: WorkspaceScope) async throws { savedRules = rules }

    func decidedCount() -> Int { decisions.count }
    func failureCount() -> Int { failures.count }
    func savedItemIDs() -> Set<String> { Set(items.keys.map(\.rawValue)) }

    func replaceItems(_ items: [PersonalWorkItem], scope: WorkspaceScope, at date: Date) async throws {
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        refreshedAt = date
    }

    func itemsNeedingAnalysis(
        scope: WorkspaceScope, rulesDigest: String, at date: Date, limit: Int
    ) async throws -> [PersonalWorkItem] {
        items.values
            .filter { item in
                (decisions[item.id]?.fingerprint != item.fingerprint || (decisions[item.id]?.rulesDigest ?? "") != rulesDigest)
                    && (failures[item.id].map { $0.fingerprint != item.fingerprint || $0.retryAt <= date } ?? true)
            }
            .sorted {
                let left = $0.primaryRelationship?.urgencyRank ?? .max
                let right = $1.primaryRelationship?.urgencyRank ?? .max
                return left != right ? left < right : $0.updatedAt > $1.updatedAt
            }
            .prefix(limit)
            .map { $0 }
    }

    func saveDecisions(_ decisions: [TriageDecision], scope: WorkspaceScope) async throws {
        for decision in decisions {
            self.decisions[decision.itemID] = decision
            failures[decision.itemID] = nil
        }
    }

    func recordAnalysisFailure(
        itemIDs: [GitHubNodeID], reason: String, retryAt: Date, scope: WorkspaceScope
    ) async throws {
        for id in itemIDs {
            guard let item = items[id] else { continue }
            failures[id] = (item.fingerprint, retryAt)
        }
    }

    func setLocalStatus(_ status: LocalStatus, itemID: GitHubNodeID, scope: WorkspaceScope) async throws {
        local[itemID] = status
    }

    func entries(scope: WorkspaceScope) async throws -> AsyncThrowingStream<[TriageEntry], Error> {
        let snapshot = items.values.map { item in
            TriageEntry(
                item: item, decision: decisions[item.id],
                analysis: decisions[item.id]?.fingerprint == item.fingerprint ? .current : .pending,
                local: local[item.id] ?? .active
            )
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    func lastRefreshAt(scope: WorkspaceScope) async throws -> Date? { refreshedAt }
}
