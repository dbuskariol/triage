import Combine
import Foundation

@MainActor
final class LocalGroupingUndoCoordinator: NSObject, ObservableObject {
    @Published private(set) var feedback: String?

    func presentFeedback(_ value: String) {
        feedback = value
    }

    func perform(
        _ mutation: WorkItemGroupingMutation,
        to item: WorkItem,
        appModel: TriageAppModel,
        undoManager: UndoManager?
    ) async {
        guard let history = await appModel.applyGroupingMutation(mutation, to: item) else {
            feedback = "Triage could not save this local grouping decision. GitHub was not modified."
            return
        }
        guard let undoManager else {
            feedback = "Local grouping updated. Undo is unavailable in this window; GitHub is unchanged."
            return
        }
        registerUndo(history: history, item: item, appModel: appModel, undoManager: undoManager)
        feedback = "Local grouping updated. Choose Edit > Undo to reverse it in Triage; GitHub is unchanged."
    }

    private func registerUndo(
        history: WorkItemGroupingMutationHistory,
        item: WorkItem,
        appModel: TriageAppModel,
        undoManager: UndoManager
    ) {
        LocalWorkflowUndoPolicy.registerNativeUndo(named: "Change Grouping in Triage", with: undoManager) {
            undoManager.registerUndo(withTarget: self) { coordinator in
                coordinator.registerRedo(history: history, item: item, appModel: appModel, undoManager: undoManager)
                Task { @MainActor in
                    let restored = await appModel.restoreGroupingDecisions(
                        history.before,
                        expectedCurrent: history.after,
                        for: item
                    )
                    coordinator.feedback = restored
                        ? "Local grouping reversal completed in Triage. GitHub was not modified."
                        : "Triage cannot reverse this local grouping change because it changed again. GitHub was not modified."
                }
            }
        }
    }

    private func registerRedo(
        history: WorkItemGroupingMutationHistory,
        item: WorkItem,
        appModel: TriageAppModel,
        undoManager: UndoManager
    ) {
        LocalWorkflowUndoPolicy.registerNativeUndo(named: "Change Grouping in Triage", with: undoManager) {
            undoManager.registerUndo(withTarget: self) { coordinator in
                coordinator.registerUndo(history: history, item: item, appModel: appModel, undoManager: undoManager)
                Task { @MainActor in
                    let restored = await appModel.restoreGroupingDecisions(
                        history.after,
                        expectedCurrent: history.before,
                        for: item
                    )
                    coordinator.feedback = restored
                        ? "Local grouping reapplied in Triage. GitHub was not modified."
                        : "Triage cannot reapply this local grouping change because it changed again. GitHub was not modified."
                }
            }
        }
    }
}
