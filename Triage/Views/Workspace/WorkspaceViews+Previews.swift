import SwiftUI

@MainActor
private final class WorkspacePreviewActions: WorkspaceActions {
    func refreshNow() {}
    func markDone(_ entry: TriageEntry) {}
    func snooze(_ entry: TriageEntry, until date: Date) {}
    func restore(_ entry: TriageEntry) {}
    func openOnGitHub(_ entry: TriageEntry) {}
    func openCopilotSettings() {}
    func addRule(_ rule: TriageRule) {}
    func openRulesSettings() {}
}

private enum WorkspacePreviewFixture {
    static let entry = TriageEntry(
        item: PersonalWorkItem(
            id: GitHubNodeID(rawValue: "PR_preview")!,
            kind: .pullRequest,
            repository: "octo-org/triage",
            number: 42,
            title: "Keep the inbox focused on work that needs you",
            url: URL(string: "https://github.com/octo-org/triage/pull/42")!,
            state: .open,
            author: "octocat",
            createdAt: .now.addingTimeInterval(-86_400),
            updatedAt: .now.addingTimeInterval(-720),
            relationships: [.reviewRequested],
            labels: ["design"],
            assignees: ["octocat"],
            body: "",
            pullRequest: PullRequestFacts(
                isDraft: false,
                reviewDecision: .changesRequested,
                requestedReviewers: ["you"],
                latestReviews: [ReviewFact(author: "octocat", state: "CHANGES_REQUESTED", submittedAt: .now)],
                checks: .failure,
                mergeable: "CONFLICTING",
                unresolvedReviewThreads: 2,
                additions: 84,
                deletions: 20
            ),
            recentActivity: [
                ActivityFact(author: "octocat", createdAt: .now.addingTimeInterval(-720), excerpt: "Could you take another look at the new flow?")
            ]
        ),
        decision: TriageDecision(
            itemID: GitHubNodeID(rawValue: "PR_preview")!,
            disposition: .act,
            priority: 82,
            confidence: 0.91,
            summary: "The author needs your review before this can move forward.",
            reason: "Changes were requested and the checks are failing.",
            nextAction: "Review the latest changes and respond to the author.",
            fingerprint: "preview",
            modelID: "preview",
            decidedAt: .now
        ),
        analysis: .current,
        local: .active
    )

    static let presentation = WorkspacePresentation(
        entries: [.inbox: [entry]],
        status: TriageStatus(phase: .idle, problem: nil, lastRefreshAt: .now.addingTimeInterval(-120), nextRefreshAt: nil)
    )
}

#Preview("Workspace list") {
    @Previewable @State var selection: GitHubNodeID? = WorkspacePreviewFixture.entry.id
    TriageListView(
        presentation: WorkspacePreviewFixture.presentation,
        section: .inbox,
        selectedEntryID: $selection,
        actions: WorkspacePreviewActions()
    )
    .frame(width: 600, height: 500)
}

#Preview("Workspace detail") {
    TriageDetailView(
        entry: WorkspacePreviewFixture.entry,
        inboxIsEmpty: false,
        actions: WorkspacePreviewActions()
    )
    .frame(width: 450, height: 650)
}

#Preview("Workspace sidebar") {
    @Previewable @State var section = WorkspacePresentation.Section.inbox
    WorkspaceSidebarView(
        presentation: WorkspacePreviewFixture.presentation,
        selection: $section
    )
    .frame(width: 260, height: 500)
}
