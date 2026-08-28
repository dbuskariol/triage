import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .settings: "gearshape"
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case updates
    case about

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class AppNavigationModel: ObservableObject {
    @Published var section: AppSection = .overview
    @Published var settingsCategory: SettingsCategory = .general

    func openSettings(_ category: SettingsCategory = .general) {
        settingsCategory = category
        section = .settings
    }
}
