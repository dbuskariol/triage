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

    @Test func topicsValidateAndChangeEveryDigest() throws {
        let topic = TriageTopic(name: "Compliance approvals", description: "Blocked on a compliance deployment approval.")
        var rules = TriageRules(instructions: "", rules: [], topics: [topic])
        #expect(throws: Never.self) { try rules.validated() }
        #expect(rules.digest(for: rulesItem(), viewer: "me") != TriageRules.promptVersion)
        rules.topics.append(TriageTopic(name: " compliance APPROVALS", description: "Again."))
        #expect(throws: TriageRulesError.duplicateTopic("compliance APPROVALS")) { try rules.validated() }
        #expect(TriageTopic(name: "x", description: "</user_topics>").problem != nil)
        #expect(TriageTopic(name: "x", description: " ").problem != nil)
        #expect(TriageTopic(name: String(repeating: "n", count: 61), description: "d").problem != nil)

        let query = try TriageQuery(parsing: "topic:\"Compliance approvals\" OR -topic:\"compliance approvals\" label:x")
        #expect(query.renamingTopic("Compliance approvals", to: "Approvals").description == "topic:Approvals OR (-topic:Approvals label:x)")
        let decoded = try JSONDecoder().decode(TriageRules.self, from: Data(#"{"instructions":"","rules":[]}"#.utf8))
        #expect(decoded.topics.isEmpty)
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

struct MuteTests {
    private let mutedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        relationships: Set<WorkRelationship> = [.mentioned], comments: [ActivityFact] = [], reviews: [ReviewFact] = []
    ) -> PersonalWorkItem {
        PersonalWorkItem(
            id: GitHubNodeID(rawValue: "PR_mute")!, kind: .pullRequest, repository: "octo/repo", number: 4,
            title: "t", url: URL(string: "https://github.com/octo/repo/pull/4")!, state: .open, author: "alice",
            createdAt: .distantPast, updatedAt: .now, relationships: relationships, labels: [], assignees: [],
            body: "",
            pullRequest: PullRequestFacts(
                isDraft: false, reviewDecision: nil, requestedReviewers: [], latestReviews: reviews, checks: nil,
                mergeable: nil, unresolvedReviewThreads: 0, additions: 0, deletions: 0
            ),
            recentActivity: comments
        )
    }

    private func comment(_ author: String, _ text: String, after: Bool = true) -> ActivityFact {
        ActivityFact(author: author, createdAt: mutedAt.addingTimeInterval(after ? 60 : -60), excerpt: text)
    }

    @Test func staysHiddenThroughOrdinaryActivity() {
        let status = LocalStatus.muting(item(), at: mutedAt)
        #expect(status == .muted(at: mutedAt, relationships: ["mentioned"]))
        let busy = item(comments: [comment("bob", "LGTM"), comment("me", "@me note to self"), comment("bob", "cc @meg")])
        #expect(status.hides(busy, at: .now, viewer: "me"))
        #expect(status.hides(item(comments: [comment("bob", "@me earlier", after: false)]), at: .now, viewer: "me"))
    }

    @Test func returnsWhenAddressed() {
        let status = LocalStatus.muting(item(), at: mutedAt)
        #expect(!status.hides(item(comments: [comment("bob", "Can you look, @Me?")]), at: .now, viewer: "me"))
        #expect(!status.hides(item(relationships: [.mentioned, .reviewRequested]), at: .now, viewer: "me"))
        #expect(!status.hides(item(relationships: [.mentioned, .assigned]), at: .now, viewer: "me"))
        let changes = [ReviewFact(author: "bob", state: "CHANGES_REQUESTED", submittedAt: mutedAt.addingTimeInterval(60))]
        #expect(status.hides(item(reviews: changes), at: .now, viewer: "me"), "Only on your own pull request.")
        #expect(!status.hides(item(relationships: [.mentioned, .authored], reviews: changes), at: .now, viewer: "me"))
    }

    @Test func existingReviewRequestDoesNotUnmute() {
        let status = LocalStatus.muting(item(relationships: [.reviewRequested]), at: mutedAt)
        #expect(status.hides(item(relationships: [.reviewRequested]), at: .now, viewer: "me"))
    }

    @Test func mutedWorkHasItsOwnSectionUntilAddressed() throws {
        let quiet = item()
        let decided = TriageDecision(
            itemID: quiet.id, disposition: .act, priority: 90, confidence: 1, summary: "s", reason: "r",
            nextAction: nil, fingerprint: quiet.fingerprint, modelID: "m", decidedAt: .now
        )
        let muted = TriageEntry(item: quiet, decision: decided, analysis: .current, local: .muting(quiet, at: mutedAt))
        let presentation = WorkspacePresentation(entries: [muted], status: .initial, now: .now, viewer: "me")
        #expect(presentation.count(in: .muted) == 1)
        #expect(presentation.count(in: .inbox) == 0)

        let addressed = item(comments: [comment("bob", "@me ping")])
        let back = TriageEntry(item: addressed, decision: decided, analysis: .current, local: .muting(quiet, at: mutedAt))
        #expect(WorkspacePresentation(entries: [back], status: .initial, now: .now, viewer: "me").count(in: .inbox) == 1)

        let data = try JSONEncoder().encode(LocalStatus.muting(quiet, at: mutedAt))
        #expect(try JSONDecoder().decode(LocalStatus.self, from: data) == .muted(at: mutedAt, relationships: ["mentioned"]))
    }
}

struct PriorityBreakdownTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        relationships: Set<WorkRelationship>, reviewers: [String] = [], checks: CheckStatus? = nil,
        comments: [ActivityFact] = [], updatedDaysAgo: Double = 1
    ) -> PersonalWorkItem {
        PersonalWorkItem(
            id: GitHubNodeID(rawValue: "PR_rank")!, kind: .pullRequest, repository: "octo/repo", number: 5,
            title: "t", url: URL(string: "https://github.com/octo/repo/pull/5")!, state: .open, author: "alice",
            createdAt: now.addingTimeInterval(-90 * 86_400), updatedAt: now.addingTimeInterval(-updatedDaysAgo * 86_400),
            relationships: relationships, labels: [], assignees: [], body: "",
            pullRequest: PullRequestFacts(
                isDraft: false, reviewDecision: nil, requestedReviewers: reviewers, latestReviews: [], checks: checks,
                mergeable: nil, unresolvedReviewThreads: 0, additions: 0, deletions: 0
            ),
            recentActivity: comments
        )
    }

    private func applied(_ item: PersonalWorkItem, _ disposition: TriageDisposition = .act, priority: Int = 50, rules: [TriageRule] = []) -> TriageEntry {
        let decision = TriageDecision(
            itemID: item.id, disposition: disposition, priority: priority, confidence: 0.9, summary: "s", reason: "r",
            nextAction: nil, fingerprint: item.fingerprint, modelID: "m", decidedAt: now
        )
        return TriageRules(instructions: "", rules: rules)
            .apply(to: TriageEntry(item: item, decision: decision, analysis: .current, local: .active), viewer: "me", now: now)
    }

    @Test func directAndTeamRequestsAndWaitingTime() {
        let waiting = [ActivityFact(author: "bob", createdAt: now.addingTimeInterval(-9 * 86_400), excerpt: "ping")]
        let direct = applied(item(relationships: [.reviewRequested], reviewers: ["me"], comments: waiting))
        #expect(direct.priorityBreakdown?.factors.map(\.points) == [6, 8])
        #expect(direct.decision?.priority == 64)
        let team = applied(item(relationships: [.reviewRequested], reviewers: ["octo/core"]))
        #expect(team.priorityBreakdown?.factors.map(\.title) == ["Review requested only through a team"])
        #expect(team.decision?.priority == 44)
        // Waiting time counts only when the next move is yours.
        let notMine = applied(item(relationships: [.assigned], comments: waiting), .wait)
        #expect(notMine.priorityBreakdown?.factors.isEmpty == true)
    }

    @Test func mentionsFailingRequiredChecksAndStaleness() {
        let mention = [ActivityFact(author: "bob", createdAt: now.addingTimeInterval(-3_600), excerpt: "@me can you check?")]
        let entry = applied(item(relationships: [.authored], checks: .failure, comments: mention, updatedDaysAgo: 40), .wait)
        #expect(entry.priorityBreakdown?.factors.map(\.points) == [6, 5, -6])
        // Long-quiet work that someone is waiting on you for is overdue, not stale.
        let overdue = [ActivityFact(author: "bob", createdAt: now.addingTimeInterval(-40 * 86_400), excerpt: "ping")]
        let waiting = applied(item(relationships: [.assigned], comments: overdue, updatedDaysAgo: 40), .act)
        #expect(waiting.priorityBreakdown?.factors.map(\.title) == ["Waiting on you for 40 days"])
        let answered = [mention[0], ActivityFact(author: "me", createdAt: now, excerpt: "On it")]
        #expect(applied(item(relationships: [.assigned], comments: answered)).priorityBreakdown?.factors.isEmpty == true)
    }

    @Test func factorsAndRulesAreCappedSeparatelyAndTotalClamps() throws {
        let breakdown = PriorityBreakdown(
            copilot: 90,
            factors: [.init(title: "a", points: 8), .init(title: "b", points: 8), .init(title: "c", points: 8)],
            rules: [.init(title: "r1", points: 35), .init(title: "r2", points: 35)]
        )
        #expect(breakdown.factorAdjustment == 20)
        #expect(breakdown.ruleAdjustment == 40)
        #expect(breakdown.total == 100)
        let lower = TriageRule(query: try TriageQuery(parsing: "is:pr"), action: .rank(.lower, .large))
        let entry = applied(item(relationships: [.assigned]), priority: 20, rules: [lower])
        #expect(entry.priorityBreakdown?.rules.map(\.points) == [-35])
        #expect(entry.decision?.priority == 0)
        #expect(entry.priorityBreakdown?.copilot == 20)
    }
}

