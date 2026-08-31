import XCTest
@testable import Triage

final class BusinessDayPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testDefaultPolicyCountsWeekdaysAndPreservesTimeOfDay() {
        let latestProgress = date(year: 2026, month: 8, day: 28, hour: 14)
        let due = BusinessDayPolicy().staleAfter(
            latestProgressAt: latestProgress,
            calendar: calendar
        )

        XCTAssertEqual(due, date(year: 2026, month: 9, day: 2, hour: 14))
    }

    func testStalenessBeginsAtTheThirdBusinessDayDeadline() {
        let latestProgress = date(year: 2026, month: 8, day: 28, hour: 14)
        let policy = BusinessDayPolicy()
        let due = date(year: 2026, month: 9, day: 2, hour: 14)

        XCTAssertFalse(
            policy.isStale(
                latestProgressAt: latestProgress,
                at: due.addingTimeInterval(-1),
                calendar: calendar
            )
        )
        XCTAssertTrue(
            policy.isStale(
                latestProgressAt: latestProgress,
                at: due,
                calendar: calendar
            )
        )
    }

    func testAlternateWeekendScheduleCountsSundayAndMonday() {
        let policy = BusinessDayPolicy(
            workingDays: [.sunday, .monday],
            staleAfterBusinessDays: 2
        )
        let latestProgress = date(year: 2026, month: 8, day: 28, hour: 14)

        XCTAssertEqual(
            policy.staleAfter(latestProgressAt: latestProgress, calendar: calendar),
            date(year: 2026, month: 8, day: 31, hour: 14)
        )
    }

    @MainActor
    func testPersistedPolicyRestoresAcrossPreferencesInstances() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.setStaleAfterBusinessDays(5)
        preferences.setWorkingDay(.friday, enabled: false)
        preferences.setWorkingDay(.sunday, enabled: true)

        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.businessDayPolicy.staleAfterBusinessDays, 5)
        XCTAssertEqual(restored.businessDayPolicy.workingDays, [.monday, .tuesday, .wednesday, .thursday, .sunday])
    }

    @MainActor
    func testInvalidPersistedValuesFallBackToNativeDefaultsAndCannotRemoveLastWorkingDay() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set(0, forKey: TriagePreferenceKeys.staleAfterBusinessDays)
        defaults.set([0, 8], forKey: TriagePreferenceKeys.workingWeekdays)

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.businessDayPolicy, BusinessDayPolicy())

        preferences.setStaleAfterBusinessDays(0)
        XCTAssertEqual(preferences.businessDayPolicy.staleAfterBusinessDays, 3)

        for weekday in WorkingWeekday.defaultWorkweek.dropFirst() {
            preferences.setWorkingDay(weekday, enabled: false)
        }
        preferences.setWorkingDay(.monday, enabled: false)
        XCTAssertEqual(preferences.businessDayPolicy.workingDays, [.monday])
    }

    func testProviderReadsPersistedPolicyForLiveRecomputation() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = BusinessDayPolicyPreferences(defaults: defaults)
        let provider: @Sendable () -> BusinessDayPolicy = { store.policy() }
        let latestProgress = date(year: 2026, month: 8, day: 28, hour: 14)
        let evaluatedAt = date(year: 2026, month: 9, day: 1, hour: 14)

        XCTAssertFalse(
            provider().isStale(
                latestProgressAt: latestProgress,
                at: evaluatedAt,
                calendar: calendar
            )
        )
        XCTAssertTrue(store.save(BusinessDayPolicy(staleAfterBusinessDays: 2)))
        XCTAssertTrue(
            provider().isStale(
                latestProgressAt: latestProgress,
                at: evaluatedAt,
                calendar: calendar
            )
        )
    }

    @MainActor
    func testInboxAndGeneralPreferencesPersistWithValidatedSnoozeDurations() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let preferences = AppPreferences(defaults: defaults)

        preferences.inboxDefaultSort = .recentActivity
        preferences.setInboxSnoozeDuration(30, for: .first)
        preferences.setInboxSnoozeDuration(180, for: .second)
        preferences.setInboxSnoozeDuration(1_440, for: .third)
        preferences.appearanceDensity = .compact
        preferences.refreshBehavior = .manual

        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.inboxDefaultSort, .recentActivity)
        XCTAssertEqual(
            restored.inboxSnoozeDurations,
            InboxSnoozeDurations(firstMinutes: 30, secondMinutes: 180, thirdMinutes: 1_440)
        )
        XCTAssertEqual(restored.appearanceDensity, .compact)
        XCTAssertEqual(restored.refreshBehavior, .manual)
    }

    @MainActor
    func testInvalidInboxAndGeneralPreferenceValuesFallBackToSafeDefaults() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set("unknown", forKey: TriagePreferenceKeys.inboxDefaultSort)
        defaults.set(60, forKey: TriagePreferenceKeys.inboxSnoozeFirstMinutes)
        defaults.set(60, forKey: TriagePreferenceKeys.inboxSnoozeSecondMinutes)
        defaults.set(30, forKey: TriagePreferenceKeys.inboxSnoozeThirdMinutes)
        defaults.set("dense-but-invalid", forKey: TriagePreferenceKeys.appearanceDensity)
        defaults.set("eventually", forKey: TriagePreferenceKeys.refreshBehavior)

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.inboxDefaultSort, .attention)
        XCTAssertEqual(preferences.inboxSnoozeDurations, .default)
        XCTAssertEqual(preferences.appearanceDensity, .standard)
        XCTAssertEqual(preferences.refreshBehavior, .automatic)

        preferences.setInboxSnoozeDuration(1_440, for: .first)
        XCTAssertEqual(preferences.inboxSnoozeDurations, .default)
    }

    private var defaultsSuiteName: String {
        "BusinessDayPolicyTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }

    private func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        )!
    }
}
