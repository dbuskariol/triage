import AppKit
import SwiftUI

/// Shared focused values let the main command menu target the active work-list
/// search field and inspector rather than an arbitrary window.
private struct TriageSearchFocusKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct TriageInspectorVisibilityKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct TriageSidebarVisibilityKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct TriageWorkflowUndoCoordinatorKey: FocusedValueKey {
    typealias Value = LocalWorkflowUndoCoordinator
}

extension FocusedValues {
    var triageSearchFocus: Binding<Bool>? {
        get { self[TriageSearchFocusKey.self] }
        set { self[TriageSearchFocusKey.self] = newValue }
    }

    var triageInspectorVisibility: Binding<Bool>? {
        get { self[TriageInspectorVisibilityKey.self] }
        set { self[TriageInspectorVisibilityKey.self] = newValue }
    }

    var triageSidebarVisibility: Binding<Bool>? {
        get { self[TriageSidebarVisibilityKey.self] }
        set { self[TriageSidebarVisibilityKey.self] = newValue }
    }
    var triageWorkflowUndoCoordinator: LocalWorkflowUndoCoordinator? {
        get { self[TriageWorkflowUndoCoordinatorKey.self] }
        set { self[TriageWorkflowUndoCoordinatorKey.self] = newValue }
    }
}

/// Deterministic mutations for optional focused values. Keeping the routing
/// separate from the Commands builder makes the no-focus disabled state and
/// the two independent bindings straightforward to verify.
enum TriageFocusedCommandRouting {
    static func focusSearch(_ searchFocus: Binding<Bool>?) {
        searchFocus?.wrappedValue = true
    }

    static func focusSearch(_ searchFocus: Binding<Bool?>) {
        searchFocus.wrappedValue = true
    }

    static func toggleInspector(_ inspectorVisible: Binding<Bool>?) {
        inspectorVisible?.wrappedValue.toggle()
    }

    static func toggleInspector(_ inspectorVisible: Binding<Bool?>) {
        inspectorVisible.wrappedValue = !(inspectorVisible.wrappedValue ?? false)
    }

    static func toggleSidebar(_ sidebarVisible: Binding<Bool>?) {
        sidebarVisible?.wrappedValue.toggle()
    }

    static func toggleSidebar(_ sidebarVisible: Binding<Bool?>) {
        sidebarVisible.wrappedValue = !(sidebarVisible.wrappedValue ?? false)
    }
}

/// Holds a requested external navigation until the app-owned confirmation UI
/// approves it. Commands must never invoke `openURL` directly because they do
/// not have a view hierarchy in which to present that confirmation themselves.
@MainActor
final class ExternalNavigationConfirmationCoordinator: ObservableObject {
    @Published private(set) var pendingURL: URL?

    func requestOpen(_ url: URL) {
        guard GitHubMarkdownPolicy.permitsExternalNavigation(to: url) else {
            pendingURL = nil
            return
        }
        pendingURL = url
    }

    func confirmOpen() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }

    func cancel() {
        pendingURL = nil
    }
}

/// A view-hosted confirmation shared by command routing. Keeping this outside
/// `Commands` gives keyboard invocations the same explicit browser hand-off as
/// detail links and Markdown links.
struct ExternalNavigationConfirmationHost<Content: View>: View {
    @ObservedObject var coordinator: ExternalNavigationConfirmationCoordinator
    @Environment(\.openURL) private var openURL
    let content: Content

    init(
        coordinator: ExternalNavigationConfirmationCoordinator,
        @ViewBuilder content: () -> Content
    ) {
        self.coordinator = coordinator
        self.content = content()
    }

    var body: some View {
        content
            .confirmationDialog(
                "Open external link?",
                isPresented: Binding(
                    get: { coordinator.pendingURL != nil },
                    set: { if !$0 { coordinator.cancel() } }
                ),
                titleVisibility: .visible
            ) {
                if let pendingURL = coordinator.pendingURL {
                    Button("Open \(pendingURL.host ?? "external site")") {
                        guard let destination = coordinator.confirmOpen() else { return }
                        openURL(destination)
                    }
                }
                Button("Cancel", role: .cancel) {
                    coordinator.cancel()
                }
            } message: {
                Text(confirmationMessage)
            }
            .accessibilityHint("External links require confirmation before opening in your default browser.")
    }

