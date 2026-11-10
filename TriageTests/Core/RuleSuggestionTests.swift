import Foundation
import Testing
@testable import Triage

struct RuleSuggestionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, author: String = "dependabot[bot]", repository: String = "octo/widgets", signals: [String] = []) -> TriageEntry {
        let item = PersonalWorkItem(
            id: GitHubNodeID(rawValue: id)!, kind: .pullRequest, repository: repository, number: 1, title: "Bump \(id)",
            url: URL(string: "https://github.com/\(repository)/pull/1")!, state: .open, author: author,
            createdAt: now, updatedAt: now, relationships: [.reviewRequested], labels: [], assignees: [], body: "",
            pullRequest: PullRequestFacts(
                isDraft: false, reviewDecision: nil, requestedReviewers: ["octo/core"], latestReviews: [], checks: nil,
                mergeable: nil, unresolvedReviewThreads: 0, additions: 1, deletions: 1
            ),
            recentActivity: []
        )
        var decision = TriageDecision(
            itemID: item.id, disposition: .review, priority: 50, confidence: 0.9, summary: "s", reason: "r",
            nextAction: nil, fingerprint: item.fingerprint, modelID: "m", decidedAt: now
        )
        decision.signals = signals
        return TriageEntry(item: item, decision: decision, analysis: .current, local: .active)
    }

    private func events(_ kind: TriageFeedback.Kind, _ entries: [TriageEntry]) -> [TriageFeedback] {
        entries.map { .item(kind, $0, viewer: "me", at: now) }
    }

    @Test func consistentlyDismissedGroupsBecomeCandidates() throws {
        let bots = (1...6).map { entry("B\($0)") }
        let people = (1...6).map { entry("P\($0)", author: "alice") }
        var feedback = events(.doneUnopened, Array(bots.prefix(5))) + events(.opened, [bots[5]])
        feedback += events(.opened, people) + events(.doneUnopened, Array(people.prefix(2)))
        // An item opened and then dismissed counts once, as dismissed.
        feedback += events(.muted, [bots[5]])
        let candidates = RuleSuggestionMiner.candidates(from: feedback, rules: .empty)
        let keys = candidates.map(\.key)
        #expect(keys.contains("author:dependabot[bot]"))
        #expect(!keys.contains("author:alice"), "Only 2 of 6 dismissed.")
        #expect(!keys.contains("repo:octo/widgets"), "8 of 12 is below the threshold.")
        let bot = try #require(candidates.first { $0.key == "author:dependabot[bot]" })
        #expect(bot.items == 6)
        #expect(bot.dismissed == 6)
        #expect(bot.outcomes[.doneUnopened] == 5)
        #expect(!bot.isStrong)
        #expect(bot.evidence.contains("6 of 6"))
        #expect(bot.examples.count == 3)
    }

    @Test func coveredDismissedAndSmallGroupsAreSkipped() throws {
        let many = (1...12).map { entry("B\($0)", signals: ["bot-noise"]) }
        let feedback = events(.doneUnopened, many)
        let strong = RuleSuggestionMiner.candidates(from: feedback, rules: .empty)
        #expect(strong.first?.isStrong == true)
        let covering = TriageRules(instructions: "", rules: [TriageRule(query: try TriageQuery(parsing: "author:dependabot[bot] is:pr"), action: .exclude)])
        #expect(!RuleSuggestionMiner.candidates(from: feedback, rules: covering).map(\.key).contains("author:dependabot[bot]"))
        let dismissed = RuleSuggestionMiner.candidates(from: feedback, rules: .empty, dismissed: ["signal:bot-noise"])
        #expect(!dismissed.map(\.key).contains("signal:bot-noise"))
        #expect(RuleSuggestionMiner.candidates(from: events(.doneUnopened, Array(many.prefix(4))), rules: .empty).isEmpty)
    }

    @Test func suggestionsAreValidatedAndKeptWithinTheirGroup() throws {
        let entries = (1...6).map { entry("B\($0)") }
        let candidate = try #require(RuleSuggestionMiner.candidates(from: events(.doneUnopened, entries), rules: .empty)
            .first { $0.key == "author:dependabot[bot]" })
        func suggestion(_ query: String, _ action: String, id: String = "c1") -> CopilotRuleSuggestion {
            CopilotRuleSuggestion(candidateID: id, query: query, action: action, name: "Hide bot updates", rationale: "You never open them.")
        }
        let existing = TriageRules(instructions: "", rules: [TriageRule(query: try TriageQuery(parsing: "author:dependabot[bot] is:draft"), action: .exclude)])
        let validated = RuleSuggestion.validated([
            suggestion("author:dependabot[bot] -status:failing", "exclude"),
            suggestion("is:pr", "rank:lower:small"), // broader than the group: scoped back to it
            suggestion("author:dependabot[bot] is:draft", "exclude"), // duplicates a rule
            suggestion("stauts:x", "exclude"),
            suggestion("author:dependabot[bot]", "explode"),
            suggestion("author:dependabot[bot]", "exclude", id: "unknown"),
            suggestion("author:dependabot[bot] repo:elsewhere", "exclude"), // matches nothing now
        ], candidates: ["c1": candidate], rules: existing, entries: entries, viewer: "me")
        #expect(validated.map(\.rule.query.description) == ["author:dependabot[bot] -status:failing", "author:dependabot[bot] is:pr"])
        #expect(validated.map(\.rule.action) == [.exclude, .rank(.lower, .small)])
        #expect(validated.allSatisfy { $0.rule.origin == .suggestion })
    }

    @Test func suggesterSendsNumberedCandidatesExistingRulesAndTopics() async throws {
        let helper = SuggestingHelper()
        let suggester = CopilotRuleSuggester(
            makeHelper: { helper },
            authorize: { _ in CopilotTriageAuthorization(isConsentGranted: true, selectedModelID: nil) }
        )
        let candidates = RuleSuggestionMiner.candidates(from: events(.doneUnopened, (1...6).map { entry("B\($0)") }), rules: .empty)
        let rules = TriageRules(
            instructions: "", rules: [TriageRule(query: try TriageQuery(parsing: "is:draft"), action: .exclude)],
            topics: [TriageTopic(name: "Compliance", description: "Approval gates.")]
        )
        let scope = WorkspaceScope(accountID: AccountID(rawValue: "account")!, organizationID: OrganizationID(rawValue: "org")!, organizationLogin: "octo", viewerLogin: "me")
        let result = try await suggester.suggest(candidates, rules: rules, scope: scope)
        let request = try #require(await helper.lastRequest)
        #expect(request.candidates.map(\.id) == (1...candidates.count).map { "c\($0)" })
        #expect(request.candidates.first?.total == candidates.first?.items)
        #expect(request.existingRules == ["exclude: is:draft"])
        #expect(request.topics.map(\.name) == ["Compliance"])
        #expect(result.candidates["c1"]?.key == candidates.first?.key)
        #expect(throws: Never.self) { try request.validate() }
    }
}

