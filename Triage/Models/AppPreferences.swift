import Combine
import Foundation
import ServiceManagement

enum TriagePreferenceKeys {
    static let showMenuBarExtra = "interface.show-menu-bar-extra"
    static let staleAfterBusinessDays = "inbox.stale-after-business-days"
    static let workingWeekdays = "inbox.working-weekdays"
    static let inboxDefaultSort = "inbox.default-sort"
    static let inboxSnoozeFirstMinutes = "inbox.snooze-first-minutes"
    static let inboxSnoozeSecondMinutes = "inbox.snooze-second-minutes"
    static let inboxSnoozeThirdMinutes = "inbox.snooze-third-minutes"
    static let appearanceDensity = "interface.appearance-density"
    static let refreshBehavior = "interface.refresh-behavior"
}

/// The default order for an unfiltered Inbox. Search-result ordering remains a
/// separate, query-specific presentation preference.
enum InboxDefaultSort: String, CaseIterable, Identifiable, Sendable {
    case attention
    case recentActivity

    var id: Self { self }

    var title: String {
        switch self {
        case .attention: "Attention"
        case .recentActivity: "Recent Activity"
        }
    }
}

enum InboxSnoozeSlot: CaseIterable, Identifiable, Sendable {
    case first
    case second
    case third

    var id: Self { self }

    var title: String {
        switch self {
        case .first: "First snooze duration"
        case .second: "Second snooze duration"
        case .third: "Third snooze duration"
        }
    }
}

/// Three local quick-snooze values, validated as a strictly increasing set so
/// every native menu remains predictable and never contains duplicate actions.
struct InboxSnoozeDurations: Equatable, Sendable {
    static let minimumMinutes = 5
    static let maximumMinutes = 43_200 // 30 days
    static let `default` = InboxSnoozeDurations(
        firstMinutes: 60,
        secondMinutes: 1_440,
        thirdMinutes: 10_080
    )!

    let firstMinutes: Int
    let secondMinutes: Int
    let thirdMinutes: Int

    init?(firstMinutes: Int, secondMinutes: Int, thirdMinutes: Int) {
        let values = [firstMinutes, secondMinutes, thirdMinutes]
        guard values.allSatisfy({ (Self.minimumMinutes...Self.maximumMinutes).contains($0) }),
              firstMinutes < secondMinutes,
              secondMinutes < thirdMinutes
        else { return nil }
        self.firstMinutes = firstMinutes
        self.secondMinutes = secondMinutes
        self.thirdMinutes = thirdMinutes
    }

    func minutes(for slot: InboxSnoozeSlot) -> Int {
        switch slot {
        case .first: firstMinutes
        case .second: secondMinutes
        case .third: thirdMinutes
        }
    }

    func replacing(_ slot: InboxSnoozeSlot, with minutes: Int) -> Self? {
        switch slot {
        case .first:
            Self(firstMinutes: minutes, secondMinutes: secondMinutes, thirdMinutes: thirdMinutes)
        case .second:
            Self(firstMinutes: firstMinutes, secondMinutes: minutes, thirdMinutes: thirdMinutes)
        case .third:
            Self(firstMinutes: firstMinutes, secondMinutes: secondMinutes, thirdMinutes: minutes)
        }
    }

    func title(for slot: InboxSnoozeSlot) -> String {
        "Snooze for \(Self.durationTitle(minutes(for: slot)))"
    }

    private static func durationTitle(_ minutes: Int) -> String {
        if minutes % 1_440 == 0 {
            let days = minutes / 1_440
            return "\(days) \(days == 1 ? "day" : "days")"
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        return "\(minutes) minutes"
    }
}

enum InterfaceAppearanceDensity: String, CaseIterable, Identifiable, Sendable {
    case standard
    case compact

    var id: Self { self }

    var title: String { self == .standard ? "Standard" : "Compact" }
}

enum RefreshBehavior: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case manual

    var id: Self { self }

    var title: String { self == .automatic ? "Automatic" : "Manual only" }
}

/// Thread-safe, local preference storage supplied to background derivation.
/// Invalid persisted values are ignored rather than weakening the native
/// Monday-Friday, three-business-day default.
final class BusinessDayPolicyPreferences: @unchecked Sendable {
    static let minimumStaleAfterBusinessDays = 1
    static let maximumStaleAfterBusinessDays = 365

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func policy() -> BusinessDayPolicy {
        lock.lock()
        defer { lock.unlock() }

        let threshold = defaults.object(forKey: TriagePreferenceKeys.staleAfterBusinessDays) as? Int
        let staleAfterBusinessDays = Self.isValid(threshold)
            ? threshold ?? BusinessDayPolicy().staleAfterBusinessDays
            : BusinessDayPolicy().staleAfterBusinessDays
        let rawWorkingDays = defaults.array(forKey: TriagePreferenceKeys.workingWeekdays) ?? []
        let workingDays = Set(rawWorkingDays.compactMap { value in
            (value as? Int).flatMap(WorkingWeekday.init(rawValue:))
        })
        return BusinessDayPolicy(
            workingDays: workingDays.isEmpty ? WorkingWeekday.defaultWorkweek : workingDays,
            staleAfterBusinessDays: staleAfterBusinessDays
        )
    }

