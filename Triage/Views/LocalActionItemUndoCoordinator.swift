import Combine
import Foundation

/// Native undo for the strictly local editable portion of an action item.
/// Each reversal carries the committed record's timestamp so a later edit is
/// never silently overwritten.
@MainActor
final class LocalActionItemUndoCoordinator: NSObject, ObservableObject {
    @Published private(set) var feedback: String?

    func perform(
        _ edit: LocalActionItemEdit,
        actionItem: ActionItem,
        in workItem: WorkItem,
        appModel: TriageAppModel,
        undoManager: UndoManager?
    ) async {
        guard actionItem.localEdit != edit else {
            feedback = "No local action-item fields changed. GitHub was not modified."
            return
        }
        guard let updated = await appModel.editActionItem(edit, actionItem: actionItem, in: workItem) else {
            feedback = "Triage could not save this local action-item edit. GitHub was not modified."
            return
        }
        registerUndo(
            restoring: actionItem,
            expectedCurrent: updated,
            in: workItem,
            appModel: appModel,
            undoManager: undoManager
        )
        feedback = undoManager == nil
            ? "Local action item updated. Undo is unavailable in this window; GitHub is unchanged."
            : "Local action item updated. Choose Edit > Undo to reverse it in Triage; GitHub is unchanged."
    }

    private func registerUndo(
        restoring previous: ActionItem,
        expectedCurrent: ActionItem,
        in workItem: WorkItem,
        appModel: TriageAppModel,
        undoManager: UndoManager?
    ) {
        guard let undoManager,
              let restoreEdit = previous.localEdit,
              let inverseEdit = expectedCurrent.localEdit
        else { return }
        register(
            LocalActionItemUndoStep(
                edit: restoreEdit,
                inverseEdit: inverseEdit,
                expectedCurrent: expectedCurrent,
                workItem: workItem,
                appModel: appModel
            ),
            with: undoManager
        )
    }

    /// `UndoManager` builds its redo stack only from registrations performed
    /// synchronously while an undo is being invoked. The durable local edit is
    /// asynchronous, so each native action registers a pending inverse first;
    /// the committed record (including its new optimistic-lock timestamp) is
    /// installed into that inverse when the vault write completes.
    private func register(
        _ step: LocalActionItemUndoStep,
        with undoManager: UndoManager
    ) {
        // The durable save completed asynchronously, after the originating
        // SwiftUI control event may have closed its automatic undo group. A
        // standalone group keeps Edit > Undo discoverable and named in that
        // normal case, while respecting a group already opened by AppKit.
        let opensGroup = undoManager.groupingLevel == 0
            && !undoManager.isUndoing
            && !undoManager.isRedoing
        if opensGroup {
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { coordinator in
            coordinator.invoke(step, with: undoManager)
        }
        undoManager.setActionName("Edit Local Action Item")
        if opensGroup {
            undoManager.endUndoGrouping()
        }
    }

    private func invoke(
        _ step: LocalActionItemUndoStep,
        with undoManager: UndoManager
    ) {
        guard let expectedCurrent = step.expectedCurrent else {
            feedback = "Triage is still saving the prior local action-item change. GitHub was not modified."
            return
        }
        let inverse = LocalActionItemUndoStep(
            edit: step.inverseEdit,
            inverseEdit: step.edit,
            expectedCurrent: nil,
            workItem: step.workItem,
            appModel: step.appModel
        )
        // This must occur before returning from UndoManager's invocation so it
        // becomes a redo (or, while redoing, the next undo) rather than a new
        // unrelated undo entry.
        register(inverse, with: undoManager)
        Task { @MainActor [weak self] in
            await self?.apply(step, expecting: expectedCurrent, preparing: inverse)
        }
    }

    private func apply(
        _ step: LocalActionItemUndoStep,
        expecting expectedCurrent: ActionItem,
        preparing inverse: LocalActionItemUndoStep
    ) async {
        guard let updated = await step.appModel.editActionItem(
            step.edit,
            actionItem: expectedCurrent,
            in: step.workItem
        ) else {
            feedback = "Triage cannot reverse this local action-item edit because it changed again. GitHub was not modified."
            return
        }
        inverse.expectedCurrent = updated
        feedback = "Local action-item reversal completed in Triage. GitHub was not modified."
    }
}

@MainActor
private final class LocalActionItemUndoStep {
    let edit: LocalActionItemEdit
    let inverseEdit: LocalActionItemEdit
    var expectedCurrent: ActionItem?
    let workItem: WorkItem
    let appModel: TriageAppModel

    init(
        edit: LocalActionItemEdit,
        inverseEdit: LocalActionItemEdit,
        expectedCurrent: ActionItem?,
        workItem: WorkItem,
        appModel: TriageAppModel
    ) {
        self.edit = edit
        self.inverseEdit = inverseEdit
        self.expectedCurrent = expectedCurrent
        self.workItem = workItem
        self.appModel = appModel
    }
}
