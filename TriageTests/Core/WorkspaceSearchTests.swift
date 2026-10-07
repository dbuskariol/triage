import Foundation
import Testing
@testable import Triage

struct WorkspaceSearchTests {
    private func entry(
        _ id: String, title: String, repository: String = "octo/widgets", author: String = "alice",
        labels: [String] = [], reviewers: [String] = [], relationships: Set<WorkRelationship> = [.assigned],
        conflicts: Bool = false, disposition: TriageDisposition = .review, priority: Int = 50, nextAction: String? = nil
    ) -> TriageEntry {
        let item = PersonalWorkItem(
            id: GitHubNodeID(rawValue: id)!, kind: .pullRequest, repository: repository, number: 42, title: title,
            url: URL(string: "https://github.com/\(repository)/pull/42")!, state: .open, author: author,
            createdAt: .now, updatedAt: .now, relationships: relationships, labels: labels, assignees: [],
            body: "Body mentions caching layer.",
            pullRequest: PullRequestFacts(
                isDraft: false, reviewDecision: nil, requestedReviewers: reviewers, latestReviews: [],
                checks: nil, mergeable: conflicts ? "CONFLICTING" : "MERGEABLE",
                unresolvedReviewThreads: 0, additions: 0, deletions: 0
            ),
            recentActivity: []
        )
        let decision = TriageDecision(
            itemID: item.id, disposition: disposition, priority: priority, confidence: 0.8, summary: "s",
            reason: "r", nextAction: nextAction, fingerprint: item.fingerprint, modelID: "m", decidedAt: .now
        )
        return TriageEntry(item: item, decision: decision, analysis: .current, local: .active)
    }

    @Test func freeTextMatchesTitleBodyNumberAndCopilotText() {
        let work = entry("A", title: "Fix pagination", nextAction: "Rebase on main")
        func search(_ text: String) -> Bool { WorkspaceSearch(text: text).matches(work, viewer: "me") }
        #expect(search("pagination"))
        #expect(search("caching"))
        #expect(search("#42"))
        #expect(search("rebase"))
        #expect(search("PAGINATION fix"))
        #expect(!search("pagination unrelated"))
        #expect(search("\"caching layer\""))
    }

    @Test func qualifiersAndTokensFilterLikeGitHub() {
        let team = entry("T", title: "Team review", reviewers: ["octo/core"], relationships: [.reviewRequested], conflicts: true)
        let direct = entry("D", title: "Direct review", author: "bob", labels: ["security"],
                           reviewers: ["me"], relationships: [.reviewRequested], disposition: .act, priority: 90)
        func results(_ search: WorkspaceSearch) -> [String] {
            [team, direct].filter { search.matches($0, viewer: "me") }.map(\.id.rawValue)
        }
        #expect(results(WorkspaceSearch(text: "is:team")) == ["T"])
        #expect(results(WorkspaceSearch(text: "is:direct")) == ["D"])
        #expect(results(WorkspaceSearch(text: "status:conflicts")) == ["T"])
        #expect(results(WorkspaceSearch(text: "author:bob label:security")) == ["D"])
        #expect(results(WorkspaceSearch(text: "priority:high is:action")) == ["D"])
        #expect(results(WorkspaceSearch(text: "team:core")) == ["T"])
        #expect(results(WorkspaceSearch(text: "review", tokens: [SearchToken(kind: .repo, value: "widgets")])) == ["T", "D"])
        #expect(results(WorkspaceSearch(text: "unknown:thing review")).isEmpty)
    }

    @Test func suggestionsOfferMatchingValuesAndCommonFilters() {
        let entries = [entry("A", title: "a", repository: "octo/widgets", labels: ["security"])]
        #expect(!WorkspaceSearch(text: "").suggestions(from: entries).isEmpty)
        #expect(WorkspaceSearch(text: "wid").suggestions(from: entries).contains(SearchToken(kind: .repo, value: "widgets")))
        #expect(WorkspaceSearch(text: "label:sec").suggestions(from: entries) == [SearchToken(kind: .label, value: "security")])
        #expect(WorkspaceSearch(text: "status:").suggestions(from: entries).count == 4)
        #expect(WorkspaceSearch(text: "fix wid").textWithoutLastWord == "fix ")
    }
}

struct CopilotModelChoiceTests {
    @Test func validatesEffortAndContextTier() {
        #expect(CopilotModelChoice.isValidReasoningEffort(nil))
        #expect(CopilotModelChoice.isValidReasoningEffort("high"))
        #expect(CopilotModelChoice.isValidReasoningEffort("xhigh"))
        #expect(!CopilotModelChoice.isValidReasoningEffort("High"))
        #expect(!CopilotModelChoice.isValidReasoningEffort("very high"))
        #expect(CopilotModelChoice.isValidContextTier("long_context"))
        #expect(!CopilotModelChoice.isValidContextTier("huge"))
    }

    @Test func modelCapabilitiesDecodeFromTheHelperAndDefaultWhenAbsent() throws {
        let json = #"[{"id":"m","display_name":"M","is_default":false,"supported_reasoning_efforts":["low","high"],"default_reasoning_effort":"low","supports_long_context":true},{"id":"auto","display_name":"Auto","is_default":true}]"#
        let models = try JSONDecoder().decode([CopilotModel].self, from: Data(json.utf8))
        #expect(models[0].supportedReasoningEfforts == ["low", "high"])
        #expect(models[0].supportsLongContext == true)
        #expect(models[1].supportedReasoningEfforts == nil)
    }
}
