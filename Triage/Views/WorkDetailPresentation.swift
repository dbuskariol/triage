import Foundation

/// Pure presentation decisions for the work detail and inspector. Keeping
/// these labels and ordering rules out of the SwiftUI hierarchy makes it hard
/// for the UI to accidentally present partial or stale cache data as current.
enum WorkDetailPresentation {
    static let timelinePageSize = 20
    static let maximumConciseSourceBodyCharacters = 12_000

    enum AccessibilityFocusTarget: String, CaseIterable, Sendable {
        case inspectorToggle
        case inspectorFirstWorkflowAction
    }

    static let detailSectionHeadings = [
        "Source",
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

    static let localGroupingAccessibilityHint =
        "Saves only Triage’s encrypted local grouping decision; does not modify GitHub."

    static func inspectorFocusTarget(isPresented: Bool) -> AccessibilityFocusTarget {
        isPresented ? .inspectorFirstWorkflowAction : .inspectorToggle
    }

    static func inspectorIsAvailable(hasSelection: Bool) -> Bool {
        hasSelection
    }

    static func groupingCandidates(for item: WorkItem) -> [GroupingCandidate] {
        item.contextLinks.map {
            GroupingCandidate(
                destinationNodeID: $0.id,
                relation: $0.relation,
                title: $0.content.title
            )
        }
        .sorted {
            ($0.title.localizedStandardCompare($1.title) == .orderedAscending)
                || ($0.title == $1.title && $0.destinationNodeID.rawValue < $1.destinationNodeID.rawValue)
        }
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

    /// The detail owns only normalized, already-cached content. These groups
    /// make that graph legible without inventing a relationship or fetching
    /// additional GitHub data.
    static func relatedContentGroups(for item: WorkItem) -> [RelatedContentGroup] {
        var groups = [(title: String, contents: [GitHubContentSummary])]()
        for role in relatedRoles {
            let contents = item.members
                .filter { $0.id != item.primaryNodeID && $0.role == role }
                .map(\.content)
            if !contents.isEmpty {
                groups.append((relatedTitle(for: role), contents))
            }
        }

        let contextGroups = Dictionary(
            grouping: item.contextLinks,
            by: { relatedTitle(for: $0.relation) }
        )
        for title in contextGroups.keys.sorted() {
            guard let links = contextGroups[title] else { continue }
            groups.append((title, links.map(\.content)))
        }

        var seen = Set<GitHubNodeID>()
        return groups.compactMap { group in
            let contents = group.contents
                .filter { seen.insert($0.id).inserted }
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            guard !contents.isEmpty else { return nil }
            return RelatedContentGroup(title: group.title, contents: contents)
        }
    }

    static func actorNames(for item: WorkItem) -> [String] {
        var seen = Set<ActorID>()
        return item.members.compactMap(\.content.author).compactMap { actor in
            guard seen.insert(actor.id).inserted else { return nil }
            return actor.displayName ?? actor.login
        }
    }

    static func labelTitles(for item: WorkItem) -> [String] {
        var seen = Set<GitHubNodeID>()
        return item.members
            .filter { $0.content.kind == .label }
            .map(\.content)
            .filter { seen.insert($0.id).inserted }
            .map(\.title)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func timelinePage(for item: WorkItem, visibleCount: Int) -> [EvidenceReference] {
        Array(allEvidence(for: item).prefix(max(0, visibleCount)))
    }

    static func conciseSourceBody(_ source: String) -> ConciseSourceBody? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maximumConciseSourceBodyCharacters else {
            return ConciseSourceBody(markdown: trimmed, isTruncated: false)
        }
        let prefix = String(trimmed.prefix(maximumConciseSourceBodyCharacters))
        let boundary = prefix.lastIndex(of: "\n") ?? prefix.endIndex
        return ConciseSourceBody(
            markdown: String(prefix[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines),
            isTruncated: true
        )
    }

    static func nextTimelineVisibleCount(current: Int, total: Int) -> Int {
        min(max(0, current) + timelinePageSize, total)
    }

    static func timelineTitle(for event: TimelineEventSummary) -> String {
        if let body = event.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            return body
        }
        return event.kind.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    static func timelineAccessibilityLabel(for event: TimelineEventSummary) -> String {
        let actor = event.actor.map { $0.displayName ?? $0.login }
        let parts = [
            actor,
            timelineTitle(for: event),
            event.occurredAt.formatted(date: .abbreviated, time: .shortened)
        ].compactMap { $0 }
        return parts.joined(separator: ", ")
    }

    static func reviewStateSummaries(for item: WorkItem) -> [String] {
        let relations = Set(item.relations.map(\.kind.rawValue))
        var summaries = [String]()
        if relations.contains(WorkRelationKind.changesRequested.rawValue) {
            summaries.append("Changes requested")
        }
        if relations.contains(WorkRelationKind.reviewed.rawValue) {
            summaries.append("Review submitted")
        }
        if relations.contains(WorkRelationKind.reviewRequestedDirectly.rawValue) {
            summaries.append("Your review requested")
        }
        if relations.contains(WorkRelationKind.reviewRequestedFromTeam.rawValue) {
            summaries.append("Team review requested")
        }
        if item.members.contains(where: { $0.role == .reviewThread }) {
            summaries.append("Review threads available")
        }
        return summaries
    }

    static func availabilityTitle(for item: WorkItem) -> String {
        guard !allEvidence(for: item).isEmpty else {
            return "No normalized evidence is available"
        }
        return item.freshness.status == .fresh ? "Evidence is available" : "Evidence may be incomplete"
    }

    private static func relatedTitle(for role: WorkItemMemberRole) -> String {
        switch role {
        case .primary: "Related source"
        case .closingPullRequest: "Closing pull requests"
        case .linkedIssue: "Linked issues"
        case .review: "Pull request reviews"
        case .reviewThread: "Review threads"
        case .comment: "Comments"
        case .projectItem: "Project items"
        case .discussion: "Discussions"
        }
    }

    private static let relatedRoles: [WorkItemMemberRole] = [
        .closingPullRequest,
        .linkedIssue,
        .review,
        .reviewThread,
        .comment,
        .projectItem,
        .discussion
    ]

    private static func relatedTitle(for relation: WorkRelationKind) -> String {
        switch relation {
        case .projectContext, .projectWrapsContent: "Project context"
        case .linkedPullRequest: "Linked pull requests"
        case .crossReferences: "Cross-references"
        case .blocks, .blockedBy: "Dependencies"
        case .parentOf, .childOf: "Hierarchy"
        case .closes, .closedBy: "Closing relationships"
        case .duplicateOf: "Duplicates"
        default: "Related content"
        }
    }
}

struct GroupingCandidate: Equatable, Identifiable, Sendable {
    let destinationNodeID: GitHubNodeID
    let relation: WorkRelationKind
    let title: String

    var id: String { "\(destinationNodeID.rawValue)\u{0}\(relation.rawValue)" }
}

struct ConciseSourceBody: Equatable, Sendable {
    let markdown: String
    let isTruncated: Bool
}

struct RelatedContentGroup: Equatable, Identifiable {
    let title: String
    let contents: [GitHubContentSummary]

    var id: String { title }
}
