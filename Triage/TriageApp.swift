import AppKit
import SwiftUI

@MainActor
private final class TriageApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var appModel: TriageAppModel?
    private var terminationTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Created before launch finishes so it is the notification delegate in
    /// time to receive the click that launched Triage.
    private var attention: AttentionNotifier?
    /// A notification click received before the workspace was installed.
    private var pendingTarget: AttentionTarget?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !TriageApp.isRunningTests, !TriageApp.isUITestFixture else { return }
        let attention = AttentionNotifier()
        attention.onOpen = { [weak self] target in
            guard let self else { return }
            if let appModel { appModel.open(target) } else { pendingTarget = target }
        }
        self.attention = attention
    }

    func install(appModel: TriageAppModel) {
        self.appModel = appModel
        guard wakeObserver == nil else { return }
        if let attention {
            appModel.onPresentationChange = { presentation, organizationID in
                attention.process(presentation, organizationID: organizationID)
            }
        }
        if let pendingTarget {
            appModel.open(pendingTarget)
            self.pendingTarget = nil
        }
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
    @StateObject private var preferences: AppPreferences
    @StateObject private var softwareUpdates: SoftwareUpdateController
    #if DEBUG
    private let uiTestFixture: TriageUITestFixture?
    #endif

    init() {
        let navigation = AppNavigationModel()
        _navigation = StateObject(wrappedValue: navigation)
        _preferences = StateObject(wrappedValue: AppPreferences())
        #if DEBUG
        if let launch = TriageUITestFixtureLaunch.current {
            do {
                let fixture = try TriageUITestFixture(launch: launch)
                uiTestFixture = fixture
                let dependencies = try fixture.dependencies()
                _appModel = StateObject(wrappedValue: TriageAppModel(dependencies: dependencies))
                _softwareUpdates = StateObject(wrappedValue: SoftwareUpdateController(startingUpdater: false))
            } catch {
                fatalError("Triage could not create its UI-test fixture workspace.")
            }
            return
        }
        uiTestFixture = nil
        #endif
        _softwareUpdates = StateObject(wrappedValue: SoftwareUpdateController())
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
                .defaultAppStorage(.triage)
                .task {
                    guard !Self.isRunningTests else { return }
                    appDelegate.install(appModel: appModel)
                    await appModel.restoreAccounts()
                    #if DEBUG
                    uiTestFixture?.didRestoreAccounts(appModel)
                    #endif
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { softwareUpdates.checkForUpdates() }
                    .disabled(!softwareUpdates.canCheckForUpdates)
            }
            TriageWorkspaceCommands(appModel: appModel)
        }

        MenuBarExtra(isInserted: menuBarExtraInsertion) {
            MenuBarView()
                .environmentObject(appModel)
                .environmentObject(navigation)
                .defaultAppStorage(.triage)
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
                .defaultAppStorage(.triage)
        }
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
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// A Debug UI-test fixture launch: local fixture data only, and no
    /// notifications or Dock badge from the user's notification center.
    static var isUITestFixture: Bool {
        #if DEBUG
        TriageUITestFixtureLaunch.current != nil
        #else
        false
        #endif
    }
}

