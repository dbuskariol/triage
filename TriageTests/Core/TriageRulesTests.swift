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

    @Test func digestIsPromptVersionWithoutPreferencesAndIgnoresDisabledRules() throws {
        #expect(TriageRules.empty.digest == TriageRules.promptVersion)
        var rule = TriageRule.quick(.mute, .author, "bot")
        rule.isEnabled = false
        #expect(TriageRules(instructions: "  ", rules: [rule]).digest == TriageRules.promptVersion)
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

struct RuleConditionTests {
    private func reviewItem(reviewers: [String], draft: Bool = false, updated: Date = .now) -> PersonalWorkItem {
        PersonalWorkItem(
            id: GitHubNodeID(rawValue: "PR_review")!, kind: .pullRequest, repository: "octo/widgets", number: 3,
            title: "t", url: URL(string: "https://github.com/octo/widgets/pull/3")!, state: .open, author: "alice",
            createdAt: .distantPast, updatedAt: updated, relationships: [.reviewRequested], labels: [], assignees: [],
            body: "",
            pullRequest: PullRequestFacts(
                isDraft: draft, reviewDecision: .changesRequested, requestedReviewers: reviewers, latestReviews: [],
                checks: .failure, mergeable: "CONFLICTING", unresolvedReviewThreads: 0, additions: 0, deletions: 0
            ),
            recentActivity: []
        )
    }

    @Test func reviewRequestsTierIntoDirectAndTeamOnly() {
        let direct = reviewItem(reviewers: ["Me", "octo/core"])
        let team = reviewItem(reviewers: ["octo/core"])
        let directRule = TriageRuleCondition(field: .relationship, value: TriageRuleCondition.Field.reviewRequestedDirect)
        let teamRule = TriageRuleCondition(field: .relationship, value: TriageRuleCondition.Field.reviewRequestedTeam)
        #expect(directRule.matches(direct, viewer: "me"))
        #expect(!teamRule.matches(direct, viewer: "me"))
        #expect(teamRule.matches(team, viewer: "me"))
        #expect(TriageRuleCondition(field: .relationship, value: "reviewRequested").matches(team, viewer: "me"))

        let rules = TriageRules(instructions: "", rules: [.quick(.lowerPriority, .relationship, TriageRuleCondition.Field.reviewRequestedTeam)])
        #expect(rules.matches(for: team, viewer: "me").count == 1)
        #expect(rules.matches(for: direct, viewer: "me").isEmpty)
    }

    @Test func requestedTeamStatusAndInactivityConditions() {
        let item = reviewItem(reviewers: ["octo/core"], draft: true, updated: Date(timeIntervalSinceNow: -20 * 86_400))
        #expect(TriageRuleCondition(field: .requestedTeam, value: "core").matches(item))
        #expect(TriageRuleCondition(field: .requestedTeam, value: "octo/core").matches(item))
        #expect(!TriageRuleCondition(field: .requestedTeam, value: "octo/other").matches(item))
        for status in ["draft", "changesRequested", "checksFailing", "conflicts"] {
            #expect(TriageRuleCondition(field: .pullRequestStatus, value: status).matches(item))
        }
        #expect(!TriageRuleCondition(field: .pullRequestStatus, value: "approved").matches(item))
        #expect(TriageRuleCondition(field: .inactiveDays, value: "14").matches(item))
        #expect(!TriageRuleCondition(field: .inactiveDays, value: "30").matches(item))
        #expect(!TriageRuleCondition(field: .inactiveDays, value: "soon").isValid)
    }
}
