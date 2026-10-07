import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case accounts
    case organizations
    case ai
    case rules
    case general
    case updates
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .ai: "AI"
        default: rawValue.capitalized
        }
    }

    var systemImage: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .organizations: "building.2"
        case .ai: "sparkles"
        case .rules: "line.3.horizontal.decrease.circle"
        case .general: "gearshape"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
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
            .flatMap(SettingsCategory.init(rawValue:)) ?? .accounts
    }

    func openSettings(_ category: SettingsCategory) {
        settingsCategory = category
    }

    /// No per-account navigation state is persisted.
    func purgeSelectionState(for _: AccountID) {}
}
