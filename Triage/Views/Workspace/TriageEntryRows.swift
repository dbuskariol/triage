import SwiftUI

/// List rows with swipe actions, shared by the section lists and saved
/// searches. The context menu is attached to the list so it acts on the
/// whole selection.
struct TriageEntryRows: View {
    let entries: [TriageEntry]
    let selection: Set<GitHubNodeID>
    /// Done and snoozed items offer Restore instead of Done and Snooze.
    let setAsideIDs: Set<GitHubNodeID>
    let actions: any WorkspaceActions
    var sectionLabel: (TriageEntry) -> String? = { _ in nil }

    var body: some View {
        ForEach(entries) { entry in
            TriageEntryRow(entry: entry, isSelected: selection.contains(entry.id), sectionLabel: sectionLabel(entry))
                .tag(entry.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipes(for: entry) }
                .swipeActions(edge: .leading) {
                    Button(entry.isUnread ? "Read" : "Unread") { actions.setRead([entry], entry.isUnread) }
                        .tint(.blue)
                }
        }
    }

    @ViewBuilder
    private func swipes(for entry: TriageEntry) -> some View {
        if setAsideIDs.contains(entry.id) {
            Button("Restore") { actions.restore(entry) }.tint(.blue)
        } else {
            Button("Done") { actions.markDone(entry) }.tint(.green)
            Menu("Snooze") { SnoozeMenuItems(entries: [entry], actions: actions) }
        }
    }
}

/// The item menu, for one entry or a whole selection. Actions that only make
/// sense for one item appear only when one is chosen. Shared by list context
/// menus, dashboards, and the multiple-selection panel.
struct TriageEntryMenu: View {
    let entries: [TriageEntry]
    let setAsideIDs: Set<GitHubNodeID>
    let actions: any WorkspaceActions

    var body: some View {
        let anyUnread = entries.contains(where: \.isUnread)
        let allSetAside = entries.allSatisfy { setAsideIDs.contains($0.id) }
        Button(anyUnread ? "Mark as Read" : "Mark as Unread") { actions.setRead(entries, anyUnread) }
        Divider()
        if allSetAside {
            Button("Restore") { actions.restore(entries) }
        } else {
            Button("Done") { actions.markDone(entries) }
            Menu("Snooze") { SnoozeMenuItems(entries: entries, actions: actions) }
        }
        Divider()
        Button(entries.count == 1 ? "Open on GitHub" : "Open \(entries.count) on GitHub") { actions.openOnGitHub(entries) }
        if let entry = entries.first, entries.count == 1 {
            Button("Draft Reply…") { actions.beginDraft(for: entry) }
            Divider()
            Button("Create Rule…") { actions.beginRule(from: entry, correcting: false) }
        } else if entries.count > 1 {
            Button("Focus on These") { actions.startFocus(entries) }
        }
    }
}

extension WorkspacePresentation {
    /// Done or snoozed work, which offers Restore instead of Done and Snooze.
    var setAsideIDs: Set<GitHubNodeID> { Set((entries(in: .done) + entries(in: .snoozed)).map(\.id)) }
}

/// Mail- and Superhuman-style keys on top of the native ↑/↓ (⇧ extends, ⌘A
/// selects all): j/k move, e/⌫ Done (or Restore), s snoozes until tomorrow,
/// u toggles unread, Return opens on GitHub. Actions apply to the selection.
private struct TriageListKeys: ViewModifier {
    let entries: [TriageEntry]
    @Binding var selection: Set<GitHubNodeID>
    let setAsideIDs: Set<GitHubNodeID>
    let actions: any WorkspaceActions

    func body(content: Content) -> some View {
        content
            .onKeyPress(characters: ["j", "k"]) { press in
                if let next = ListSelection.moved(selection, in: entries.map(\.id), by: press.characters == "j" ? 1 : -1) {
                    selection = [next]
                }
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward, "e"]) { _ in
                let chosen = selected
                guard !chosen.isEmpty else { return .ignored }
                chosen.allSatisfy { setAsideIDs.contains($0.id) } ? actions.restore(chosen) : actions.markDone(chosen)
                return .handled
            }
            .onKeyPress(characters: ["s"]) { _ in
                let chosen = selected.filter { !setAsideIDs.contains($0.id) }
                guard !chosen.isEmpty else { return .ignored }
                actions.snooze(chosen, until: SnoozeOption.tomorrow.date())
                return .handled
            }
            .onKeyPress(characters: ["u"]) { _ in
                let chosen = selected
                guard !chosen.isEmpty else { return .ignored }
                actions.setRead(chosen, chosen.contains(where: \.isUnread))
                return .handled
            }
            .onKeyPress(.return) {
                let chosen = selected
                guard !chosen.isEmpty else { return .ignored }
                actions.openOnGitHub(chosen)
                return .handled
            }
            .onExitCommand {
                if selection.count > 1, let first = selected.first { selection = [first.id] }
            }
    }

    /// Selected entries in display order.
    private var selected: [TriageEntry] {
        entries.filter { selection.contains($0.id) }
    }
}

extension View {
    /// Adds the shared triage keys; `entries` must be in display order.
    func triageListKeys(
        entries: [TriageEntry], selection: Binding<Set<GitHubNodeID>>,
        setAsideIDs: Set<GitHubNodeID>, actions: any WorkspaceActions
    ) -> some View {
        modifier(TriageListKeys(entries: entries, selection: selection, setAsideIDs: setAsideIDs, actions: actions))
    }

    /// The item menu for the clicked rows (or the selection they belong to),
    /// and double-click to open on GitHub.
    func triageContextMenu(
        entries: [TriageEntry], setAsideIDs: Set<GitHubNodeID>, actions: any WorkspaceActions
    ) -> some View {
        contextMenu(forSelectionType: GitHubNodeID.self) { ids in
            let chosen = entries.filter { ids.contains($0.id) }
            if !chosen.isEmpty {
                TriageEntryMenu(entries: chosen, setAsideIDs: setAsideIDs, actions: actions)
            }
        } primaryAction: { ids in
            actions.openOnGitHub(entries.filter { ids.contains($0.id) })
        }
    }
}
