import Foundation

struct AttentionRanker: Sendable {
    private static let pinBoost = 500
    private static let highPriorityBoost = 300
    private static let lowPriorityPenalty = 100
    private static let overdueBoost = 250
    private static let dueSoonBoost = 150
    private static let unreadActivityBoost = 80
    private static let draftPenalty = 400

    func score(
        for workItem: WorkItem,
        at date: Date,
        repositoryPreference: Int = 0,
        hasNewRelevantActivity: Bool = false
    ) -> AttentionScore {
        var breakdown: [String: Int] = [:]
        let strongestReason = workItem.attentionReasons.map(\.strength).max() ?? 0
        breakdown["attentionReason"] = strongestReason

        if workItem.workflow.isPinned {
            breakdown["pin"] = Self.pinBoost
        }
        switch workItem.workflow.priority {
        case .high:
            breakdown["manualPriority"] = Self.highPriorityBoost
        case .normal:
            break
        case .low:
            breakdown["manualPriority"] = -Self.lowPriorityPenalty
        }
        if let dueAt = workItem.openActionItems.compactMap(\.dueAt).min() {
            if dueAt <= date {
                breakdown["overdue"] = Self.overdueBoost
            } else if dueAt <= date.addingTimeInterval(3 * 86_400) {
                breakdown["dueSoon"] = Self.dueSoonBoost
            }
        }
        if hasNewRelevantActivity {
            breakdown["newActivity"] = Self.unreadActivityBoost
        }
        if workItem.state == .resolved || workItem.sourceKind == .pullRequest && isDraft(workItem) {
            breakdown["draftOrResolved"] = -Self.draftPenalty
        }
        if repositoryPreference != 0 {
            breakdown["repositoryPreference"] = min(max(repositoryPreference, -100), 100)
        }

        return AttentionScore(
            value: breakdown.values.reduce(0, +),
            breakdown: breakdown
        )
    }

    func sort(
        _ workItems: [WorkItem],
        at date: Date,
        repositoryPreference: (RepositoryID) -> Int = { _ in 0 },
        hasNewRelevantActivity: (WorkItemID) -> Bool = { _ in false }
    ) -> [WorkItem] {
        workItems.sorted(by: { (left: WorkItem, right: WorkItem) -> Bool in
            let leftScore = score(
                for: left,
                at: date,
                repositoryPreference: left.repository.map { repositoryPreference($0.id) } ?? 0,
                hasNewRelevantActivity: hasNewRelevantActivity(left.id)
            )
            let rightScore = score(
                for: right,
                at: date,
                repositoryPreference: right.repository.map { repositoryPreference($0.id) } ?? 0,
                hasNewRelevantActivity: hasNewRelevantActivity(right.id)
            )
            if left.workflow.isPinned != right.workflow.isPinned {
                return left.workflow.isPinned
            }
            if left.workflow.priority != right.workflow.priority {
                return left.workflow.priority > right.workflow.priority
            }
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            let leftDueAt = left.openActionItems.compactMap(\.dueAt).min()
            let rightDueAt = right.openActionItems.compactMap(\.dueAt).min()
            switch (leftDueAt, rightDueAt) {
            case let (leftDueAt?, rightDueAt?) where leftDueAt != rightDueAt:
                return leftDueAt < rightDueAt
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            if left.lastRelevantActivityAt != right.lastRelevantActivityAt {
                return left.lastRelevantActivityAt > right.lastRelevantActivityAt
            }
            return left.id.rawValue < right.id.rawValue
        })
    }

    /// Presentation must rank the durable score produced by the derived
    /// projection, never run a second scoring pass with a different clock or
    /// missing repository preferences. Workflow and activity fields remain
    /// stable tie-breakers for an explainable local order.
    func sortPersisted(_ workItems: [WorkItem]) -> [WorkItem] {
        workItems.sorted(by: { left, right in
            if left.workflow.isPinned != right.workflow.isPinned {
                return left.workflow.isPinned
            }
            if left.workflow.priority != right.workflow.priority {
                return left.workflow.priority > right.workflow.priority
            }
            if left.score != right.score {
                return left.score > right.score
            }
            let leftDueAt = left.openActionItems.compactMap(\.dueAt).min()
            let rightDueAt = right.openActionItems.compactMap(\.dueAt).min()
            switch (leftDueAt, rightDueAt) {
            case let (leftDueAt?, rightDueAt?) where leftDueAt != rightDueAt:
                return leftDueAt < rightDueAt
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            if left.lastRelevantActivityAt != right.lastRelevantActivityAt {
                return left.lastRelevantActivityAt > right.lastRelevantActivityAt
            }
            return left.id.rawValue < right.id.rawValue
        })
    }

    private func isDraft(_ workItem: WorkItem) -> Bool {
        workItem.members.contains { $0.content.state == .draft }
    }
}
