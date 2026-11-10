import Foundation
import Testing
@testable import Triage

private func rule(_ action: TriageRuleAction, _ query: String, enabled: Bool = true) -> TriageRule {
    TriageRule(isEnabled: enabled, query: try! TriageQuery(parsing: query), action: action)
}

private func entry(_ item: PersonalWorkItem, _ decision: TriageDecision?) -> TriageEntry {
    TriageEntry(item: item, decision: decision, analysis: decision == nil ? .pending : .current, local: .active)
}

struct TriageRulesTests {
    @Test func precedenceIsExcludeThenFirstRouteThenCappedRank() {
        let item = rulesItem()
        let rules = TriageRules(instructions: "", rules: [
            rule(.route(.needsAction), "repo:octo/widgets"),
            rule(.route(.noAction), "author:dependabot[bot]"), // later route loses
            rule(.rank(.higher, .large), "label:security"),
            rule(.rank(.higher, .medium), "is:pr"), // 35 + 20 is capped at 40
        ])
        let applied = rules.apply(to: entry(item, decision(item, .none, priority: 30)), viewer: "me")
        #expect(applied.decision?.disposition == .act)
        #expect(applied.decision?.priority == 70)
        #expect(applied.appliedRules.count == 4)
        #expect(!applied.isExcluded)

        let hidden = TriageRules(instructions: "", rules: [rule(.route(.inbox), "is:pr"), rule(.exclude, "author:dependabot[bot]")])
            .apply(to: entry(item, decision(item, .act, priority: 90)), viewer: "me")
        #expect(hidden.isExcluded)
        #expect(hidden.excludedBy == "Hide: author:dependabot[bot]")
    }

    @Test func moveToInboxNeverDowngradesNeedsAction() {
        let item = rulesItem()
        let rules = TriageRules(instructions: "", rules: [rule(.route(.inbox), "label:security")])
        #expect(rules.apply(to: entry(item, decision(item, .act, priority: 90)), viewer: "me").decision?.disposition == .act)
        #expect(rules.apply(to: entry(item, decision(item, .none, priority: 10)), viewer: "me").decision?.disposition == .review)
    }

    @Test func factExclusionsSkipCopilotAndAIExclusionsWaitForADecision() {
        let item = rulesItem()
        let facts = TriageRules(instructions: "", rules: [rule(.exclude, "author:dependabot[bot]")])
        #expect(facts.isExcludedBeforeAnalysis(item, viewer: "me"))
        let presentation = WorkspacePresentation(entries: [entry(item, nil)], status: .initial, now: .now, rules: facts)
        #expect(presentation.count(in: .excluded) == 1)
        #expect(presentation.count(in: .analyzing) == 0)

        let ai = TriageRules(instructions: "", rules: [rule(.exclude, "-in:inbox")])
        #expect(!ai.isExcludedBeforeAnalysis(item, viewer: "me"))
        #expect(!ai.apply(to: entry(item, nil), viewer: "me").isExcluded)
        #expect(ai.apply(to: entry(item, decision(item, .wait, priority: 20)), viewer: "me").isExcluded)
        #expect(!ai.apply(to: entry(item, decision(item, .act, priority: 90)), viewer: "me").isExcluded)
    }

