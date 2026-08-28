import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Triage")
                        .font(.headline)
                    Text("Ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Button("Open Triage") {
                navigation.section = .inbox
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")

            Button("Settings…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Button("Check for Updates…") {
                softwareUpdates.checkForUpdates()
            }
            .disabled(!softwareUpdates.canCheckForUpdates)

            Divider()

            Button("Quit Triage") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 250)
    }
}
