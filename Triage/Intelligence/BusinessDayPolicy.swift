import Foundation

enum WorkingWeekday: Int, CaseIterable, Codable, Sendable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    static let defaultWorkweek: Set<WorkingWeekday> = [
        .monday, .tuesday, .wednesday, .thursday, .friday
    ]

    var title: String {
        switch self {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }
}

struct BusinessDayPolicy: Codable, Equatable, Sendable {
    let workingDays: Set<WorkingWeekday>
    let staleAfterBusinessDays: Int

    init(
        workingDays: Set<WorkingWeekday> = WorkingWeekday.defaultWorkweek,
        staleAfterBusinessDays: Int = 3
    ) {
        precondition(!workingDays.isEmpty, "A business-day policy requires at least one working day.")
        precondition(staleAfterBusinessDays > 0, "A stale threshold must be positive.")
        self.workingDays = workingDays
        self.staleAfterBusinessDays = staleAfterBusinessDays
    }

    func staleAfter(
        latestProgressAt date: Date,
        calendar: Calendar
    ) -> Date {
        var current = date
        var remainingBusinessDays = staleAfterBusinessDays

        while remainingBusinessDays > 0 {
            current = calendar.date(byAdding: .day, value: 1, to: current)!
            let weekday = WorkingWeekday(rawValue: calendar.component(.weekday, from: current))!
            if workingDays.contains(weekday) {
                remainingBusinessDays -= 1
            }
        }
        return current
    }

    func isStale(
        latestProgressAt date: Date,
        at evaluationDate: Date,
        calendar: Calendar
    ) -> Bool {
        evaluationDate >= staleAfter(latestProgressAt: date, calendar: calendar)
    }
}
