import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
private final class TriageApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private weak var appModel: TriageAppModel?
    private var notificationActionHandler: (any NotificationLocalActionHandling)?
    private var pendingNotificationActions: [NotificationLocalAction] = []
    private var terminationTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    func install(
        appModel: TriageAppModel,
        notificationActionHandler: any NotificationLocalActionHandling
    ) {
        self.appModel = appModel
        self.notificationActionHandler = notificationActionHandler
        UNUserNotificationCenter.current().delegate = self
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.appModel?.handleSystemWake()
                }
            }
        }
        let pending = pendingNotificationActions
        pendingNotificationActions = []
        Task { @MainActor in
            for action in pending {
                await notificationActionHandler.handle(action)
            }
        }
    }

    private func stopWakeObservation() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        guard !TriageUITestFixture.isRequested else { return }
        #endif
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil, let appModel else {
            return terminationTask == nil ? .terminateNow : .terminateLater
        }
        terminationTask = Task { [weak self, weak sender] in
            self?.stopWakeObservation()
            await appModel.shutdown()
            sender?.reply(toApplicationShouldTerminate: true)
            self?.terminationTask = nil
        }
        return .terminateLater
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let action = NotificationResponseRouter.localAction(from: response) else {
            completionHandler()
            return
        }
        completionHandler()
        Task { @MainActor in
            await handleNotificationAction(action)
        }
    }

    private func handleNotificationAction(_ action: NotificationLocalAction) async {
        guard let notificationActionHandler else {
            pendingNotificationActions.append(action)
            return
        }
        await notificationActionHandler.handle(action)
    }
}

@main
struct TriageApp: App {
    @NSApplicationDelegateAdaptor(TriageApplicationDelegate.self) private var appDelegate
    @StateObject private var navigation: AppNavigationModel
    @StateObject private var appModel: TriageAppModel
    @StateObject private var preferences: AppPreferences
    @StateObject private var notificationSettings: NativeNotificationSettings
    @StateObject private var notificationAuthorization: NotificationSystemAuthorization
    @StateObject private var softwareUpdates: SoftwareUpdateController
    @StateObject private var externalNavigation: ExternalNavigationConfirmationCoordinator
    @StateObject private var workspaceAccessibility: WorkspaceAccessibilityCoordinator
    private let notificationScheduler: UserNotificationCenterScheduler?
    private let notificationResponseAdapter: NotificationResponseApplicationAdapter?
    private let rootDefaults: UserDefaults
    #if DEBUG
    private let uiTestFixture: TriageUITestFixture?
    #endif

