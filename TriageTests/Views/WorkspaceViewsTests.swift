import Foundation
import Testing
@testable import Triage

struct WorkspaceViewsTests {
    @Test func decisionLabelsUseProductThresholds() {
        #expect(WorkspaceViewPresentation.priorityLabel(70) == "High")
        #expect(WorkspaceViewPresentation.priorityLabel(40) == "Medium")
        #expect(WorkspaceViewPresentation.priorityLabel(39) == "Low")
        #expect(WorkspaceViewPresentation.confidenceLabel(0.8) == "High")
        #expect(WorkspaceViewPresentation.confidenceLabel(0.5) == "Medium")
        #expect(WorkspaceViewPresentation.confidenceLabel(0.49) == "Low")
        #expect(WorkspaceViewPresentation.dispositionLabel(.act) == "Needs your action")
    }

    @Test func statusLineDescribesCurrentWork() {
        #expect(
            WorkspaceViewPresentation.statusLine(
                TriageStatus(phase: .searching(found: 42), problem: nil, lastRefreshAt: nil, nextRefreshAt: nil)
            ) == "Searching GitHub · 42 found"
        )
        #expect(
            WorkspaceViewPresentation.statusLine(
                TriageStatus(phase: .analyzing(completed: 12, total: 40), problem: nil, lastRefreshAt: nil, nextRefreshAt: nil)
            ) == "Copilot is prioritizing · 12 of 40"
        )
    }

    @Test func rowBadgesSurfaceOnlyImportantPullRequestFacts() {
        let entry = TriageEntry(
            item: PersonalWorkItem(
                id: GitHubNodeID(rawValue: "PR_1")!,
                kind: .pullRequest,
                repository: "org/repo",
                number: 1,
                title: "Title",
                url: URL(string: "https://github.com/org/repo/pull/1")!,
                state: .open,
                author: nil,
                createdAt: .now,
                updatedAt: .now,
                relationships: [.reviewRequested],
                labels: [],
                assignees: [],
                body: "",
                pullRequest: PullRequestFacts(
                    isDraft: true,
                    reviewDecision: .changesRequested,
                    requestedReviewers: [],
                    latestReviews: [],
                    checks: .failure,
                    mergeable: "CONFLICTING",
                    unresolvedReviewThreads: 0,
                    additions: 0,
                    deletions: 0
                ),
                recentActivity: []
            ),
            decision: nil,
            analysis: .pending,
            local: .active
        )

        #expect(
            WorkspaceViewPresentation.badges(for: entry)
                == ["Checks failing", "Changes requested", "Conflicts", "Draft"]
        )
    }
}

struct WorkspaceSortTests {
    @Test func sortFieldsOrderTheSelectedSection() {
        let presentation = WorkspacePresentation(entries: [
            sortEntry("a", title: "beta", repository: "org/zeta", priority: 50, updated: 3),
            sortEntry("b", title: "Alpha", repository: "org/alpha", priority: 90, updated: 1),
            sortEntry("c", title: "gamma", repository: "org/mid", priority: 70, updated: 2),
        ], status: .initial, now: .now)
        func ids(_ field: WorkspaceSortField, _ ascending: Bool) -> [String] {
            presentation.entries(in: .inbox, sortedBy: field, ascending: ascending).map(\.id.rawValue)
        }
        #expect(ids(.recommended, true) == ["b", "c", "a"])
        #expect(ids(.priority, false) == ["b", "c", "a"])
        #expect(ids(.priority, true) == ["a", "c", "b"])
        #expect(ids(.updated, false) == ["a", "c", "b"])
        #expect(ids(.title, true) == ["b", "a", "c"])
        #expect(ids(.repository, true) == ["b", "c", "a"])
        #expect(WorkspaceSortField.title.defaultAscending)
        #expect(!WorkspaceSortField.updated.defaultAscending)
    }
}

private func sortEntry(_ id: String, title: String, repository: String, priority: Int, updated: TimeInterval) -> TriageEntry {
    let item = PersonalWorkItem(
        id: GitHubNodeID(rawValue: id)!, kind: .issue, repository: repository, number: 1, title: title,
        url: URL(string: "https://github.com/\(repository)/issues/1")!, state: .open, author: nil,
        createdAt: Date(timeIntervalSince1970: updated), updatedAt: Date(timeIntervalSince1970: updated),
        relationships: [.assigned], labels: [], assignees: [], body: "", pullRequest: nil, recentActivity: []
    )
    let decision = TriageDecision(
        itemID: item.id, disposition: .review, priority: priority, confidence: 0.8,
        summary: "Summary", reason: "Reason", nextAction: nil, fingerprint: item.fingerprint,
        modelID: "test", decidedAt: .now
    )
    return TriageEntry(item: item, decision: decision, analysis: .current, local: .active)
}

struct MarkdownBlockTests {
    @Test func parsesGitHubStructure() {
        let blocks = MarkdownBlock.parse("""
        ## Summary
        Support agreed on **Urgent**.
        Second line.

        - one
          continued
        - [x] done
        1. first

        > quoted

        | Run | Result |
        |-----|:------:|
        | A   | 93%    |

        ```
        go test ./...
        ```
        ---
        """)
        #expect(blocks == [
            .heading(level: 2, text: "Summary"),
            .paragraph("Support agreed on **Urgent**.\nSecond line."),
            .list([
                .init(marker: .bullet, text: "one continued", depth: 0),
                .init(marker: .task(true), text: "done", depth: 0),
                .init(marker: .number(1), text: "first", depth: 0),
            ]),
            .quote("quoted"),
            .table([["Run", "Result"], ["A", "93%"]]),
            .code("go test ./..."),
            .rule,
        ])
    }
}
