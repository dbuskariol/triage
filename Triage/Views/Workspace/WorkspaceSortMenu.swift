import SwiftUI

/// Sort By choices shared by the toolbar menu and the View menu, backed by
/// user defaults so every window and menu stays in sync.
struct WorkspaceSortMenuContent: View {
    @AppStorage(TriagePreferenceKeys.sortField) private var field = WorkspaceSortField.recommended
    @AppStorage(TriagePreferenceKeys.sortAscending) private var ascending = false

    var body: some View {
        Picker("Sort By", selection: Binding(
            get: { field },
            set: { newValue in
                guard newValue != field else { return }
                field = newValue
                ascending = newValue.defaultAscending
            }
        )) {
            ForEach(WorkspaceSortField.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.inline)

        Picker("Order", selection: $ascending) {
            Text(field == .title || field == .repository ? "A to Z" : "Ascending").tag(true)
            Text(field == .title || field == .repository ? "Z to A" : "Descending").tag(false)
        }
        .pickerStyle(.inline)
        .disabled(!field.supportsDirection)
    }
}

struct WorkspaceSortToolbarMenu: View {
    @AppStorage(TriagePreferenceKeys.sortField) private var field = WorkspaceSortField.recommended

    var body: some View {
        Menu {
            WorkspaceSortMenuContent()
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .help("Sort by \(field.title)")
    }
}
