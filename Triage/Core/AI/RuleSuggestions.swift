import Foundation

/// A group of similar work the user keeps handling the same way, found
/// locally and deterministically in their feedback.
struct RuleSuggestionCandidate: Equatable, Sendable {
    /// The filter that selects the group; also its identity for dismissal.
    let query: TriageQuery
    /// Distinct items the user handled in this group.
    let items: Int
    /// Of those, items they dismissed (done unopened, muted, Not right?, …).
    let dismissed: Int
    let outcomes: [TriageFeedback.Kind: Int]
    let examples: [TriageFeedback.Snapshot]

    var key: String { query.description }
    var consistency: Double { items == 0 ? 0 : Double(dismissed) / Double(items) }
    var isStrong: Bool { items >= RuleSuggestionMiner.strongItems && consistency >= RuleSuggestionMiner.strongConsistency }

    /// One plain sentence of evidence, e.g. "You dismissed 11 of 12 items
    /// matching author:dependabot[bot], 9 without opening them."
    var evidence: String {
        let top = outcomes.filter { $0.key.isDismissive }.max { $0.value < $1.value }
        let detail = top.map { ", \($0.value) by \(Self.phrase($0.key))" } ?? ""
        return "You set aside \(dismissed) of \(items) items matching \(key) in the last 90 days\(detail)."
    }

    private static func phrase(_ kind: TriageFeedback.Kind) -> String {
        switch kind {
        case .notRight: "saying Not right?"
        case .doneUnopened: "marking them done without opening them"
        case .doneQuickly: "marking them done right after opening them"
        case .muted: "muting them"
        case .ignoredInInbox: "leaving them unopened for a week"
        case .snoozed: "snoozing them"
        case .opened: "opening them"
        case .ruleCreated, .ruleDeleted: "changing rules"
        }
    }
}

/// Finds rule candidates in feedback. Pure, deterministic, and local.
enum RuleSuggestionMiner {
    static let minimumItems = 5
    static let minimumConsistency = 0.8
    static let strongItems = 10
    static let strongConsistency = 0.9
    static let maximumCandidates = 20

    static func candidates(
        from events: [TriageFeedback], rules: TriageRules, dismissed: Set<String> = []
    ) -> [RuleSuggestionCandidate] {
        // One verdict per item: dismissed if any dismissive outcome, otherwise
        // engaged if opened or snoozed. Latest facts describe the item.
        struct Item { var snapshot: TriageFeedback.Snapshot; var dismissed = false; var outcomes: [TriageFeedback.Kind] = [] }
        var items: [GitHubNodeID: Item] = [:]
        for event in events {
            guard let id = event.itemID, let snapshot = event.snapshot else { continue }
            var item = items[id] ?? Item(snapshot: snapshot)
            item.snapshot = snapshot
            item.dismissed = item.dismissed || event.kind.isDismissive
            item.outcomes.append(event.kind)
            items[id] = item
        }
        var groups: [TriageQuery.Node: [Item]] = [:]
        for item in items.values {
            for feature in features(of: item.snapshot) { groups[feature, default: []].append(item) }
        }
        let covered = Set(rules.enabledRules.flatMap(\.query.terms))
        return groups.compactMap { feature, members -> RuleSuggestionCandidate? in
            let query = TriageQuery(feature)
            guard !covered.contains(feature), !dismissed.contains(query.description) else { return nil }
            let dismissedCount = members.filter(\.dismissed).count
            guard members.count >= minimumItems, Double(dismissedCount) / Double(members.count) >= minimumConsistency else { return nil }
            var outcomes: [TriageFeedback.Kind: Int] = [:]
            for kind in members.flatMap(\.outcomes) { outcomes[kind, default: 0] += 1 }
            let examples = members.filter(\.dismissed).map(\.snapshot).sorted { $0.title < $1.title }.prefix(3)
            return RuleSuggestionCandidate(query: query, items: members.count, dismissed: dismissedCount, outcomes: outcomes, examples: Array(examples))
        }
        .sorted { ($0.dismissed, $0.consistency, $1.key) > ($1.dismissed, $1.consistency, $0.key) }
        .prefix(maximumCandidates)
        .map(\.self)
    }

    /// Single filters that describe an item; Copilot may narrow them.
    static func features(of snapshot: TriageFeedback.Snapshot) -> [TriageQuery.Node] {
        var result: [TriageQuery.Node] = [.qualifier(.repo, snapshot.repository)]
        if let author = snapshot.author { result.append(.qualifier(.author, author)) }
        result += snapshot.labels.map { .qualifier(.label, $0) }
        result += snapshot.signals.map { .qualifier(.signal, $0) }
        result += snapshot.topics.map { .qualifier(.topic, $0) }
        result += snapshot.botCommenters.map { .qualifier(.commenter, $0) }
        result += snapshot.failingChecks.map { .qualifier(.check, "\($0):failing") }
        if let request = snapshot.reviewRequest { result.append(.qualifier(.is, request)) }
        if snapshot.isDraft { result.append(.qualifier(.is, "draft")) }
        return result
    }
}

