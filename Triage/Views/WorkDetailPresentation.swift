import Foundation

/// Pure presentation decisions for the work detail and inspector. Keeping
/// these labels and ordering rules out of the SwiftUI hierarchy makes it hard
/// for the UI to accidentally present partial or stale cache data as current.
enum WorkDetailPresentation {
    enum AccessibilityFocusTarget: String, CaseIterable, Sendable {
        case inspectorToggle
        case inspectorFirstWorkflowAction
    }

    static let detailSectionHeadings = [
        "Sync and coverage",
        "Why this is here",
        "Action items",
        "Related content",
        "Review state",
        "Project context",
        "Timeline",
        "Evidence and provenance"
    ]

    static let localWorkflowAccessibilityHint =
        "Changes only Triage’s encrypted local workflow; does not modify GitHub."

    static func inspectorFocusTarget(isPresented: Bool) -> AccessibilityFocusTarget {
        isPresented ? .inspectorFirstWorkflowAction : .inspectorToggle
    }

    static func inspectorIsAvailable(hasSelection: Bool) -> Bool {
        hasSelection
    }

    /// The inspector can supply an explicit follow-up date while the keyboard
    /// command keeps its existing immediate Waiting behavior. Archived work
    /// never exposes a waiting transition.
    static func waitingAction(
        for workflow: WorkflowState,
        followUpAt: Date? = nil
    ) -> WorkflowAction? {
        switch workflow.status {
        case .active:
            .markWaiting(followUpAt: followUpAt)
        case .waiting:
            .clearWaiting
        case .archived:
            nil
        }
    }

    static func defaultFollowUpDate(from date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: date)
            ?? date.addingTimeInterval(86_400)
    }

    static func sourceTitle(_ kind: GitHubContentKind) -> String {
        switch kind {
        case .issue: "Issue"
        case .pullRequest: "Pull Request"
        case .discussion: "Discussion"
        case .pullRequestReview: "Pull Request Review"
        case .pullRequestReviewThread: "Review Thread"
        case .pullRequestReviewComment: "Review Comment"
        case .issueComment: "Issue Comment"
        case .discussionComment: "Discussion Comment"
        case .discussionReply: "Discussion Reply"
        case .project: "Project"
        case .projectItem: "Project Item"
        case .projectDraftIssue: "Project Draft Issue"
        case .repository: "Repository"
        case .milestone: "Milestone"
        case .label: "Label"
        case .team: "Team"
        case .actor: "Account"
        case .commit: "Commit"
        case .statusCheck: "Status Check"
        case .timelineEvent: "Timeline Event"
        case .notificationThread: "Notification"
        }
    }

    static func freshnessTitle(_ freshness: FreshnessState) -> String {
        return switch freshness.status {
        case .fresh: "Current"
        case .refreshing: "Refreshing"
        case .stale: "Stale cache"
        case .partial: "Partial coverage"
        case .offline: "Offline cache"
        case .authenticationRequired: "Sign-in required"
        case .ssoRequired: "SSO authorization required"
        case .approvalRequired: "Organization approval required"
        case .rateLimited: "Rate limited"
        case .failed: "Refresh failed"
        }
    }

    static func freshnessDescription(_ freshness: FreshnessState) -> String {
        if let detail = freshness.detail, !detail.isEmpty {
            return detail
        }

        return switch freshness.status {
        case .fresh: "The displayed work is based on the latest successful local synchronization."
        case .refreshing: "Triage is updating this cached work."
        case .stale: "This cached work may no longer match GitHub."
        case .partial: "Some source coverage is incomplete; absence is not evidence of no activity."
        case .offline: "GitHub is unavailable; Triage is showing cached work only."
        case .authenticationRequired: "Reconnect this account before Triage can refresh the source."
        case .ssoRequired: "Authorize this account for the organization before Triage can refresh the source."
        case .approvalRequired: "Organization approval is required before all source data can refresh."
        case .rateLimited: "GitHub rate limits are delaying a refresh."
        case .failed: "Triage could not refresh this source. Existing cached work is retained."
        }
    }

    static func allEvidence(for item: WorkItem) -> [EvidenceReference] {
        let evidence = item.attentionReasons.flatMap(\.evidence)
            + item.relations.flatMap(\.evidence)
            + item.members.flatMap(\.evidence)
            + item.contextLinks.flatMap(\.evidence)

        var seen = Set<EvidenceID>()
        return evidence
            .sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
                return $0.id.rawValue < $1.id.rawValue
            }
            .filter { seen.insert($0.id).inserted }
    }

    static func availabilityTitle(for item: WorkItem) -> String {
        guard !allEvidence(for: item).isEmpty else {
            return "No normalized evidence is available"
        }
        return item.freshness.status == .fresh ? "Evidence is available" : "Evidence may be incomplete"
    }
}