private actor SuggestingHelper: TriageCopilotHelping {
    private(set) var lastRequest: CopilotSuggestRulesRequest?

    func health(_: CopilotHealthRequest) async throws -> CopilotHealthResponse { throw CancellationError() }
    func models(_: CopilotModelsRequest) async throws -> CopilotModelsResponse { throw CancellationError() }
    func cancel(_: CopilotCancelRequest) async throws -> CopilotCancelResponse { throw CancellationError() }
    func shutdown(_: CopilotShutdownRequest) async throws -> CopilotShutdownResponse { throw CancellationError() }

    func authenticate(_ request: CopilotAuthenticateRequest) async throws -> CopilotAuthenticationResponse {
        CopilotAuthenticationResponse(
            header: .init(requestID: request.header.requestID, accountID: request.header.accountID,
                          organizationID: request.header.organizationID, status: .authentication),
            authentication: .init(host: "github.com", login: "me", authenticationType: "token", isAuthenticated: true)
        )
    }

    func suggestRules(_ request: CopilotSuggestRulesRequest) async throws -> CopilotSuggestRulesResponse {
        lastRequest = request
        return CopilotSuggestRulesResponse(
            header: .init(requestID: request.header.requestID, accountID: request.header.accountID,
                          organizationID: request.header.organizationID, status: .suggestions),
            modelID: "auto", suggestions: []
        )
    }
}