    @Test func perItemDigestChangesOnlyWithWhatCopilotSees() throws {
        let item = rulesItem()
        let other = rulesItem(repository: "octo/other", author: "alice", labels: [])
        #expect(TriageRules.empty.digest(for: item, viewer: "me") == TriageRules.promptVersion)
        // Hide, Rank, disabled, and Copilot-output rules never re-analyze.
        let quiet = TriageRules(instructions: "  ", rules: [
            rule(.exclude, "author:bot"), rule(.rank(.lower, .small), "is:pr"),
            rule(.route(.waiting), "is:pr", enabled: false), rule(.route(.waiting), "priority:low"),
        ])
        #expect(quiet.digest(for: item, viewer: "me") == TriageRules.promptVersion)
        // A fact Route rule changes only the items it matches.
        let routed = TriageRules(instructions: "", rules: [rule(.route(.needsAction), "repo:widgets")])
        #expect(routed.digest(for: item, viewer: "me") != TriageRules.promptVersion)
        #expect(routed.digest(for: other, viewer: "me") == TriageRules.promptVersion)
        let instructions = TriageRules(instructions: "Security first.", rules: [])
        #expect(instructions.digest(for: other, viewer: "me") != TriageRules(instructions: "Docs first.", rules: []).digest(for: other, viewer: "me"))
        #expect(throws: TriageRulesError.instructionsTooLong) {
            try TriageRules(instructions: String(repeating: "a", count: 2_001), rules: []).validated()
        }
    }

    @Test func hintsDescribeFactRoutesOnly() {
        let rules = TriageRules(instructions: "", rules: [
            rule(.route(.needsAction), "repo:widgets"), rule(.exclude, "is:draft"), rule(.route(.waiting), "effort:deep"),
        ])
        let hints = rules.hints(for: rulesItem(), viewer: "me")
        #expect(hints.count == 1)
        #expect(hints[0].contains("needing their action"))
    }

    @Test func conflictsNameTheWinningRoute() {
        let first = rule(.route(.needsAction), "repo:widgets")
        let second = rule(.route(.waiting), "label:security")
        let third = rule(.route(.needsAction), "is:pr")
        let rules = TriageRules(instructions: "", rules: [first, second, third])
        let conflicts = rules.conflicts(in: [entry(rulesItem(), nil)], viewer: "me")
        #expect(conflicts.map(\.winner.id) == [first.id, second.id])
        #expect(conflicts.map(\.loser.id) == [second.id, third.id])
    }

    @Test func actionsRoundTripAsStrings() throws {
        for action in TriageRuleAction.all {
            #expect(TriageRuleAction(storageValue: action.storageValue) == action)
        }
        #expect(TriageRuleAction(storageValue: "rank:sideways:big") == nil)
        let saved = TriageRules(instructions: "x", rules: [rule(.rank(.lower, .small), "repo:a/* -label:b")])
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(TriageRules.self, from: data) == saved)
    }

    @Test func legacyRulesMigrateLosslessly() throws {
        let json = #"""
        { "instructions": "", "rules": [
          { "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Bots", "isEnabled": true,
            "conditions": [{ "field": "author", "value": "dependabot[bot]" }, { "field": "pullRequestStatus", "value": "checksFailing" }],
            "effect": "mute" },
          { "name": "", "isEnabled": false,
            "conditions": [{ "field": "relationship", "value": "reviewRequestedTeam" }, { "field": "inactiveDays", "value": "14" }],
            "effect": "lowerPriority" },
          { "name": "", "conditions": [{ "field": "pullRequestStatus", "value": "ready" }, { "field": "repository", "value": "octo/*" }], "effect": "alwaysInbox" },
          { "name": "", "conditions": [{ "field": "kind", "value": "issue" }, { "field": "titleContains", "value": "release train" }], "effect": "needsAction" },
          { "name": "", "conditions": [{ "field": "relationship", "value": "commented" }], "effect": "noAction" },
          { "name": "", "conditions": [{ "field": "author", "value": "  " }], "effect": "mute" },
          { "name": "", "conditions": [{ "field": "label", "value": "x" }], "effect": "somethingNew" }
        ] }
        """#
        let rules = try JSONDecoder().decode(TriageRules.self, from: Data(json.utf8))
        #expect(rules.rules.map(\.query.description) == [
            "author:dependabot[bot] status:failing",
            "is:team updated:>=14d",
            "is:pr -is:draft repo:octo/*",
            "is:issue title:\"release train\"",
            "is:commented",
        ])
        #expect(rules.rules.map(\.action) == [.exclude, .rank(.lower, .medium), .route(.inbox), .route(.needsAction), .route(.noAction)])
        #expect(rules.rules[0].id == UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        #expect(rules.rules[0].name == "Bots")
        #expect(!rules.rules[1].isEnabled)
    }

    @Test func suggestionsStartFromTheItem() {
        var item = rulesItem()
        item = item.replacingPullRequest({
            var facts = item.pullRequest!
            facts.checkRuns = [CheckRunFact(name: "deploy-gate", result: .failing)]
            return facts
        }())
        var decided = decision(item, .act, priority: 80)
        decided.signals = ["approval-gate"]
        let work = TriageEntry(item: item, decision: decided, analysis: .current, local: .active)
        let tokens = TriageRule.suggestedTokens(for: work, viewer: "me").map(\.title)
        #expect(tokens.prefix(3) == ["is:assigned", "signal:approval-gate", "check:deploy-gate:failing"])
        #expect(tokens.contains("repo:octo/widgets"))
        #expect(tokens.contains("author:dependabot[bot]"))
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
        var currentPrompt = current
        currentPrompt.decision?.rulesDigest = TriageRules.promptVersion
        #expect(WorkspacePresentation(entries: [currentPrompt], status: .initial, now: .now).count(in: .analyzing) == 0)
    }
}

struct HandledDetectionTests {
    private func item(comments: [ActivityFact], reviews: [ReviewFact] = []) -> PersonalWorkItem {
        PersonalWorkItem(
            id: GitHubNodeID(rawValue: "PR_handled")!, kind: .pullRequest, repository: "octo/repo", number: 9,
            title: "t", url: URL(string: "https://github.com/octo/repo/pull/9")!, state: .open, author: "alice",
            createdAt: .distantPast, updatedAt: .now, relationships: [.reviewRequested], labels: [], assignees: [],
            body: "",
            pullRequest: PullRequestFacts(
                isDraft: false, reviewDecision: nil, requestedReviewers: [], latestReviews: reviews, checks: nil,
                mergeable: nil, unresolvedReviewThreads: 0, additions: 0, deletions: 0
            ),
            recentActivity: comments
        )
    }

    @Test func yourOwnActivityNeverBringsDoneWorkBackButOthersDoes() {
        let doneAt = Date(timeIntervalSinceNow: -600)
        let mine = item(comments: [ActivityFact(author: "Me", createdAt: .now, excerpt: "fixed")])
        let entry = TriageEntry(item: mine, decision: nil, analysis: .current,
                                local: .done(fingerprint: "x", at: doneAt))
        #expect(!entry.isVisible(at: .now, viewer: "me"))

        let others = item(comments: [ActivityFact(author: "bob", createdAt: .now, excerpt: "one more thing")])
        let returned = TriageEntry(item: others, decision: nil, analysis: .current,
                                   local: .done(fingerprint: "x", at: doneAt))
        #expect(returned.isVisible(at: .now, viewer: "me"))
    }

    @Test func viewerActivityListsOnlyYourRecentActions() {
        let since = Date(timeIntervalSinceNow: -600)
        let work = item(
            comments: [
                ActivityFact(author: "me", createdAt: .now, excerpt: "Rebased and fixed the test"),
                ActivityFact(author: "me", createdAt: .distantPast, excerpt: "old"),
                ActivityFact(author: "bob", createdAt: .now, excerpt: "thanks"),
            ],
            reviews: [ReviewFact(author: "me", state: "APPROVED", submittedAt: .now)]
        )
        let activity = work.viewerActivity(since: since, viewer: "me")
        #expect(activity.count == 2)
        #expect(activity[0].contains("Rebased and fixed the test"))
        #expect(activity[1].contains("approved review"))
        #expect(work.latestActivity(excluding: "me") != nil)
    }
}
