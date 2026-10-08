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

    init(defaults: UserDefaults = .standard) {
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

    nonisolated static func refreshIntervalMinutes(_ defaults: UserDefaults = .standard) -> Int {
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

    static func current(_ defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: TriagePreferenceKeys.markReadPolicy).flatMap(Self.init) ?? .afterDelay
    }
}

/// Snooze times shared by every snooze control, using the user's preferences.
enum SnoozeOption: CaseIterable, Identifiable {
    case laterToday, tomorrow, nextWeek

    var id: Self { self }

    var title: String {
        switch self {
        case .laterToday: "Later Today"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next Week"
        }
    }

    func date(from now: Date = .now, defaults: UserDefaults = .standard, calendar: Calendar = .current) -> Date {
        switch self {
        case .laterToday:
            let hours = defaults.object(forKey: TriagePreferenceKeys.laterTodayHours) as? Int ?? 3
            return now.addingTimeInterval(TimeInterval(max(1, hours) * 3_600))
        case .tomorrow:
            let hour = Self.preferredMorningHour(defaults)
            let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        case .nextWeek:
            return Self.nextMonday(
                from: now,
                hour: Self.preferredMorningHour(defaults),
                calendar: calendar
            )
        }
    }

    /// e.g. "Tomorrow, 9:00 AM" for menus.
    func subtitle(from now: Date = .now) -> String {
        date(from: now).formatted(.dateTime.weekday(.wide).hour().minute())
    }

    /// Shared by Tomorrow and Next Week. Settings stores this as `tomorrowHour`.
    nonisolated static func preferredMorningHour(_ defaults: UserDefaults) -> Int {
        let hour = defaults.object(forKey: TriagePreferenceKeys.tomorrowHour) as? Int ?? 9
        return min(23, max(0, hour))
    }

    /// Next week's Monday at `hour`:00. If today is Monday, that's next Monday,
    /// not later this morning.
    nonisolated static func nextMonday(
        from now: Date,
        hour: Int,
        calendar: Calendar
    ) -> Date {
        let mondayWeekday = calendar.component(
            .weekday,
            from: calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)) ?? now
        )
        var matching = DateComponents()
        matching.weekday = mondayWeekday
        matching.hour = hour
        matching.minute = 0
        matching.second = 0
        let upcoming = calendar.nextDate(
            after: now,
            matching: matching,
            matchingPolicy: .nextTime
        ) ?? now
        if calendar.isDate(upcoming, inSameDayAs: now) {
            return calendar.date(byAdding: .day, value: 7, to: upcoming) ?? upcoming
        }
        return upcoming
    }
}
