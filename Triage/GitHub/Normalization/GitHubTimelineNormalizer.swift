import Foundation

enum GitHubTimelineNormalizer {
    static func kind(for event: String?) -> TimelineEventKind {
        switch event {
        case "assigned": .assigned
        case "unassigned": .unassigned
        case "commented": .commented
        case "reviewed": .reviewed
        case "review_requested": .reviewRequested
        case "review_request_removed": .reviewRequestRemoved
        case "review_dismissed": .reviewDismissed
        case "labeled": .labeled
        case "unlabeled": .unlabeled
        case "cross-referenced": .crossReferenced
        case "committed": .committed
        case "closed": .closed
        case "reopened": .reopened
        case "merged": .merged
        case "transferred": .transferred
        case "added_to_project": .addedToProject
        case "removed_from_project": .removedFromProject
        case "milestoned", "demilestoned": .milestoneChanged
        case "renamed": .renamed
        default: .unknown
        }
    }
}
