import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case inbox
    case myWork
    case reviews
    case waiting
    case snoozed
    case allWork

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .myWork: "My Work"
        case .reviews: "Reviews"
        case .waiting: "Waiting"
        case .snoozed: "Snoozed"
        case .allWork: "All Work"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .myWork: "person.crop.circle"
        case .reviews: "text.badge.checkmark"
        case .waiting: "hourglass"
        case .snoozed: "clock"
        case .allWork: "rectangle.stack"
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
    @Published var section: AppSection = .inbox
    @Published var settingsCategory: SettingsCategory = .general

    func openSettings(_ category: SettingsCategory = .general) {
        settingsCategory = category
        section = .inbox
    }
}
