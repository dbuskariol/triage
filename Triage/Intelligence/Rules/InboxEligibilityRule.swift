import Foundation

enum InboxDisposition: String, Sendable {
    case inbox
    case waiting
    case snoozed
    case archived
    case resolved
    case inaccessible
    case informational
}

struct InboxEligibilityRule: Sendable {
    func disposition(
        for workItem: WorkItem,
        at date: Date
    ) -> InboxDisposition {
        if workItem.state == .inaccessible {
            return .inaccessible
        }
        if workItem.workflow.isSnoozed(at: date) {
            return .snoozed
        }
        if workItem.workflow.status == .archived {
            return .archived
        }
        if workItem.workflow.status == .waiting {
            if workItem.attentionReasons.contains(where: Self.isWaitingWakeUp) {
                return .inbox
            }
            return .waiting
        }
        if workItem.state == .resolved, workItem.openActionItems.isEmpty {
            return .resolved
        }
        if workItem.workflow.isPinned
            || !workItem.attentionReasons.isEmpty
            || !workItem.openActionItems.isEmpty
        {
            return .inbox
        }
        return .informational
    }

    private static func isWaitingWakeUp(_ reason: AttentionReason) -> Bool {
        reason.ruleID == WaitingAttentionRuleID.awaitedActorResponded.rawValue
            || reason.ruleID == WaitingAttentionRuleID.followUpDue.rawValue
    }
}