    private var confirmationMessage: String {
        guard let pendingURL = coordinator.pendingURL else {
            return "Triage opens external HTTPS links only after confirmation."
        }
        return "Triage has not loaded hosted content. Open \(pendingURL.host ?? "this external site") in your default browser?"
    }
}

struct TriageWorkflowCommandAvailability: Equatable {
    let canOpenSource: Bool
    let canArchive: Bool
    let canUnarchive: Bool
    let canSnooze: Bool
    let canClearSnooze: Bool
    let canMarkWaiting: Bool
    let canClearWaiting: Bool

    init(item: WorkItem?) {
        guard let item else {
            canOpenSource = false
            canArchive = false
            canUnarchive = false
            canSnooze = false
            canClearSnooze = false
            canMarkWaiting = false
            canClearWaiting = false
            return
        }

        canOpenSource = item.sourceURL.map(GitHubMarkdownPolicy.permitsExternalNavigation(to:)) ?? false
        canArchive = item.workflow.status != .archived
        canUnarchive = item.workflow.status == .archived
        canSnooze = item.workflow.status != .archived
        canClearSnooze = item.workflow.snoozedUntil != nil
        canMarkWaiting = item.workflow.status != .waiting && item.workflow.status != .archived
        canClearWaiting = item.workflow.status == .waiting
    }
}

