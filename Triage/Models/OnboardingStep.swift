import Foundation

/// The Setup Assistant's steps, in order. GitHub and an organization are
/// required; everything after is recommended and can be changed in Settings.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome, github, organization, copilot, notifications, mac, ready

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .github: "GitHub"
        case .organization: "Organization"
        case .copilot: "Copilot"
        case .notifications: "Notifications"
        case .mac: "Your Mac"
        case .ready: "Ready"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "hand.wave"
        case .github: "person.crop.circle.badge.checkmark"
        case .organization: "building.2"
        case .copilot: "sparkles"
        case .notifications: "bell.badge"
        case .mac: "macwindow"
        case .ready: "checkmark.seal"
        }
    }

    /// What has been set up so far, for the step list and gating.
    struct Facts: Equatable, Sendable {
        var hasAccount = false
        var hasOrganization = false
        var isCopilotReady = false
        var isNotificationsDecided = false
        var hasVisitedMac = false
    }

    func isComplete(_ facts: Facts) -> Bool {
        switch self {
        case .welcome: true
        case .github: facts.hasAccount
        case .organization: facts.hasOrganization
        case .copilot: facts.isCopilotReady
        case .notifications: facts.isNotificationsDecided
        case .mac: facts.hasVisitedMac
        case .ready: false
        }
    }

    /// Whether Continue may leave this step. Optional steps can be skipped.
    func canContinue(_ facts: Facts) -> Bool {
        switch self {
        case .github: facts.hasAccount
        case .organization: facts.hasOrganization
        default: true
        }
    }

    /// Whether a step can be opened from the step list: only after every
    /// required step before it is done.
    func isReachable(_ facts: Facts) -> Bool {
        Self.allCases.prefix(while: { $0 != self }).allSatisfy { $0.canContinue(facts) }
    }

    var next: Self? { Self(rawValue: rawValue + 1) }
    var previous: Self? { Self(rawValue: rawValue - 1) }
}
