import Combine
import Foundation

/// The policy boundary for native local-workflow undo. It deliberately maps
/// only reversible workflow transitions and never creates an action that could
/// alter GitHub content.
enum LocalWorkflowUndoPolicy {
    /// Registers a native undo operation even when an asynchronous save has
    /// already ended SwiftUI's event group. Existing AppKit undo/redo groups
    /// remain intact; a standalone manager receives one named group.
    @MainActor
    static func registerNativeUndo(
        named actionName: String,
        with undoManager: UndoManager,
        registration: () -> Void
    ) {
        let opensGroup = undoManager.groupingLevel == 0
            && !undoManager.isUndoing
            && !undoManager.isRedoing
        if opensGroup {
            undoManager.beginUndoGrouping()
        }
        registration()
        undoManager.setActionName(actionName)
        if opensGroup {
            undoManager.endUndoGrouping()
        }
    }

    static func inverse(for action: WorkflowAction, previous: WorkflowState) -> WorkflowAction? {
        switch action {
        case .archive:
            switch previous.status {
            case .active: return .unarchive
            case .waiting: return .markWaiting(followUpAt: previous.followUpAt)
            case .archived: return nil
            }
        case .unarchive:
            return previous.status == .archived ? .archive : nil
        case let .setPinned(isPinned):
            return previous.isPinned == isPinned ? nil : .setPinned(previous.isPinned)
        case let .setPriority(priority):
            return previous.priority == priority ? nil : .setPriority(previous.priority)
        case let .snooze(until):
            guard previous.snoozedUntil != until else { return nil }
            return previous.snoozedUntil.map { WorkflowAction.snooze(until: $0) } ?? .clearSnooze
        case .clearSnooze:
            return previous.snoozedUntil.map { WorkflowAction.snooze(until: $0) }
        case .markWaiting:
            return previous.status == .active ? .clearWaiting : nil
        case .clearWaiting:
            return previous.status == .waiting
                ? .markWaiting(followUpAt: previous.followUpAt)
                : nil
        }
    }

    static func actionName(for action: WorkflowAction) -> String {
        switch action {
        case .archive: return "Archive in Triage"
        case .unarchive: return "Restore in Triage"
        case .setPinned(true): return "Pin in Triage"
        case .setPinned(false): return "Unpin in Triage"
        case .setPriority: return "Set Priority in Triage"
        case .snooze: return "Snooze in Triage"
        case .clearSnooze: return "End Snooze in Triage"
        case .markWaiting: return "Mark Waiting in Triage"
        case .clearWaiting: return "Stop Waiting in Triage"
        }
    }

    static func hasSamePersistentState(_ lhs: WorkflowState, _ rhs: WorkflowState) -> Bool {
        lhs.status == rhs.status
            && lhs.isPinned == rhs.isPinned
            && lhs.priority == rhs.priority
            && lhs.snoozedUntil == rhs.snoozedUntil
            && lhs.followUpAt == rhs.followUpAt
            && lhs.localNote == rhs.localNote
    }
}

@MainActor
final class LocalWorkflowUndoCoordinator: NSObject, ObservableObject {
    @Published private(set) var feedback: String?

    func perform(
        _ action: WorkflowAction,
        to item: WorkItem,
        appModel: TriageAppModel,
        undoManager: UndoManager?
    ) async {
        guard let inverse = LocalWorkflowUndoPolicy.inverse(for: action, previous: item.workflow) else {
            feedback = "This local workflow action has no reversible change. GitHub was not modified."
            return
        }

        let expectedAfterAction = WorkflowTransitionEngine.apply(action, to: item.workflow, at: .now).next
        await appModel.applyWorkflowAction(action, to: item)
        guard let updated = currentWorkItem(id: item.id, in: appModel),
              LocalWorkflowUndoPolicy.hasSamePersistentState(updated.workflow, expectedAfterAction)
        else {
            feedback = "Triage could not save this local workflow change. GitHub was not modified."
            return
        }

        if let undoManager {
            registerHistoryStep(
                expectedCurrent: updated.workflow,
                applying: inverse,
                expectedAfterApplying: item.workflow,
                nextAction: action,
                item: item,
                appModel: appModel,
                undoManager: undoManager,
                actionName: LocalWorkflowUndoPolicy.actionName(for: action)
            )
            feedback = "Local workflow updated. Choose Edit > Undo to reverse it in Triage; GitHub is unchanged."
        } else {
            feedback = "Local workflow updated. Undo is unavailable in this window; GitHub is unchanged."
        }
    }

    private func registerHistoryStep(
        expectedCurrent: WorkflowState,
        applying: WorkflowAction,
        expectedAfterApplying: WorkflowState,
        nextAction: WorkflowAction,
        item: WorkItem,
        appModel: TriageAppModel,
        undoManager: UndoManager,
        actionName: String
    ) {
        LocalWorkflowUndoPolicy.registerNativeUndo(named: actionName, with: undoManager) {
            undoManager.registerUndo(withTarget: self) { coordinator in
                coordinator.registerHistoryStep(
                    expectedCurrent: expectedAfterApplying,
                    applying: nextAction,
                    expectedAfterApplying: expectedCurrent,
                    nextAction: applying,
                    item: item,
                    appModel: appModel,
                    undoManager: undoManager,
                    actionName: actionName
                )
                Task { @MainActor in
                    await coordinator.applyHistoryStep(
                        applying,
                        expectedCurrent: expectedCurrent,
                        expectedAfterApplying: expectedAfterApplying,
                        item: item,
                        appModel: appModel
                    )
                }
            }
        }
    }

    private func applyHistoryStep(
        _ action: WorkflowAction,
        expectedCurrent: WorkflowState,
        expectedAfterApplying: WorkflowState,
        item: WorkItem,
        appModel: TriageAppModel
    ) async {
        guard let current = currentWorkItem(id: item.id, in: appModel) else {
            feedback = "Triage cannot reverse this local workflow change because the item is unavailable. GitHub was not modified."
            return
        }
        guard LocalWorkflowUndoPolicy.hasSamePersistentState(current.workflow, expectedCurrent) else {
            feedback = "Triage cannot reverse this local workflow change because it changed again. GitHub was not modified."
            return
        }

        await appModel.applyWorkflowAction(action, to: item)
        guard let updated = currentWorkItem(id: item.id, in: appModel),
              LocalWorkflowUndoPolicy.hasSamePersistentState(updated.workflow, expectedAfterApplying)
        else {
            feedback = "Triage could not reverse this local workflow change. GitHub was not modified."
            return
        }
        feedback = "Local workflow reversal completed in Triage. GitHub was not modified."
    }

    private func currentWorkItem(id: WorkItemID, in appModel: TriageAppModel) -> WorkItem? {
        appModel.workItems.first(where: { $0.id == id })
    }
}
