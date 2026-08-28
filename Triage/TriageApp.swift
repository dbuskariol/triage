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

            CommandMenu("Work") {
                Button("Archive in Triage") {
                    applyWorkflow(.archive)
                }
                .disabled(appModel.selectedWorkItem == nil)
                .keyboardShortcut(.delete, modifiers: .command)

                Button("Pin") {
                    guard let item = appModel.selectedWorkItem else { return }
                    applyWorkflow(.setPinned(!item.workflow.isPinned))
                }
                .disabled(appModel.selectedWorkItem == nil)
                .keyboardShortcut("p", modifiers: [.control, .command])

                Menu("Priority") {
                    priorityCommand("Low", priority: .low, key: "1")
                    priorityCommand("Normal", priority: .normal, key: "2")
                    priorityCommand("High", priority: .high, key: "3")
                }

                Menu("Snooze") {
                    snoozeCommand("1 Hour", interval: 3_600)
                    snoozeCommand("Tomorrow", interval: 86_400)
                    snoozeCommand("Next Week", interval: 7 * 86_400)
                }

                Button("Mark Waiting") {
                    applyWorkflow(.markWaiting(followUpAt: nil))
                }
                .disabled(appModel.selectedWorkItem == nil)
                .keyboardShortcut("w", modifiers: [.control, .command])
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

    private func priorityCommand(
        _ title: String,
        priority: WorkPriority,
        key: KeyEquivalent
    ) -> some View {
        Button(title) {
            applyWorkflow(.setPriority(priority))
        }
        .disabled(appModel.selectedWorkItem == nil)
        .keyboardShortcut(key, modifiers: [.control, .command])
    }

    private func applyWorkflow(_ action: WorkflowAction) {
        guard let item = appModel.selectedWorkItem else { return }
        Task {
            await appModel.applyWorkflowAction(action, to: item)
        }
    }

    private func snoozeCommand(_ title: String, interval: TimeInterval) -> some View {
        Button(title) {
            applyWorkflow(.snooze(until: Date().addingTimeInterval(interval)))
        }
        .disabled(appModel.selectedWorkItem == nil)
    }
}