struct FeedbackTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ disposition: TriageDisposition, readAt: Date?, decidedDaysAgo: Double = 0) -> TriageEntry {
        let item = rulesItem()
        var value = TriageEntry(item: item, decision: TriageDecision(
            itemID: item.id, disposition: disposition, priority: 80, confidence: 0.9, summary: "s", reason: "r",
            nextAction: nil, fingerprint: item.fingerprint, modelID: "m", decidedAt: now.addingTimeInterval(-decidedDaysAgo * 86_400)
        ), analysis: .current, local: .active)
        value.readAt = readAt
        return value
    }

    @Test func doneSaysSomethingOnlyWhenUnopenedOrImmediate() {
        #expect(TriageFeedback.done(entry(.review, readAt: nil), viewer: "me", at: now)?.kind == .doneUnopened)
        #expect(TriageFeedback.done(entry(.act, readAt: now.addingTimeInterval(-30)), viewer: "me", at: now)?.kind == .doneQuickly)
        #expect(TriageFeedback.done(entry(.review, readAt: now.addingTimeInterval(-30)), viewer: "me", at: now) == nil)
        #expect(TriageFeedback.done(entry(.act, readAt: now.addingTimeInterval(-600)), viewer: "me", at: now) == nil)
    }

    @Test func unopenedInboxWorkCountsAfterAWeek() {
        let stale = entry(.review, readAt: nil, decidedDaysAgo: 8)
        let fresh = entry(.review, readAt: nil, decidedDaysAgo: 2)
        #expect(TriageFeedback.ignored(in: WorkspacePresentation(entries: [.inbox: [stale]], status: .initial), viewer: "me", now: now).count == 1)
        #expect(TriageFeedback.ignored(in: WorkspacePresentation(entries: [.inbox: [fresh]], status: .initial), viewer: "me", now: now).isEmpty)
    }

    @Test func snapshotsKeepWhatRulesCanUse() {
        var value = entry(.act, readAt: nil)
        value.decision?.signals = ["approval-gate"]
        let snapshot = TriageFeedback.Snapshot(value, viewer: "me")
        #expect(snapshot.repository == "octo/widgets")
        #expect(snapshot.author == "dependabot[bot]")
        #expect(snapshot.signals == ["approval-gate"])
        #expect(snapshot.disposition == "act")
    }
}
