import Foundation
import Testing
@testable import Triage

struct SnoozeOptionTests {
    private let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "SnoozeOptionTests")!
        defaults.removePersistentDomain(forName: "SnoozeOptionTests")
        defaults.set(9, forKey: TriagePreferenceKeys.tomorrowHour)
        return defaults
    }()

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        calendar.locale = Locale(identifier: "en_AU")
        return calendar
    }

    @Test func nextWeekFromThursdayIsComingMondayNotSameWeekday() {
        let now = date(2026, 10, 8, 19, 14)
        let snoozed = SnoozeOption.nextWeek.date(from: now, defaults: defaults, calendar: calendar)
        #expect(snoozed == date(2026, 10, 12, 9, 0))
        #expect(calendar.component(.weekday, from: snoozed) == 2)
    }

    @Test func nextWeekFromMondayMorningIsNextMondayNotLaterToday() {
        let now = date(2026, 10, 12, 8, 0)
        let snoozed = SnoozeOption.nextWeek.date(from: now, defaults: defaults, calendar: calendar)
        #expect(snoozed == date(2026, 10, 19, 9, 0))
    }

    @Test func nextWeekFromMondayAfternoonIsNextMonday() {
        let now = date(2026, 10, 12, 15, 0)
        let snoozed = SnoozeOption.nextWeek.date(from: now, defaults: defaults, calendar: calendar)
        #expect(snoozed == date(2026, 10, 19, 9, 0))
    }

    @Test func nextWeekFromSundayIsTomorrowMonday() {
        let now = date(2026, 10, 11, 20, 0)
        let snoozed = SnoozeOption.nextWeek.date(from: now, defaults: defaults, calendar: calendar)
        #expect(snoozed == date(2026, 10, 12, 9, 0))
    }

    @Test func tomorrowIsStillTheNextMorning() {
        let now = date(2026, 10, 8, 19, 14)
        let snoozed = SnoozeOption.tomorrow.date(from: now, defaults: defaults, calendar: calendar)
        #expect(snoozed == date(2026, 10, 9, 9, 0))
    }

    @Test func inSevenDaysKeepsTheSameWeekday() {
        let now = date(2026, 10, 8, 19, 14)
        let snoozed = SnoozeOption.inSevenDays.date(from: now, defaults: defaults, calendar: calendar)
        #expect(snoozed == date(2026, 10, 15, 9, 0))
        #expect(calendar.component(.weekday, from: snoozed) == calendar.component(.weekday, from: now))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }
}
