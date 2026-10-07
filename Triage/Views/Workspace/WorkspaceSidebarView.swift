import SwiftUI

struct WorkspaceSidebarView<Pickers: View>: View {
    let presentation: WorkspacePresentation
    @Binding var selection: WorkspacePresentation.Section
    @ViewBuilder let pickers: () -> Pickers

    init(
        presentation: WorkspacePresentation,
        selection: Binding<WorkspacePresentation.Section>,
        @ViewBuilder pickers: @escaping () -> Pickers
    ) {
        self.presentation = presentation
        _selection = selection
        self.pickers = pickers
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                pickers()
            }

            Section {
                row(.inbox, showsBadge: true)
            }

            Section("Other work") {
                row(.waiting)
                row(.informational)
                row(.analyzing, showsBadge: presentation.count(in: .analyzing) > 0)
                row(.handled)
                if presentation.count(in: .muted) > 0 || selection == .muted {
                    row(.muted, showsBadge: true)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Triage sidebar")
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

    private func row(_ section: WorkspacePresentation.Section, showsBadge: Bool = false) -> some View {
        Label {
            HStack {
                Text(section.title)
                Spacer(minLength: 8)
                if showsBadge {
                    Text(presentation.count(in: section), format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(presentation.count(in: section)) items")
                }
            }
        } icon: {
            Image(systemName: section.systemImage)
        }
        .tag(section)
        .accessibilityLabel(
            showsBadge ? "\(section.title), \(presentation.count(in: section)) items" : section.title
        )
    }
}

extension WorkspaceSidebarView where Pickers == EmptyView {
    init(presentation: WorkspacePresentation, selection: Binding<WorkspacePresentation.Section>) {
        self.init(presentation: presentation, selection: selection) { EmptyView() }
    }
}