/// The command surface is deliberately thin: it routes every mutation to the
/// same explicit app-model API used by toolbars and contextual controls.
/// Attach this from the main window scene with `.commands`.
struct TriageWorkspaceCommands: Commands {
    @ObservedObject var appModel: TriageAppModel
    @ObservedObject var navigation: AppNavigationModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var externalNavigation: ExternalNavigationConfirmationCoordinator
    @FocusedBinding(\.triageSearchFocus) private var searchFocus
    @FocusedBinding(\.triageInspectorVisibility) private var inspectorVisible
    @FocusedBinding(\.triageSidebarVisibility) private var sidebarVisible
    @FocusedValue(\.triageWorkflowUndoCoordinator) private var workflowUndo
    @Environment(\.undoManager) private var undoManager

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                TriageFocusedCommandRouting.toggleSidebar($sidebarVisible)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(sidebarVisible == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh GitHub Work") {
                Task {
                    await appModel.refreshSelectedOrganizationAfterAccessCheck()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(appModel.selectedOrganization == nil || appModel.isRefreshing)
        }

        CommandMenu("Navigate") {
            Button("Back") {
                navigateSelectionBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!canNavigateSelectionBack)
            Button("Forward") {
                navigateSelectionForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!canNavigateSelectionForward)
            Divider()
            navigationCommand("Inbox", section: .inbox, key: "1")
            navigationCommand("My Work", section: .myWork, key: "2")
            navigationCommand("Reviews", section: .reviews, key: "3")
            navigationCommand("Waiting", section: .waiting, key: "4")
            navigationCommand("Snoozed", section: .snoozed, key: "5")
            navigationCommand("All Work", section: .allWork, key: "6")
            Divider()
            Button("Focus Search") {
                TriageFocusedCommandRouting.focusSearch($searchFocus)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(searchFocus == nil)
            Button("Toggle Inspector") {
                TriageFocusedCommandRouting.toggleInspector($inspectorVisible)
            }
            .keyboardShortcut("i", modifiers: [.option, .command])
            .disabled(inspectorVisible == nil)
        }

        CommandMenu("Work") {
            Button("Open on GitHub") {
                guard let sourceURL = appModel.selectedWorkItem?.sourceURL else { return }
                externalNavigation.requestOpen(sourceURL)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!availability.canOpenSource)
            .accessibilityHint("Requests confirmation before opening the selected HTTPS source in GitHub. It does not change GitHub.")

            Divider()

            Button("Archive in Triage") {
                apply(.archive)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!availability.canArchive)
            .accessibilityHint(localWorkflowHint)

            Button("Restore in Triage") {
                apply(.unarchive)
            }
            .disabled(!availability.canUnarchive)
            .accessibilityHint(localWorkflowHint)

            Button(selectedWorkItem?.workflow.isPinned == true ? "Unpin in Triage" : "Pin in Triage") {
                guard let item = selectedWorkItem else { return }
                apply(.setPinned(!item.workflow.isPinned))
            }
            .keyboardShortcut("p", modifiers: [.control, .command])
            .disabled(selectedWorkItem == nil)
            .accessibilityHint(localWorkflowHint)

            Menu("Set Priority") {
                priorityCommand("Low", priority: .low, key: "1")
                priorityCommand("Normal", priority: .normal, key: "2")
                priorityCommand("High", priority: .high, key: "3")
            }
            .disabled(selectedWorkItem == nil)
            .accessibilityHint(localWorkflowHint)

            Menu("Snooze") {
                ForEach(InboxSnoozeSlot.allCases) { slot in
                    Button(preferences.inboxSnoozeDurations.title(for: slot)) {
                        apply(
                            .snooze(
                                until: Date().addingTimeInterval(
                                    TimeInterval(preferences.inboxSnoozeDurations.minutes(for: slot) * 60)
                                )
                            )
                        )
                    }
                    .accessibilityHint(localWorkflowHint)
                }
                Divider()
                Button("End Snooze") {
                    apply(.clearSnooze)
                }
                .disabled(!availability.canClearSnooze)
                .accessibilityHint(localWorkflowHint)
            }
            .disabled(!availability.canSnooze && !availability.canClearSnooze)
            .accessibilityHint(localWorkflowHint)

            Button("Mark Waiting") {
                guard let workflow = selectedWorkItem?.workflow,
                      let action = WorkDetailPresentation.waitingAction(for: workflow)
                else { return }
                apply(action)
            }
            .keyboardShortcut("w", modifiers: [.control, .command])
            .disabled(!availability.canMarkWaiting)
            .accessibilityHint(localWorkflowHint)

            Button("Stop Waiting") {
                guard let workflow = selectedWorkItem?.workflow,
                      let action = WorkDetailPresentation.waitingAction(for: workflow)
                else { return }
                apply(action)
            }
            .disabled(!availability.canClearWaiting)
            .accessibilityHint(localWorkflowHint)
        }
    }

    private var selectedWorkItem: WorkItem? {
        appModel.selectedWorkItem
    }

    private var availability: TriageWorkflowCommandAvailability {
        TriageWorkflowCommandAvailability(item: selectedWorkItem)
    }

    private var validWorkItemIDs: Set<WorkItemID> {
        appModel.selectableWorkItemIDs
    }

    private var canNavigateSelectionBack: Bool {
        navigation.canNavigateSelectionBack(
            accountID: appModel.selectedAccountID,
            organizationID: appModel.selectedOrganizationID,
            validWorkItemIDs: validWorkItemIDs
        )
    }

    private var canNavigateSelectionForward: Bool {
        navigation.canNavigateSelectionForward(
            accountID: appModel.selectedAccountID,
            organizationID: appModel.selectedOrganizationID,
            validWorkItemIDs: validWorkItemIDs
        )
    }

    private func navigateSelectionBack() {
        guard let workItemID = navigation.navigateSelectionBack(
            accountID: appModel.selectedAccountID,
            organizationID: appModel.selectedOrganizationID,
            validWorkItemIDs: validWorkItemIDs
        ) else { return }
        appModel.selectedWorkItemID = workItemID
    }

    private func navigateSelectionForward() {
        guard let workItemID = navigation.navigateSelectionForward(
            accountID: appModel.selectedAccountID,
            organizationID: appModel.selectedOrganizationID,
            validWorkItemIDs: validWorkItemIDs
        ) else { return }
        appModel.selectedWorkItemID = workItemID
    }

    private var localWorkflowHint: String {
        "Changes only Triage’s local workflow state; it does not modify GitHub."
    }

    private func navigationCommand(_ title: String, section: AppSection, key: KeyEquivalent) -> some View {
        Button(title) {
            navigation.section = section
        }
        .keyboardShortcut(key, modifiers: .command)
    }

    private func priorityCommand(_ title: String, priority: WorkPriority, key: KeyEquivalent) -> some View {
        Button(title) {
            apply(.setPriority(priority))
        }
        .keyboardShortcut(key, modifiers: [.control, .command])
    }

    private func apply(_ action: WorkflowAction) {
        guard let item = selectedWorkItem else { return }
        let targets = appModel.selectedWorkItems
        Task {
            if let workflowUndo {
                await workflowUndo.perform(
                    action,
                    to: targets.isEmpty ? [item] : targets,
                    appModel: appModel,
                    undoManager: undoManager
                )
            } else {
                await appModel.applyWorkflowAction(action, to: targets.isEmpty ? [item] : targets)
            }
        }
    }
}