    @discardableResult
    func save(_ policy: BusinessDayPolicy) -> Bool {
        guard Self.isValid(policy.staleAfterBusinessDays), !policy.workingDays.isEmpty else {
            return false
        }
        lock.lock()
        defaults.set(policy.staleAfterBusinessDays, forKey: TriagePreferenceKeys.staleAfterBusinessDays)
        defaults.set(policy.workingDays.map(\.rawValue).sorted(), forKey: TriagePreferenceKeys.workingWeekdays)
        lock.unlock()
        return true
    }

    private static func isValid(_ value: Int?) -> Bool {
        guard let value else { return false }
        return (minimumStaleAfterBusinessDays...maximumStaleAfterBusinessDays).contains(value)
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var showMenuBarExtra: Bool {
        didSet { defaults.set(showMenuBarExtra, forKey: TriagePreferenceKeys.showMenuBarExtra) }
    }
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var businessDayPolicy: BusinessDayPolicy
    @Published var inboxDefaultSort: InboxDefaultSort {
        didSet { defaults.set(inboxDefaultSort.rawValue, forKey: TriagePreferenceKeys.inboxDefaultSort) }
    }
    @Published private(set) var inboxSnoozeDurations: InboxSnoozeDurations
    @Published var appearanceDensity: InterfaceAppearanceDensity {
        didSet { defaults.set(appearanceDensity.rawValue, forKey: TriagePreferenceKeys.appearanceDensity) }
    }
    @Published var refreshBehavior: RefreshBehavior {
        didSet { defaults.set(refreshBehavior.rawValue, forKey: TriagePreferenceKeys.refreshBehavior) }
    }

    private let defaults: UserDefaults
    let businessDayPolicyPreferences: BusinessDayPolicyPreferences

    init(
        defaults: UserDefaults = .standard,
        businessDayPolicyPreferences: BusinessDayPolicyPreferences? = nil
    ) {
        self.defaults = defaults
        let businessDayPolicyPreferences = businessDayPolicyPreferences
            ?? BusinessDayPolicyPreferences(defaults: defaults)
        self.businessDayPolicyPreferences = businessDayPolicyPreferences
        showMenuBarExtra = defaults.object(forKey: TriagePreferenceKeys.showMenuBarExtra) as? Bool ?? true
        businessDayPolicy = businessDayPolicyPreferences.policy()
        inboxDefaultSort = defaults.string(forKey: TriagePreferenceKeys.inboxDefaultSort)
            .flatMap(InboxDefaultSort.init(rawValue:)) ?? .attention
        inboxSnoozeDurations = Self.loadInboxSnoozeDurations(from: defaults)
        appearanceDensity = defaults.string(forKey: TriagePreferenceKeys.appearanceDensity)
            .flatMap(InterfaceAppearanceDensity.init(rawValue:)) ?? .standard
        refreshBehavior = defaults.string(forKey: TriagePreferenceKeys.refreshBehavior)
            .flatMap(RefreshBehavior.init(rawValue:)) ?? .automatic
        refreshLaunchAtLoginStatus()
    }

    func setInboxSnoozeDuration(_ minutes: Int, for slot: InboxSnoozeSlot) {
        guard let updated = inboxSnoozeDurations.replacing(slot, with: minutes) else { return }
        inboxSnoozeDurations = updated
        defaults.set(updated.firstMinutes, forKey: TriagePreferenceKeys.inboxSnoozeFirstMinutes)
        defaults.set(updated.secondMinutes, forKey: TriagePreferenceKeys.inboxSnoozeSecondMinutes)
        defaults.set(updated.thirdMinutes, forKey: TriagePreferenceKeys.inboxSnoozeThirdMinutes)
    }

    func setStaleAfterBusinessDays(_ value: Int) {
        guard (BusinessDayPolicyPreferences.minimumStaleAfterBusinessDays...BusinessDayPolicyPreferences.maximumStaleAfterBusinessDays).contains(value) else {
            return
        }
        let updated = BusinessDayPolicy(
            workingDays: businessDayPolicy.workingDays,
            staleAfterBusinessDays: value
        )
        guard businessDayPolicyPreferences.save(updated) else { return }
        businessDayPolicy = updated
    }

    func setWorkingDay(_ weekday: WorkingWeekday, enabled: Bool) {
        var workingDays = businessDayPolicy.workingDays
        if enabled {
            workingDays.insert(weekday)
        } else {
            workingDays.remove(weekday)
        }
        guard !workingDays.isEmpty else { return }
        let updated = BusinessDayPolicy(
            workingDays: workingDays,
            staleAfterBusinessDays: businessDayPolicy.staleAfterBusinessDays
        )
        guard businessDayPolicyPreferences.save(updated) else { return }
        businessDayPolicy = updated
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            launchAtLoginError = error.localizedDescription
            refreshLaunchAtLoginStatus()
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private static func loadInboxSnoozeDurations(from defaults: UserDefaults) -> InboxSnoozeDurations {
        guard let first = defaults.object(forKey: TriagePreferenceKeys.inboxSnoozeFirstMinutes) as? Int,
              let second = defaults.object(forKey: TriagePreferenceKeys.inboxSnoozeSecondMinutes) as? Int,
              let third = defaults.object(forKey: TriagePreferenceKeys.inboxSnoozeThirdMinutes) as? Int,
              let durations = InboxSnoozeDurations(
                firstMinutes: first,
                secondMinutes: second,
                thirdMinutes: third
              )
        else { return .default }
        return durations
    }
}
