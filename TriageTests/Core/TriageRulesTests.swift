import Foundation
import Testing
@testable import Triage

struct TriageRulesTests {
    @Test func conditionsMatchCaseInsensitivelyWithRepositoryShortNamesAndWildcards() {
        let item = rulesItem(repository: "octo/widgets", author: "Dependabot[bot]", labels: ["Security"], draft: true)
        #expect(TriageRuleCondition(field: .repository, value: "Octo/Widgets").matches(item))
        #expect(TriageRuleCondition(field: .repository, value: "widgets").matches(item))
        #expect(TriageRuleCondition(field: .repository, value: "octo/*").matches(item))
        #expect(!TriageRuleCondition(field: .repository, value: "other/*").matches(item))
        #expect(TriageRuleCondition(field: .author, value: "dependabot[bot]").matches(item))
        #expect(TriageRuleCondition(field: .label, value: "security").matches(item))
        #expect(TriageRuleCondition(field: .kind, value: "draftPullRequest").matches(item))
        #expect(TriageRuleCondition(field: .relationship, value: "assigned").matches(item))
        #expect(TriageRuleCondition(field: .titleContains, value: "BUMP").matches(item))
        #expect(!TriageRuleCondition(field: .author, value: "  ").matches(item))
    }

    @Test func hardRulesOverrideCopilotAndAreAttributed() {
        let item = rulesItem()
        let entry = TriageEntry(item: item, decision: decision(item, .none, priority: 30), analysis: .current, local: .active)
        let rules = TriageRules(instructions: "", rules: [
            .quick(.needsAction, .repository, "octo/widgets"),
            .quick(.noAction, .author, "dependabot[bot]"), // later disposition rule loses
            .quick(.raisePriority, .label, "security"),
        ])
        let applied = rules.apply(to: entry)
        #expect(applied.decision?.disposition == .act)
        #expect(applied.decision?.priority == 55)
        #expect(applied.appliedRules.count == 3)
        #expect(!applied.isMuted)
    }

    @Test func alwaysInboxNeverDowngradesActionAndMuteHidesWithoutAnalysis() {
        let item = rulesItem()
        let acting = TriageEntry(item: item, decision: decision(item, .act, priority: 90), analysis: .current, local: .active)
        #expect(TriageRules(instructions: "", rules: [.quick(.alwaysInbox, .label, "security")]).apply(to: acting).decision?.disposition == .act)

        let muted = TriageRules(instructions: "", rules: [.quick(.mute, .author, "dependabot[bot]")])
        #expect(muted.isMuted(item))
        let presentation = WorkspacePresentation(
            entries: [TriageEntry(item: item, decision: nil, analysis: .pending, local: .active)],
            status: .initial, now: .now, rules: muted
        )
        #expect(presentation.count(in: .muted) == 1)
        #expect(presentation.count(in: .analyzing) == 0)
    }

    @Test func digestIsEmptyWithoutPreferencesAndIgnoresDisabledRules() throws {
        #expect(TriageRules.empty.digest == "")
        var rule = TriageRule.quick(.mute, .author, "bot")
        rule.isEnabled = false
        #expect(TriageRules(instructions: "  ", rules: [rule]).digest == "")
        let withInstructions = TriageRules(instructions: "Security first.", rules: [])
        #expect(!withInstructions.digest.isEmpty)
        #expect(withInstructions.digest != TriageRules(instructions: "Docs first.", rules: []).digest)
        #expect(throws: TriageRulesError.instructionsTooLong) {
            try TriageRules(instructions: String(repeating: "a", count: 2_001), rules: []).validated()
        }
        #expect(throws: TriageRulesError.invalidRule) {
            try TriageRules(instructions: "", rules: [.quick(.mute, .author, "")]).validated()
        }
    }

    @Test func hintsDescribeEnforcedOutcomes() {
        let hints = TriageRules(instructions: "", rules: [.quick(.needsAction, .repository, "widgets")]).hints(for: rulesItem())
        #expect(hints.count == 1)
        #expect(hints[0].contains("needing their action"))
    }
}

private func rulesItem(
    repository: String = "octo/widgets", author: String = "dependabot[bot]",
    labels: [String] = ["security"], draft: Bool = false
) -> PersonalWorkItem {
    PersonalWorkItem(
        id: GitHubNodeID(rawValue: "PR_rules")!, kind: .pullRequest, repository: repository, number: 7,
        title: "Bump dependency", url: URL(string: "https://github.com/\(repository)/pull/7")!, state: .open,
        author: author, createdAt: .now, updatedAt: .now, relationships: [.assigned], labels: labels,
        assignees: [], body: "",
        pullRequest: PullRequestFacts(
            isDraft: draft, reviewDecision: nil, requestedReviewers: [], latestReviews: [], checks: nil,
            mergeable: nil, unresolvedReviewThreads: 0, additions: 0, deletions: 0
        ),
        recentActivity: []
    )
}

private func decision(_ item: PersonalWorkItem, _ disposition: TriageDisposition, priority: Int) -> TriageDecision {
    TriageDecision(
        itemID: item.id, disposition: disposition, priority: priority, confidence: 0.8, summary: "s",
        reason: "r", nextAction: nil, fingerprint: item.fingerprint, modelID: "m", decidedAt: .now
    )
}

struct AnalyzingQueueTests {
    @Test func analyzingListsNewRecheckedAndRetryingWorkWhileDecidedItemsStayPut() {
        let item = rulesItem()
        let stale = TriageEntry(item: item, decision: decision(item, .act, priority: 80), analysis: .pending, local: .active)
        let presentation = WorkspacePresentation(entries: [stale], status: .initial, now: .now)
        #expect(presentation.count(in: .inbox) == 1)
        #expect(presentation.count(in: .analyzing) == 1)
        #expect(presentation.allEntries.count == 1)

        // A decision made under older preferences is queued too.
        let current = TriageEntry(item: item, decision: decision(item, .act, priority: 80), analysis: .current, local: .active)
        let withInstructions = WorkspacePresentation(
            entries: [current], status: .initial, now: .now,
            rules: TriageRules(instructions: "Security first.", rules: [])
        )
        #expect(withInstructions.count(in: .analyzing) == 1)
        #expect(WorkspacePresentation(entries: [current], status: .initial, now: .now).count(in: .analyzing) == 0)
    }
}
