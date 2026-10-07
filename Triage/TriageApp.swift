import AppKit
import SwiftUI

@MainActor
private final class TriageApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var appModel: TriageAppModel?
    private var terminationTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    func install(appModel: TriageAppModel) {
        self.appModel = appModel
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appModel?.handleSystemWake() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appModel?.applicationDidBecomeActive()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appModel else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        terminationTask = Task {
            await appModel.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct TriageApp: App {
    @NSApplicationDelegateAdaptor(TriageApplicationDelegate.self) private var appDelegate
    @StateObject private var navigation: AppNavigationModel
    @StateObject private var appModel: TriageAppModel
    @StateObject private var preferences = AppPreferences()
    @StateObject private var softwareUpdates = SoftwareUpdateController()

    init() {
        let navigation = AppNavigationModel()
        _navigation = StateObject(wrappedValue: navigation)
        do {
            let fileManager = FileManager.default
            let composition = TriageProductionComposition(
                vaultRegistry: try VaultRegistry(),
                secretStore: .shared,
                applicationSupportDirectory: try fileManager.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
                ),
                cachesDirectory: try fileManager.url(
                    for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
                )
            )
            _appModel = StateObject(wrappedValue: TriageAppModel(
                dependencies: composition.dependencies(
                    purgeAccountNavigationState: { navigation.purgeSelectionState(for: $0) }
                )
            ))
        } catch {
            fatalError("Triage could not construct its local encrypted workspace.")
        }
    }

    var body: some Scene {
        Window("Triage", id: WorkspaceWindowRestoration.mainWindowFrameIdentifier) {
            RootView()
                .environmentObject(appModel)
                .environmentObject(navigation)
                .environmentObject(preferences)
                .environmentObject(softwareUpdates)
                .frame(minWidth: 940, minHeight: 620)
                .task {
                    guard !Self.isRunningTests else { return }
                    appDelegate.install(appModel: appModel)
                    await appModel.restoreAccounts()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { softwareUpdates.checkForUpdates() }
                    .disabled(!softwareUpdates.canCheckForUpdates)
            }
            TriageWorkspaceCommands(appModel: appModel)
            TriageSettingsWindowCommands()
        }

        MenuBarExtra(isInserted: menuBarExtraInsertion) {
            MenuBarView()
                .environmentObject(appModel)
                .environmentObject(navigation)
        } label: {
            Label("Triage", systemImage: "square.stack.3d.up")
        }
        .menuBarExtraStyle(.window)

        Window("Triage Settings", id: "settings") {
            SettingsView()
                .environmentObject(appModel)
                .environmentObject(navigation)
                .environmentObject(preferences)
                .environmentObject(softwareUpdates)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 820, height: 640)
    }

    /// MenuBarExtra writes its inserted state back during scene updates.
    /// Publishing an unchanged value would re-evaluate the scene recursively.
    private var menuBarExtraInsertion: Binding<Bool> {
        Binding(
            get: { preferences.showMenuBarExtra },
            set: { isInserted in
                guard preferences.showMenuBarExtra != isInserted else { return }
                preferences.showMenuBarExtra = isInserted
            }
        )
    }

    /// The XCTest host launches the app; it must not touch Keychain or GitHub.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

private struct TriageSettingsWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
