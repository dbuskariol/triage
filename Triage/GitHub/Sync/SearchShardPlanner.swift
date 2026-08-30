import Foundation

struct SearchTimeRange: Equatable, Sendable {
    let start: Date
    let end: Date

    init(start: Date, end: Date) {
        precondition(start < end, "A search range must have a positive duration.")
        self.start = start
        self.end = end
    }

    var midpoint: Date {
        start.addingTimeInterval(end.timeIntervalSince(start) / 2)
    }
}

enum SearchShardPlan: Equatable, Sendable {
    case complete(SearchTimeRange)
    case split(SearchTimeRange, SearchTimeRange)
    case repositoryPartitionRequired(SearchTimeRange)
}

struct SearchShardPlanner: Sendable {
    static let maximumResults = 1_000
    static let minimumRangeDuration: TimeInterval = 60

    func nextPlan(
        range: SearchTimeRange,
        totalCount: Int,
        incompleteResults: Bool
    ) -> SearchShardPlan {
        guard incompleteResults || totalCount >= Self.maximumResults else {
            return .complete(range)
        }
        guard range.end.timeIntervalSince(range.start) > Self.minimumRangeDuration else {
            return .repositoryPartitionRequired(range)
        }

        let midpoint = range.midpoint
        return .split(
            SearchTimeRange(start: range.start, end: midpoint),
            SearchTimeRange(start: midpoint, end: range.end)
        )
    }
}
