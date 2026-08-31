import XCTest
@testable import Triage

final class AttentionRankerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    func testManualPinAndPriorityOutrankAutomaticAttention() {
        let ranker = AttentionRanker()
        let automatic = makeWorkItem(id: "automatic", reasonStrength: 1_000)
        let pinned = makeWorkItem(id: "pinned", pinned: true)
        let highPriority = makeWorkItem(id: "high", priority: .high)

        XCTAssertEqual(
            ranker.sort([automatic, highPriority, pinned], at: now).map(\.id.rawValue),
            ["pinned", "high", "automatic"]
        )
    }

    func testDeadlineAndRepositoryPreferenceAreCappedAndExplained() {
        let ranker = AttentionRanker()
        let item = makeWorkItem(
            id: "deadline",
            dueAt: now.addingTimeInterval(-1)
        )
        let score = ranker.score(for: item, at: now, repositoryPreference: 1_000)

        XCTAssertEqual(score.breakdown["overdue"], 250)
        XCTAssertEqual(score.breakdown["repositoryPreference"], 100)
    }

    func testStableTieBreakingUsesActivityThenWorkItemID() {
        let ranker = AttentionRanker()
        let older = makeWorkItem(id: "z", activity: now)
        let newer = makeWorkItem(id: "y", activity: now.addingTimeInterval(1))
        let sameTimeLowerID = makeWorkItem(id: "a", activity: now)

        XCTAssertEqual(
            ranker.sort([older, newer, sameTimeLowerID], at: now).map(\.id.rawValue),
            ["y", "a", "z"]
        )
    }

    func testEarlierDueDateBreaksEqualScoreBeforeActivity() {
        let ranker = AttentionRanker()
        let laterDue = makeWorkItem(
            id: "later-due",
            dueAt: now.addingTimeInterval(2 * 86_400),
            activity: now.addingTimeInterval(10)
        )
        let earlierDue = makeWorkItem(
            id: "earlier-due",
            dueAt: now.addingTimeInterval(86_400),
            activity: now
        )

        XCTAssertEqual(
            ranker.sort([laterDue, earlierDue], at: now).map(\.id.rawValue),
            ["earlier-due", "later-due"]
        )
    }

    func testPresentationSortUsesThePersistedScoreInsteadOfRecomputingWithoutPreferences() {
        let ranker = AttentionRanker()
        let locallyRanked = makeWorkItem(
            id: "persisted-high",
            reasonStrength: nil,
            persistedScore: 90
        )
        let staleRuleInputs = makeWorkItem(
            id: "would-win-if-recomputed",
            reasonStrength: 1_000,
            persistedScore: 0
        )

        XCTAssertEqual(
            ranker.sortPersisted([staleRuleInputs, locallyRanked]).map(\.id.rawValue),
            ["persisted-high", "would-win-if-recomputed"]
        )
    }

    private func makeWorkItem(
        id: String,
        pinned: Bool = false,
        priority: WorkPriority = .normal,
        reasonStrength: Int? = nil,
        dueAt: Date? = nil,
        activity: Date? = nil,
        persistedScore: Int = 0
    ) -> WorkItem {
        let itemID = WorkItemID(rawValue: id)!
        let reasons = reasonStrength.map {
            [
                AttentionReason(
                    id: "reason-\(id)",
                    category: .directResponsibility,
                    ruleID: "rule",
                    ruleVersion: 1,
                    strength: $0,
                    title: "Reason",
                    explanation: "Reason",
                    evidence: [],
                    evaluatedAt: now
                )
            ]
        } ?? []
        let actions = dueAt.map {
            [
                ActionItem(
                    id: ActionItemID.make(),
                    workItemID: itemID,
                    title: "Due action",
                    origin: .manual,
                    dueAt: $0,
                    createdAt: now,
                    updatedAt: now
                )
            ]
        } ?? []
        return WorkItem(
            id: itemID,
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: "github")!,
            primaryNodeID: GitHubNodeID(rawValue: "I_kwDO\(id)")!,
            title: id,
            state: .active,
            sourceKind: .issue,
            sourceURL: nil,
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: reasons,
            actionItems: actions,
            workflow: WorkflowState(isPinned: pinned, priority: priority, updatedAt: now),
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: activity ?? now,
            score: AttentionScore(value: persistedScore, breakdown: [:])
        )
    }
}
