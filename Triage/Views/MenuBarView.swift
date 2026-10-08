import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: TriageAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appModel.selectedOrganization?.displayName ?? appModel.selectedOrganization?.login ?? "Triage")
                    .font(.headline)
                Text(WorkspaceViewPresentation.statusLine(appModel.presentation.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if inboxEntries.isEmpty {
                Text("You’re all caught up")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(inboxEntries) { entry in
                    Button {
                        appModel.destination = .section(.inbox)
                        appModel.selectedEntryID = entry.id
                        openMainWindow()
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(priorityColor(for: entry))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.item.title)
                                    .lineLimit(1)
                                Text(entry.decision?.reason ?? "Needs your attention")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .accessibilityLabel(entry.item.title)
                }
            }

            Divider()

            Button("Refresh Now") {
                appModel.refreshNow()
            }
            Button("Settings…") {
                appModel.openSettings?(.general)
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit Triage") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 280)
    }

    private var inboxEntries: ArraySlice<TriageEntry> {
        appModel.presentation.entries(in: .inbox).prefix(5)
    }

    private func priorityColor(for entry: TriageEntry) -> Color {
        switch entry.decision?.priority ?? 0 {
        case 80...: .red
        case 50...: .orange
        default: .secondary
        }
    }

    private func openMainWindow() {
        openWindow(id: WorkspaceWindowRestoration.mainWindowFrameIdentifier)
        NSApp.activate(ignoringOtherApps: true)
    }
}