/// A rule Copilot proposes from a candidate, ready to preview and add.
struct RuleSuggestion: Identifiable, Equatable, Sendable {
    var id: String { rule.query.description + "|" + rule.action.storageValue }
    let rule: TriageRule
    let rationale: String
    let candidate: RuleSuggestionCandidate

    /// Suggestions that parse, use a known action, stay within their group,
    /// match some current work, and don't repeat an existing rule.
    static func validated(
        _ suggestions: [CopilotRuleSuggestion], candidates: [String: RuleSuggestionCandidate],
        rules: TriageRules, entries: [TriageEntry], viewer: String
    ) -> [RuleSuggestion] {
        let existing = Set(rules.rules.map { "\($0.query.description)|\($0.action.storageValue)" })
        var seen = Set<String>()
        return suggestions.compactMap { suggestion in
            guard let candidate = candidates[suggestion.candidateID],
                  let action = TriageRuleAction(storageValue: suggestion.action),
                  let query = try? TriageQuery(parsing: suggestion.query) else { return nil }
            // Narrowing is fine; broadening beyond the group is not.
            let scoped = query.terms.contains(candidate.query.root) ? query : candidate.query.and(query)
            let rule = TriageRule(name: String(suggestion.name.prefix(60)), query: scoped, action: action, origin: .suggestion)
            let key = "\(scoped.description)|\(action.storageValue)"
            guard !existing.contains(key), seen.insert(key).inserted,
                  entries.contains(where: { scoped.matches($0, viewer: viewer) }) else { return nil }
            return RuleSuggestion(rule: rule, rationale: suggestion.rationale, candidate: candidate)
        }
    }
}

/// Asks Copilot to turn candidates into rules. Uses its own helper
/// connection so suggestions never wait behind a triage batch.
actor CopilotRuleSuggester {
    static let requestTimeout: TimeInterval = 120

    private let authorize: @Sendable (WorkspaceScope) async throws -> CopilotTriageAuthorization
    private let now: @Sendable () -> Date
    private let session: CopilotHelperSession

    init(
        makeHelper: @escaping @Sendable () -> any TriageCopilotHelping = CopilotHelperSession.production,
        authorize: @escaping @Sendable (WorkspaceScope) async throws -> CopilotTriageAuthorization,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        session = CopilotHelperSession(makeHelper: makeHelper)
        self.authorize = authorize
        self.now = now
    }

    func suggest(
        _ candidates: [RuleSuggestionCandidate], rules: TriageRules, scope: WorkspaceScope
    ) async throws -> (suggestions: [CopilotRuleSuggestion], candidates: [String: RuleSuggestionCandidate]) {
        guard !candidates.isEmpty else { return ([], [:]) }
        let authorization = try await CopilotTriageAuthorization.require(authorize, scope: scope)
        let numbered = Dictionary(uniqueKeysWithValues: candidates.prefix(CopilotSuggestRulesRequest.maximumCandidates)
            .enumerated().map { ("c\($0.offset + 1)", $0.element) })
        let wire = numbered.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { id, candidate in
            CopilotSuggestionCandidate(
                id: id, query: candidate.key, total: candidate.items, dismissive: candidate.dismissed,
                outcomes: candidate.outcomes.sorted { $0.key.rawValue < $1.key.rawValue }.prefix(10).map { .init(kind: $0.key.rawValue, count: $0.value) },
                examples: candidate.examples.map {
                    .init(repository: $0.repository, title: $0.title, author: $0.author, labels: Array($0.labels.prefix(5)), signals: $0.signals)
                }
            )
        }
        let existing = rules.rules.prefix(TriageRules.maximumRules).map { String("\($0.action.storageValue): \($0.query)".prefix(400)) }
        let topics = rules.topics.map { CopilotTriageTopic(name: $0.trimmedName, description: $0.trimmedDescription) }
        let now = self.now
        let response = try await session.run(scope: scope) { helper in
            try await helper.suggestRules(CopilotSuggestRulesRequest(
                accountID: scope.accountID, organizationID: scope.organizationID, viewerLogin: scope.viewerLogin,
                candidates: wire, existingRules: existing, topics: topics, modelID: authorization.selectedModelID,
                deadline: now().addingTimeInterval(Self.requestTimeout),
                reasoningEffort: authorization.reasoningEffort, contextTier: authorization.contextTier
            ))
        }
        return (response.suggestions, numbered)
    }
}
