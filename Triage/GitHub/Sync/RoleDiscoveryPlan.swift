import Foundation

enum RoleDiscoveryStreamKind: String, CaseIterable, Sendable {
    case openInvolvement = "open-involvement"
    case openAuthored = "open-authored"
    case openAssigned = "open-assigned"
    case openDirectMentions = "open-direct-mentions"
    case openCommenterInvolvement = "open-commenter-involvement"
    case openReviewRequested = "open-review-requested"
    case openReviewInvolvement = "open-review-involvement"
    case openTeamReviewRequested = "open-team-review-requested"
    case recentClosedInvolvement = "recent-closed-involvement"
    case recentMergedReviewInvolvement = "recent-merged-review-involvement"
    case recentClosedAuthored = "recent-closed-authored"
}

struct RoleDiscoveryStream: Sendable {
    let kind: RoleDiscoveryStreamKind
    let queries: [GitHubIssueSearchQuery]

    func streamID(parent: SyncStreamID) -> SyncStreamID {
        SyncStreamID(rawValue: "\(parent.rawValue)-\(kind.rawValue)")!
    }
}

struct RoleDiscoveryPlan: Sendable {
    let streams: [RoleDiscoveryStream]

    init(
        organizationLogin: String,
        userLogin: String,
        teams: [TeamInventorySummary] = [],
        now: Date,
        calendar: Calendar = Calendar(identifier: .iso8601)
    ) throws {
        let openRelationships: [(RoleDiscoveryStreamKind, GitHubIssueSearchRelationship)] = [
            (.openInvolvement, .involves),
            (.openAuthored, .authored),
            (.openAssigned, .assigned),
            (.openDirectMentions, .mentioned),
            (.openCommenterInvolvement, .commented),
            (.openReviewRequested, .reviewRequested),
            (.openReviewInvolvement, .reviewInvolves)
        ]
        var plannedStreams = try openRelationships.map { kind, relationship in
            RoleDiscoveryStream(
                kind: kind,
                queries: [try GitHubIssueSearchQuery(
                    organizationLogin: organizationLogin,
                    userLogin: userLogin,
                    state: .open,
                    relationship: relationship
                )]
            )
        }
        let activeTeams = teams
            .filter { $0.membershipState == "active" }
            .sorted { lhs, rhs in
                if lhs.slug == rhs.slug { return lhs.nodeID.rawValue < rhs.nodeID.rawValue }
                return lhs.slug < rhs.slug
            }
        plannedStreams.append(
            RoleDiscoveryStream(
                kind: .openTeamReviewRequested,
                queries: try activeTeams.map { team in
                    try GitHubIssueSearchQuery(
                        organizationLogin: organizationLogin,
                        userLogin: userLogin,
                        state: .open,
                        relationship: .teamReviewRequested(
                            teamNodeID: team.nodeID,
                            teamSlug: team.slug
                        )
                    )
                }
            )
        )
        let recentStart = calendar.date(byAdding: .day, value: -90, to: now)!
        let recentStreams: [(RoleDiscoveryStreamKind, GitHubIssueSearchState, GitHubIssueSearchRelationship)] = [
            (.recentClosedInvolvement, .closed, .involves),
            (.recentMergedReviewInvolvement, .merged, .reviewInvolves),
            (.recentClosedAuthored, .closed, .authored)
        ]
        plannedStreams.append(contentsOf: try recentStreams.map { kind, state, relationship in
            RoleDiscoveryStream(
                kind: kind,
                queries: [try GitHubIssueSearchQuery(
                    organizationLogin: organizationLogin,
                    userLogin: userLogin,
                    state: state,
                    relationship: relationship,
                    closedAfter: recentStart
                )]
            )
        })
        streams = plannedStreams
    }
}
