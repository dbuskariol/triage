import SwiftUI

@main
struct TriageApp: App {
    @StateObject private var navigation = AppNavigationModel()
    @StateObject private var appModel = TriageAppModel()
    @StateObject private var preferences = AppPreferences()
    @StateObject private var softwareUpdates = SoftwareUpdateController()
    private let notificationScheduler = UserNotificationCenterScheduler()

    var body: some Scene {
        Window("Triage", id: "main") {
            RootView()
                .environmentObject(appModel)
                .environmentObject(navigation)
                .environmentObject(preferences)
                .environmentObject(softwareUpdates)
                .frame(minWidth: 940, minHeight: 680)
                .task {
                    await appModel.restoreAccounts()
                    await notificationScheduler.registerLocalActions()
                }
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

            CommandGroup(after: .toolbar) {
                Button("Refresh GitHub Work") {
                    Task {
                        await appModel.refreshSelectedOrganization()
                    }
                }
                .disabled(appModel.selectedOrganization == nil || appModel.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandMenu("Navigate") {
                navigationCommand("Inbox", section: .inbox, key: "1")
                navigationCommand("My Work", section: .myWork, key: "2")
                navigationCommand("Reviews", section: .reviews, key: "3")
                navigationCommand("Waiting", section: .waiting, key: "4")
                navigationCommand("Snoozed", section: .snoozed, key: "5")
                navigationCommand("All Work", section: .allWork, key: "6")
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
                .environmentObject(appModel)
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

    private func navigationCommand(
        _ title: String,
        section: AppSection,
        key: KeyEquivalent
    ) -> some View {
        Button(title) {
            navigation.section = section
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}
