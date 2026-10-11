import Foundation
import Testing
@testable import Triage

struct SnoozeOptionTests {
    private let defaults: UserDefaults = {
        // Swift Testing runs tests in parallel; each instance gets its own suite.
        let defaults = UserDefaults(suiteName: "SnoozeOptionTests-\(UUID().uuidString)")!
        defaults.set(9, forKey: TriagePreferenceKeys.tomorrowHour)
        return defaults
    }()

    private func calendar(firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar().date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test(arguments: [
        (date: 8, hour: 19, expected: 12),  // Thursday → coming Monday
        (date: 11, hour: 20, expected: 12), // Sunday → tomorrow
        (date: 12, hour: 8, expected: 19),  // Monday before the snooze hour → next Monday
        (date: 12, hour: 15, expected: 19), // Monday afternoon → next Monday
        (date: 17, hour: 10, expected: 19), // Saturday → Monday
    ])
    func nextWeekIsTheNextMondayMorning(date day: Int, hour: Int, expected: Int) {
        for firstWeekday in [1, 2] {
            let snoozed = SnoozeOption.nextWeek.date(
                from: date(day, hour), defaults: defaults, calendar: calendar(firstWeekday: firstWeekday)
            )
            #expect(snoozed == date(expected, 9))
        }
    }

    @Test func dayCountsReturnInTheMorning() {
        let now = date(8, 19, 14)
        #expect(SnoozeOption.tomorrow.date(from: now, defaults: defaults, calendar: calendar()) == date(9, 9))
        #expect(SnoozeOption.inThreeDays.date(from: now, defaults: defaults, calendar: calendar()) == date(11, 9))
        #expect(SnoozeOption.inSevenDays.date(from: now, defaults: defaults, calendar: calendar()) == date(15, 9))
    }

    @Test func morningHourFollowsThePreference() {
        defaults.set(7, forKey: TriagePreferenceKeys.tomorrowHour)
        #expect(SnoozeOption.nextWeek.date(from: date(8, 19), defaults: defaults, calendar: calendar()) == date(12, 7))
    }

    @Test func subtitleShowsTheDateOnlyBeyondTheComingWeek() {
        let now = date(8, 19)
        let soon = SnoozeOption.tomorrow.subtitle(from: now, defaults: defaults, calendar: calendar())
        let later = SnoozeOption.inSevenDays.subtitle(from: now, defaults: defaults, calendar: calendar())
        #expect(!soon.contains("Oct"))
        #expect(later.contains("15"))
    }
}
