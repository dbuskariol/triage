import Foundation
import ServiceManagement

enum TriagePreferenceKeys {
    static let showMenuBarExtra = "interface.show-menu-bar-extra"
    static let sortField = "interface.sort-field"
    static let grouping = "interface.grouping"
    static let refreshIntervalMinutes = "sync.refresh-interval-minutes"
    static let refreshWhenActive = "sync.refresh-when-active"
    static let laterTodayHours = "inbox.later-today-hours"
    static let tomorrowHour = "inbox.tomorrow-hour"
    static let autoDoneHandled = "inbox.auto-done-handled"
    static let sortAscending = "interface.sort-ascending"
    static let followUpDays = "inbox.follow-up-days"
    static let defaultFollowUpDays = 3
    static let showDockBadge = "interface.show-dock-badge"
    static let notifyNeedsAction = "notifications.needs-action"
    static let notifyFollowUps = "notifications.follow-ups"
    static let quietHoursEnabled = "notifications.quiet-hours"
    static let quietHoursStart = "notifications.quiet-hours-start"
    static let quietHoursEnd = "notifications.quiet-hours-end"
    static let writingStyle = "drafts.writing-style"
    static let onboardingCompleted = "interface.onboarding.completed"
    static let launchDestination = "interface.launch-destination"
    static let lastDestination = "interface.last-destination"
    static let markReadPolicy = "inbox.mark-read"
    static let readBaseline = "inbox.read-baseline-v2"
}

extension UserDefaults {
    /// Triage's preferences store: always `.standard`, except in a Debug
    /// UI-test fixture launch, which uses an isolated per-session suite so
    /// tests never read or change the user's preferences.
    static var triage: UserDefaults {
        #if DEBUG
        if let fixture = TriageUITestFixtureLaunch.current, let defaults = UserDefaults(suiteName: fixture.defaultsSuiteName) {
            return defaults
        }
        #endif
        return .standard
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var showMenuBarExtra: Bool {
        didSet { defaults.set(showMenuBarExtra, forKey: TriagePreferenceKeys.showMenuBarExtra) }
    }
    /// Minutes between automatic refreshes; `0` means manual only.
    @Published var refreshIntervalMinutes: Int {
        didSet { defaults.set(refreshIntervalMinutes, forKey: TriagePreferenceKeys.refreshIntervalMinutes) }
    }
    @Published var refreshWhenActive: Bool {
        didSet { defaults.set(refreshWhenActive, forKey: TriagePreferenceKeys.refreshWhenActive) }
    }
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .triage) {
        self.defaults = defaults
        showMenuBarExtra = defaults.object(forKey: TriagePreferenceKeys.showMenuBarExtra) as? Bool ?? true
        refreshIntervalMinutes = Self.refreshIntervalMinutes(defaults)
        refreshWhenActive = defaults.object(forKey: TriagePreferenceKeys.refreshWhenActive) as? Bool ?? true
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

extension AppPreferences {
    nonisolated static let refreshIntervalChoices = [2, 5, 10, 15, 30, 60, 0]
    nonisolated static let defaultRefreshIntervalMinutes = 5

    nonisolated static func refreshIntervalMinutes(_ defaults: UserDefaults = .triage) -> Int {
        let stored = defaults.object(forKey: TriagePreferenceKeys.refreshIntervalMinutes) as? Int
        return stored.flatMap { refreshIntervalChoices.contains($0) ? $0 : nil } ?? defaultRefreshIntervalMinutes
    }

    nonisolated static func refreshInterval(minutes: Int) -> Duration? {
        minutes > 0 ? .seconds(minutes * 60) : nil
    }

    nonisolated static func refreshIntervalTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Manually"
        case 60: "Every hour"
        default: "Every \(minutes) minutes"
        }
    }
}

/// When scroll bars appear in Triage, overriding System Settings ▸
/// Appearance ▸ Show scroll bars for Triage only. Stored under AppKit's
/// `AppleShowScrollBars` default in Triage's own domain, which AppKit reads at
/// launch, so a change applies the next time Triage opens.
enum ScrollBarVisibility: String, CaseIterable, Identifiable, Sendable {
    case system, whenScrolling, always

