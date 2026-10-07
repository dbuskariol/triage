import Foundation
import ServiceManagement

enum TriagePreferenceKeys {
    static let showMenuBarExtra = "interface.show-menu-bar-extra"
    static let sortField = "interface.sort-field"
    static let sortAscending = "interface.sort-ascending"
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var showMenuBarExtra: Bool {
        didSet { defaults.set(showMenuBarExtra, forKey: TriagePreferenceKeys.showMenuBarExtra) }
    }
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarExtra = defaults.object(forKey: TriagePreferenceKeys.showMenuBarExtra) as? Bool ?? true
        refreshLaunchAtLoginStatus()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }
}
