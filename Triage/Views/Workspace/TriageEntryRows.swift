import SwiftUI

/// Selectable rows with the standard context menu and swipe actions, shared
/// by the section lists, saved searches, the Briefing, and the Review.
struct TriageEntryRows: View {
    let entries: [TriageEntry]
    let selectedEntryID: GitHubNodeID?
    /// Done and snoozed items offer Restore instead of Done and Snooze.
    let handledIDs: Set<GitHubNodeID>
    let actions: any WorkspaceActions
    var sectionLabel: (TriageEntry) -> String? = { _ in nil }

    var body: some View {
        ForEach(entries) { entry in
            TriageEntryRow(entry: entry, isSelected: entry.id == selectedEntryID, sectionLabel: sectionLabel(entry))
                .tag(entry.id)
                .contextMenu { menu(for: entry) }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipes(for: entry) }
        }
    }

    @ViewBuilder
    private func menu(for entry: TriageEntry) -> some View {
        if handledIDs.contains(entry.id) {
            Button("Restore") { actions.restore(entry) }
        } else {
            Button("Done") { actions.markDone(entry) }
            Menu("Snooze") { SnoozeMenuItems(entry: entry, actions: actions) }
            Divider()
            Button("Open on GitHub") { actions.openOnGitHub(entry) }
        }
        Divider()
        Button("Create Rule…") { actions.beginRule(from: entry, correcting: false) }
    }

    @ViewBuilder
    private func swipes(for entry: TriageEntry) -> some View {
        if handledIDs.contains(entry.id) {
            Button("Restore") { actions.restore(entry) }.tint(.blue)
        } else {
            Button("Done") { actions.markDone(entry) }.tint(.green)
            Menu("Snooze") { SnoozeMenuItems(entry: entry, actions: actions) }
        }
    }
}

extension WorkspacePresentation {
    var handledIDs: Set<GitHubNodeID> { Set(entries(in: .handled).map(\.id)) }
}

/// Mail- and Superhuman-style keys on top of the native ↑/↓: j/k move,
/// e/⌫ Done (or Restore), s snoozes until tomorrow, Return opens on GitHub.
private struct TriageListKeys: ViewModifier {
    let entries: [TriageEntry]
    @Binding var selectedEntryID: GitHubNodeID?
    let handledIDs: Set<GitHubNodeID>
    let actions: any WorkspaceActions

    func body(content: Content) -> some View {
        content
            .onKeyPress(characters: ["j", "k"]) { press in
                move(by: press.characters == "j" ? 1 : -1)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward, "e"]) { _ in
                guard let entry = selected else { return .ignored }
                handledIDs.contains(entry.id) ? actions.restore(entry) : actions.markDone(entry)
                return .handled
            }
            .onKeyPress(.return) {
                guard let entry = selected else { return .ignored }
                actions.openOnGitHub(entry)
                return .handled
            }
            .onKeyPress(characters: ["s"]) { _ in
                guard let entry = selected, !handledIDs.contains(entry.id) else { return .ignored }
                actions.snooze(entry, until: SnoozeOption.tomorrow.date())
                return .handled
            }
    }

    private var selected: TriageEntry? {
        selectedEntryID.flatMap { id in entries.first { $0.id == id } }
    }

    private func move(by offset: Int) {
        guard !entries.isEmpty else { return }
        guard let id = selectedEntryID, let index = entries.firstIndex(where: { $0.id == id }) else {
            selectedEntryID = (offset > 0 ? entries.first : entries.last)?.id
            return
        }
        selectedEntryID = entries[min(max(index + offset, 0), entries.count - 1)].id
    }
}

extension View {
    /// Adds the shared triage keys; `entries` must be in display order.
    func triageListKeys(
        entries: [TriageEntry], selection: Binding<GitHubNodeID?>,
        handledIDs: Set<GitHubNodeID>, actions: any WorkspaceActions
    ) -> some View {
        modifier(TriageListKeys(entries: entries, selectedEntryID: selection, handledIDs: handledIDs, actions: actions))
    }
}