    static let key = "AppleShowScrollBars"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Use System Setting"
        case .whenScrolling: "When Scrolling"
        case .always: "Always"
        }
    }

    /// AppKit's value; `nil` removes the override.
    private var appKitValue: String? {
        switch self {
        case .system: nil
        case .whenScrolling: "WhenScrolling"
        case .always: "Always"
        }
    }

    /// The saved choice, from Triage's own domain (not the global setting).
    static func saved(_ defaults: UserDefaults = .standard) -> Self {
        let domain = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        return allCases.first { $0.appKitValue == domain[key] as? String } ?? .system
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(appKitValue, forKey: Self.key)
    }
}

/// When viewing an item's details marks it read, like Mail.
enum MarkReadPolicy: String, CaseIterable, Identifiable, Sendable {
    case immediately, afterDelay, manually

    var id: Self { self }

    var title: String {
        switch self {
        case .immediately: "Immediately"
        case .afterDelay: "After viewing for 2 seconds"
        case .manually: "Only when I mark them"
        }
    }

    /// How long details must stay on screen; `nil` never marks automatically.
    var delay: Duration? {
        switch self {
        case .immediately: .zero
        case .afterDelay: .seconds(2)
        case .manually: nil
        }
    }

    static func current(_ defaults: UserDefaults = .triage) -> Self {
        defaults.string(forKey: TriagePreferenceKeys.markReadPolicy).flatMap(Self.init) ?? .afterDelay
    }
}

/// Snooze times shared by every snooze control, using the user's preferences.
enum SnoozeOption: CaseIterable, Identifiable {
    case laterToday, tomorrow, inThreeDays, nextWeek, inSevenDays

    var id: Self { self }

    var title: String {
        switch self {
        case .laterToday: "Later Today"
        case .tomorrow: "Tomorrow"
        case .inThreeDays: "In 3 Days"
        case .nextWeek: "Next Week"
        case .inSevenDays: "In 7 Days"
        }
    }

    func date(from now: Date = .now, defaults: UserDefaults = .triage, calendar: Calendar = .current) -> Date {
        let hour = Self.morningHour(defaults)
        switch self {
        case .laterToday:
            let hours = defaults.object(forKey: TriagePreferenceKeys.laterTodayHours) as? Int ?? 3
            return now.addingTimeInterval(TimeInterval(max(1, hours) * 3_600))
        case .tomorrow: return Self.morning(daysAfter: 1, now, hour: hour, calendar: calendar)
        case .inThreeDays: return Self.morning(daysAfter: 3, now, hour: hour, calendar: calendar)
        case .nextWeek: return Self.nextMonday(after: now, hour: hour, calendar: calendar)
        case .inSevenDays: return Self.morning(daysAfter: 7, now, hour: hour, calendar: calendar)
        }
    }

    /// "Monday 9:00 AM" within the coming week; dates further out include the day and month.
    func subtitle(from now: Date = .now, defaults: UserDefaults = .triage, calendar: Calendar = .current) -> String {
        let date = date(from: now, defaults: defaults, calendar: calendar)
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        var style = days < 6
            ? Date.FormatStyle().weekday(.wide).hour().minute()
            : Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// The hour every morning snooze returns at (Settings ▸ General ▸ Snooze).
    static func morningHour(_ defaults: UserDefaults) -> Int {
        min(23, max(0, defaults.object(forKey: TriagePreferenceKeys.tomorrowHour) as? Int ?? 9))
    }

    private static func morning(daysAfter days: Int, _ now: Date, hour: Int, calendar: Calendar) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    /// The start of the next work week: the first Monday after today, so on a
    /// Monday it is the following Monday rather than later the same day.
    private static func nextMonday(after now: Date, hour: Int, calendar: Calendar) -> Date {
        // `weekday` is 1 = Sunday … 7 = Saturday in every locale; Monday is 2.
        let weekday = calendar.component(.weekday, from: now)
        let days = (2 - weekday + 7) % 7
        return morning(daysAfter: days == 0 ? 7 : days, now, hour: hour, calendar: calendar)
    }
}
