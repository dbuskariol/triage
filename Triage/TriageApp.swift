import SwiftUI

@main
struct TriageApp: App {
    @StateObject private var navigation = AppNavigationModel()
    @StateObject private var appModel = TriageAppModel()
    @StateObject private var preferences = AppPreferences()
    @StateObject private var softwareUpdates = SoftwareUpdateController()

    var body: some Scene {
        Window("Triage", id: "main") {
            RootView()
                .environmentObject(appModel)
                .environmentObject(navigation)
                .environmentObject(preferences)
                .environmentObject(softwareUpdates)
                .frame(minWidth: 940, minHeight: 680)
        }
        .defaultSize(width: 1080, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    softwareUpdates.checkForUpdates()
                }
                .disabled(!softwareUpdates.canCheckForUpdates)
            }
        }

        MenuBarExtra(isInserted: menuBarExtraInsertion) {
            MenuBarView()
                .environmentObject(appModel)
                .environmentObject(navigation)
                .environmentObject(softwareUpdates)
        } label: {
            Label("Triage", systemImage: "square.stack.3d.up")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(navigation)
                .environmentObject(preferences)
                .environmentObject(softwareUpdates)
                .frame(width: 720, height: 620)
        }
    }

    private var menuBarExtraInsertion: Binding<Bool> {
        Binding(
            get: { preferences.showMenuBarExtra },
            set: { isInserted in
                guard preferences.showMenuBarExtra != isInserted else { return }
                preferences.showMenuBarExtra = isInserted
            }
        )
    }
}
