import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case inbox
    case notifications
    case accounts
    case ai
    case rules
    case updates

    var id: Self { self }

    var title: String {
        switch self {
        case .ai: "Copilot"
        default: rawValue.capitalized
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray.full"
        case .notifications: "bell.badge"
        case .accounts: "person.crop.circle"
        case .ai: "sparkles"
        case .rules: "line.3.horizontal.decrease.circle"
        case .general: "gearshape"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

/// The main `Window` identifier; SwiftUI keys frame restoration by it.
enum WorkspaceWindowRestoration {
    static let mainWindowFrameIdentifier = "main"
}

/// Settings-window navigation. Workspace selection lives in `TriageAppModel`.
@MainActor
final class AppNavigationModel: ObservableObject {
    private static let settingsCategoryKey = "settings.selected-category"

    @Published var settingsCategory: SettingsCategory {
        didSet { defaults.set(settingsCategory.rawValue, forKey: Self.settingsCategoryKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settingsCategory = defaults.string(forKey: Self.settingsCategoryKey)
            .flatMap(SettingsCategory.init(rawValue:)) ?? .general
    }

    func openSettings(_ category: SettingsCategory) {
        settingsCategory = category
    }

    /// No per-account navigation state is persisted.
    func purgeSelectionState(for _: AccountID) {}
}
