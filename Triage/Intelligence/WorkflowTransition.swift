import Foundation

enum WorkflowAction: Sendable {
    case archive
    case unarchive
    case setPinned(Bool)
    case setPriority(WorkPriority)
    case snooze(until: Date)
    case clearSnooze
    case markWaiting(followUpAt: Date?)
    case clearWaiting
}

struct WorkflowTransition: Sendable {
    let previous: WorkflowState
    let next: WorkflowState
}

enum WorkflowTransitionEngine {
    static func apply(
        _ action: WorkflowAction,
        to state: WorkflowState,
        at date: Date
    ) -> WorkflowTransition {
        let next: WorkflowState
        switch action {
        case .archive:
            next = updated(state, status: .archived, updatedAt: date)
        case .unarchive:
            next = updated(state, status: .active, updatedAt: date)
        case let .setPinned(isPinned):
            next = WorkflowState(
                status: state.status,
                isPinned: isPinned,
                priority: state.priority,
                snoozedUntil: state.snoozedUntil,
                followUpAt: state.followUpAt,
                localNote: state.localNote,
                updatedAt: date
            )
        case let .setPriority(priority):
            next = WorkflowState(
                status: state.status,
                isPinned: state.isPinned,
                priority: priority,
                snoozedUntil: state.snoozedUntil,
                followUpAt: state.followUpAt,
                localNote: state.localNote,
                updatedAt: date
            )
        case let .snooze(until):
            next = WorkflowState(
                status: state.status,
                isPinned: state.isPinned,
                priority: state.priority,
                snoozedUntil: until,
                followUpAt: state.followUpAt,
                localNote: state.localNote,
                updatedAt: date
            )
        case .clearSnooze:
            next = WorkflowState(
                status: state.status,
                isPinned: state.isPinned,
                priority: state.priority,
                snoozedUntil: nil,
                followUpAt: state.followUpAt,
                localNote: state.localNote,
                updatedAt: date
            )
        case let .markWaiting(followUpAt):
            next = WorkflowState(
                status: .waiting,
                isPinned: state.isPinned,
                priority: state.priority,
                snoozedUntil: state.snoozedUntil,
                followUpAt: followUpAt,
                localNote: state.localNote,
                updatedAt: date
            )
        case .clearWaiting:
            next = updated(state, status: .active, updatedAt: date)
        }
        return WorkflowTransition(previous: state, next: next)
    }

    private static func updated(
        _ state: WorkflowState,
        status: LocalWorkStatus,
        updatedAt: Date
    ) -> WorkflowState {
        WorkflowState(
            status: status,
            isPinned: state.isPinned,
            priority: state.priority,
            snoozedUntil: state.snoozedUntil,
            followUpAt: state.followUpAt,
            localNote: state.localNote,
            updatedAt: updatedAt
        )
    }
}