    init() {
        #if DEBUG
        do {
            uiTestFixture = try TriageUITestFixture.makeIfRequested()
        } catch {
            fatalError(TriageStartupDiagnostics.workspaceConstructionFatalDiagnostic(for: error))
        }
        #endif

        let workspaceAccessibility = WorkspaceAccessibilityCoordinator()
        _workspaceAccessibility = StateObject(wrappedValue: workspaceAccessibility)
        _externalNavigation = StateObject(wrappedValue: ExternalNavigationConfirmationCoordinator())

        #if DEBUG
        if let fixture = uiTestFixture {
            rootDefaults = fixture.defaults
            let navigation = AppNavigationModel(defaults: fixture.defaults)
            _navigation = StateObject(wrappedValue: navigation)
            _preferences = StateObject(wrappedValue: AppPreferences(defaults: fixture.defaults))
            let notificationSettings = fixture.makeNotificationSettings()
            _notificationSettings = StateObject(wrappedValue: notificationSettings)
            _notificationAuthorization = StateObject(wrappedValue: fixture.makeNotificationAuthorization())
            _softwareUpdates = StateObject(wrappedValue: SoftwareUpdateController(startingUpdater: false))
            notificationScheduler = nil
            notificationResponseAdapter = nil
            _appModel = StateObject(wrappedValue: fixture.makeAppModel(
                workspaceAccessibility: workspaceAccessibility
            ))
            return
        }
        #endif

        rootDefaults = .standard
        let navigation = AppNavigationModel()
        _navigation = StateObject(wrappedValue: navigation)
        let businessDayPolicyPreferences = BusinessDayPolicyPreferences()
        let appPreferences = AppPreferences(
            businessDayPolicyPreferences: businessDayPolicyPreferences
        )
        _preferences = StateObject(wrappedValue: appPreferences)
        _notificationAuthorization = StateObject(wrappedValue: NotificationSystemAuthorization())
        _softwareUpdates = StateObject(wrappedValue: SoftwareUpdateController())
        notificationScheduler = UserNotificationCenterScheduler()
        notificationResponseAdapter = NotificationResponseApplicationAdapter()
        do {
            let notificationSettings = NativeNotificationSettings()
            _notificationSettings = StateObject(wrappedValue: notificationSettings)
            let fileManager = FileManager.default
            let applicationSupportDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let cachesDirectory = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let vaultRegistry = try VaultRegistry()
            let secretStore = KeychainSecretStore()
            notificationSettings.configureEncryptedConsent(
                vaultRegistry: vaultRegistry,
                secretStore: secretStore
            )
            let composition = TriageProductionComposition(
                vaultRegistry: vaultRegistry,
                secretStore: secretStore,
                applicationSupportDirectory: applicationSupportDirectory,
                cachesDirectory: cachesDirectory
            )
            _appModel = StateObject(wrappedValue: TriageAppModel(
                dependencies: composition.dependencies(
                    notificationSettings: notificationSettings,
                    notificationDeliveryLeaseGate: notificationSettings.notificationDeliveryLeaseGate,
                    businessDayPolicyProvider: { businessDayPolicyPreferences.policy() },
                    purgeAccountNavigationState: { accountID in
                        navigation.purgeSelectionState(for: accountID)
                    },
                    purgeAccountNotificationPreferences: { accountID in
                        await notificationSettings.removeAccountPreferences(for: accountID)
                    }
                ),
                vaultRegistry: vaultRegistry,
                workspaceAccessibility: workspaceAccessibility,
                automaticRefreshEnabled: appPreferences.refreshBehavior == .automatic
            ))
        } catch {
            fatalError(TriageStartupDiagnostics.workspaceConstructionFatalDiagnostic(for: error))
        }
    }

    var body: some Scene {
        Window("Triage", id: WorkspaceWindowRestoration.mainWindowFrameIdentifier) {
            ExternalNavigationConfirmationHost(coordinator: externalNavigation) {
                RootView(defaults: rootDefaults)
                    .environmentObject(appModel)
                    .environmentObject(navigation)
                    .environmentObject(preferences)
                    .environmentObject(notificationSettings)
                    .environmentObject(notificationAuthorization)
                    .environmentObject(softwareUpdates)
                    .environmentObject(workspaceAccessibility)
                    .frame(minWidth: 940, minHeight: 680)
                    .task {
                        #if DEBUG
                        if let uiTestFixture {
                            await uiTestFixture.bootstrap(appModel)
                            return
                        }
                        #endif
                        guard let notificationResponseAdapter, let notificationScheduler else { return }
                        notificationResponseAdapter.install(routeHandler: appModel)
                        appDelegate.install(
                            appModel: appModel,
                            notificationActionHandler: notificationResponseAdapter
                        )
                        await appModel.restoreAccounts()
                        if preferences.refreshBehavior == .automatic {
                            await appModel.startAutomaticRefreshes()
                            await appModel.refreshSelectedOrganizationAfterAccessCheck()
                            await appModel.launchOrganizationRefreshLifecycle()
                        }
                        await notificationScheduler.registerLocalActions()
                    }
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
            TriageWorkspaceCommands(
                appModel: appModel,
                navigation: navigation,
                preferences: preferences,
                externalNavigation: externalNavigation
            )
            TriageSettingsWindowCommands()
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

        Window("Triage Settings", id: "settings") {
            SettingsView()
                .environmentObject(appModel)
                .environmentObject(navigation)
                .environmentObject(preferences)
                .environmentObject(notificationSettings)
                .environmentObject(notificationAuthorization)
                .environmentObject(softwareUpdates)
                .frame(
                    minWidth: SettingsSidebarLayout.minimumWindowWidth,
                    idealWidth: SettingsSidebarLayout.defaultWindowWidth,
                    minHeight: 620,
                    idealHeight: 680
                )
        }
        .defaultSize(
            width: SettingsSidebarLayout.defaultWindowWidth,
            height: 680
        )
        .windowStyle(.hiddenTitleBar)
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

private struct TriageSettingsWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

enum TriageStartupDiagnostics {
    static func workspaceConstructionFatalDiagnostic(for _: Error) -> String {
        "Triage could not construct its local encrypted workspace."
    }
}
