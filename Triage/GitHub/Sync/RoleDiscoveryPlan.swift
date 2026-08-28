import Foundation

struct RoleDiscoveryPlan: Sendable {
    let openQueries: [GitHubIssueSearchQuery]
    let recentClosedQueries: [GitHubIssueSearchQuery]

    init(
        organizationLogin: String,
        userLogin: String,
        now: Date,
        calendar: Calendar = Calendar(identifier: .iso8601)
    ) throws {
        let relationships: [GitHubIssueSearchRelationship] = [
            .involves, .authored, .assigned, .mentioned, .commented, .reviewRequested, .reviewInvolves
        ]
        openQueries = try relationships.map {
            try GitHubIssueSearchQuery(
                organizationLogin: organizationLogin,
                userLogin: userLogin,
                state: .open,
                relationship: $0
            )
        }
        let recentStart = calendar.date(byAdding: .day, value: -90, to: now)!
        recentClosedQueries = try relationships.map {
            try GitHubIssueSearchQuery(
                organizationLogin: organizationLogin,
                userLogin: userLogin,
                state: .closed,
                relationship: $0,
                closedAfter: recentStart
            )
        }
    }
}
