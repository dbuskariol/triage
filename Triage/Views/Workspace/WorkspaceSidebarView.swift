import SwiftUI

struct WorkspaceSidebarView<Pickers: View>: View {
    let presentation: WorkspacePresentation
    @Binding var selection: WorkspaceDestination
    var savedSearches: [SavedSearch] = []
    var onRenameSavedSearch: (SavedSearch.ID, String) -> Void = { _, _ in }
    var onDeleteSavedSearch: (SavedSearch.ID) -> Void = { _ in }
    var onMarkAllRead: (WorkspacePresentation.Section) -> Void = { _ in }
    @ViewBuilder let pickers: () -> Pickers
    @State private var renaming: SavedSearch?
    @State private var newName = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                pickers()
            }

            Section {
                Label("Briefing", systemImage: "sun.horizon")
                    .tag(WorkspaceDestination.briefing)
                row(.inbox)
            }

            Section("Other work") {
                row(.waiting)
                row(.informational)
                row(.analyzing, showsBadge: presentation.count(in: .analyzing) > 0)
                row(.snoozed)
                row(.done)
                if presentation.count(in: .muted) > 0 || selection == .section(.muted) {
                    row(.muted, showsBadge: true)
                }
                Label("Weekly Review", systemImage: "chart.bar.xaxis")
                    .tag(WorkspaceDestination.review)
            }

            if !savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(savedSearches) { saved in
                        Label(saved.name, systemImage: "magnifyingglass")
                            .help(saved.search.summary)
                            .tag(WorkspaceDestination.savedSearch(saved.id))
                            .contextMenu {
                                Button("Rename…") {
                                    newName = saved.name
                                    renaming = saved
                                }
                                Button("Delete", role: .destructive) { onDeleteSavedSearch(saved.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Triage sidebar")
        .alert("Rename Saved Search", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { onRenameSavedSearch(renaming.id, newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// Lists show how many items are unread, like Mail; Analyzing and Muted show their size.
    private func row(_ section: WorkspacePresentation.Section, showsBadge: Bool = false) -> some View {
        let countsUnread = ![.analyzing, .muted].contains(section)
        let badge = countsUnread ? presentation.unreadCount(in: section) : presentation.count(in: section)
        let total = presentation.count(in: section)
        let spoken = countsUnread ? "\(badge) unread of \(total)" : "\(total) items"
        return Label {
            HStack {
                Text(section.title)
                Spacer(minLength: 8)
                if (countsUnread || showsBadge), badge > 0 {
                    Text(badge, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: section.systemImage)
        }
        .tag(WorkspaceDestination.section(section))
        .help(countsUnread ? "\(badge) unread, \(total) total" : "\(total) items")
        .contextMenu {
            if countsUnread {
                Button("Mark All as Read") { onMarkAllRead(section) }
                    .disabled(badge == 0)
            }
        }
        .accessibilityLabel("\(section.title), \(spoken)")
    }
}

extension WorkspaceSidebarView where Pickers == EmptyView {
    init(presentation: WorkspacePresentation, selection: Binding<WorkspaceDestination>) {
        self.init(presentation: presentation, selection: selection, pickers: { EmptyView() })
    }
}
