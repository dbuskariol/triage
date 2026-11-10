import CryptoKit
import Foundation

/// The user's triage preferences for one organization.
///
/// Two layers, following the "filters + custom instructions" pattern:
/// - `rules` are deterministic queries with one action each. Triage applies
///   them on top of Copilot's decision, so they always hold and take effect
///   instantly.
/// - `instructions` are free-text guidance sent to Copilot in a delimited,
///   lower-precedence block after the fixed system policy.
///
/// Precedence is fixed: local status (Done, Snooze, Mute) → Exclude → Route → Rank.
struct TriageRules: Codable, Equatable, Sendable {
    static let maximumInstructionBytes = 2_000
    /// Bump when the triage prompt changes materially, so existing decisions
    /// are re-analyzed in the background with the improved prompt.
    static let promptVersion = "prompt-5"
    static let maximumRules = 100
    /// Rank weights add up to at most this much either way.
    static let maximumRankAdjustment = 40
    static let empty = TriageRules(instructions: "", rules: [])

    var instructions: String
    var rules: [TriageRule]
    /// Things Copilot tags work with, so rules and search can use `topic:`.
    var topics: [TriageTopic] = []
    /// Changed by "Re-analyze All" to make every decision stale.
    var reanalysisToken = ""

    init(instructions: String, rules: [TriageRule], topics: [TriageTopic] = [], reanalysisToken: String = "") {
        self.instructions = instructions
        self.rules = rules
        self.topics = topics
        self.reanalysisToken = reanalysisToken
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instructions = try container.decode(String.self, forKey: .instructions)
        // Rules that can't be read (or migrated) are dropped, never the whole set.
        rules = try container.decode([LossyRule].self, forKey: .rules).compactMap(\.rule)
        topics = try container.decodeIfPresent([TriageTopic].self, forKey: .topics) ?? []
        reanalysisToken = try container.decodeIfPresent(String.self, forKey: .reanalysisToken) ?? ""
    }

    private struct LossyRule: Decodable {
        let rule: TriageRule?
        init(from decoder: any Decoder) throws { rule = try? TriageRule(from: decoder) }
    }

    var trimmedInstructions: String? {
        let value = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var enabledRules: [TriageRule] { rules.filter(\.isEnabled) }

    func validated() throws -> TriageRules {
        guard instructions.utf8.count <= Self.maximumInstructionBytes else { throw TriageRulesError.instructionsTooLong }
        guard rules.count <= Self.maximumRules else { throw TriageRulesError.tooManyRules }
        guard topics.count <= TriageTopic.maximumCount else { throw TriageRulesError.tooManyTopics }
        var names = Set<String>()
        for topic in topics {
            if let problem = topic.problem { throw TriageRulesError.invalidTopic(problem) }
            guard names.insert(topic.trimmedName.lowercased()).inserted else { throw TriageRulesError.duplicateTopic(topic.trimmedName) }
        }
        return self
    }

    // MARK: Matching

    /// Enabled rules matching `entry`, in list order. Rules that use Copilot's
    /// output match only once a decision exists.
    func matches(for entry: TriageEntry, viewer: String, now: Date = .now) -> [TriageRule] {
        enabledRules.filter { $0.matches(entry, viewer: viewer, now: now) }
    }

    /// Whether a rule hides `item` on GitHub facts alone, so Copilot never sees it.
    func isExcludedBeforeAnalysis(_ item: PersonalWorkItem, viewer: String, now: Date = .now) -> Bool {
        enabledRules.contains { $0.action == .exclude && $0.query.phase == .facts && $0.query.matches(item, viewer: viewer, now: now) }
    }

    /// Route rules Copilot should agree with, as short model-readable statements.
    /// Only fact rules qualify: they hold whatever Copilot decides.
    func hints(for item: PersonalWorkItem, viewer: String, now: Date = .now) -> [String] {
        enabledRules
            .filter { if case .route = $0.action { $0.query.phase == .facts } else { false } }
            .filter { $0.query.matches(item, viewer: viewer, now: now) }
            .prefix(10)
            .map { String("User rule “\($0.displayName)”: \($0.action.hint)".prefix(200)) }
    }

    /// Changes whenever anything Copilot sees for `item` changes, so only the
    /// decisions affected by a preference change are re-analyzed. Exclude and
    /// rank rules, and rules on Copilot's output, never change it.
    func digest(for item: PersonalWorkItem, viewer: String) -> String {
        let hints = hints(for: item, viewer: viewer)
        guard trimmedInstructions != nil || !hints.isEmpty || !reanalysisToken.isEmpty || !topics.isEmpty else { return Self.promptVersion }
        struct Canonical: Encodable { let prompt: String; let instructions: String; let hints: [String]; let topics: [String]; let token: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Canonical(
            prompt: Self.promptVersion, instructions: trimmedInstructions ?? "", hints: hints,
            topics: topics.map { "\($0.trimmedName): \($0.trimmedDescription)" }, token: reanalysisToken
        ))) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Applies rules on top of Copilot's decision: Exclude, then the first
    /// matching Route, then ranking (Copilot's priority, fixed factors, and
    /// capped Rank weights; see `PriorityBreakdown`).
    func apply(to entry: TriageEntry, viewer: String, now: Date = .now) -> TriageEntry {
        let matched = matches(for: entry, viewer: viewer, now: now)
        var result = entry
        result.appliedRules = matched.map(\.displayName)
        result.excludedBy = matched.first { $0.action == .exclude }?.displayName
        guard let decision = entry.decision else { return result }
        var updated = decision
        if let route = matched.lazy.compactMap(\.action.route).first {
            // "Move to Inbox" never downgrades an item Copilot says needs action.
            updated.disposition = route == .inbox && decision.disposition == .act ? .act : route.disposition
        }
        result.decision = updated
        let breakdown = PriorityBreakdown(
            copilot: decision.priority,
            factors: PriorityBreakdown.factors(for: result, viewer: viewer, now: now),
            rules: matched.filter { $0.action.rankAdjustment != 0 }.map { .init(title: $0.displayName, points: $0.action.rankAdjustment) }
        )
        result.decision?.priority = breakdown.total
        result.priorityBreakdown = breakdown
        return result
    }

    /// Pairs of enabled route rules that both match some entry but send it to
    /// different places; the earlier rule wins.
    func conflicts(in entries: [TriageEntry], viewer: String, now: Date = .now) -> [(winner: TriageRule, loser: TriageRule)] {
        let routes = enabledRules.filter { $0.action.route != nil }
        var result: [(TriageRule, TriageRule)] = []
        for (index, winner) in routes.enumerated() {
            for loser in routes[(index + 1)...] where loser.action.route != winner.action.route {
                if entries.contains(where: { winner.matches($0, viewer: viewer, now: now) && loser.matches($0, viewer: viewer, now: now) }) {
                    result.append((winner, loser))
                }
            }
        }
        return result
    }
}

enum TriageRulesError: Error, Equatable, LocalizedError {
    case instructionsTooLong
    case tooManyRules
    case tooManyTopics
    case invalidTopic(String)
    case duplicateTopic(String)

    var errorDescription: String? {
        switch self {
        case .instructionsTooLong: "Instructions can be at most \(TriageRules.maximumInstructionBytes) characters."
        case .tooManyRules: "You can have at most \(TriageRules.maximumRules) rules."
        case .tooManyTopics: "You can have at most \(TriageTopic.maximumCount) topics."
        case .invalidTopic(let problem): problem
        case .duplicateTopic(let name): "You already have a topic named “\(name)”."
        }
    }
}

/// Something the user wants Copilot to recognize, e.g. "Compliance approvals:
/// blocked on a FedRAMP or other compliance deployment approval". Copilot
/// tags matching work; rules and search use `topic:"Compliance approvals"`.
struct TriageTopic: Codable, Equatable, Hashable, Identifiable, Sendable {
    static let maximumCount = 20
    static let maximumNameBytes = 60
    static let maximumDescriptionBytes = 280

    var id = UUID()
    var name: String
    var description: String

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why this topic can't be saved, if it can't.
    var problem: String? {
        if trimmedName.isEmpty { return "Give the topic a name." }
        if trimmedName.utf8.count > Self.maximumNameBytes { return "Topic names can be at most \(Self.maximumNameBytes) characters." }
        if trimmedDescription.isEmpty { return "Describe what “\(trimmedName)” covers, so Copilot can recognize it." }
        if trimmedDescription.utf8.count > Self.maximumDescriptionBytes { return "Topic descriptions can be at most \(Self.maximumDescriptionBytes) characters." }
        if (name + description).contains(where: { "<>".contains($0) }) || name.contains(where: \.isNewline) {
            return "Topics can't contain < or >, and names can't span lines."
        }
        return nil
    }
}

/// One rule: when `query` matches, do `action`.
struct TriageRule: Codable, Equatable, Identifiable, Sendable {
    enum Origin: String, Codable, Sendable { case user, suggestion }

    var id = UUID()
    var name: String
    var isEnabled = true
    var query: TriageQuery
    var action: TriageRuleAction
    var origin = Origin.user

    init(id: UUID = UUID(), name: String = "", isEnabled: Bool = true, query: TriageQuery, action: TriageRuleAction, origin: Origin = .user) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.query = query
        self.action = action
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey { case id, name, isEnabled, query, action, origin }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin) ?? .user
        if container.contains(.query) {
            query = try container.decode(TriageQuery.self, forKey: .query)
            action = try container.decode(TriageRuleAction.self, forKey: .action)
        } else {
            // Rules saved as conditions and an effect.
            guard let migrated = try LegacyTriageRule(from: decoder).migrated() else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unusable legacy rule"))
            }
            query = migrated.query
            action = migrated.action
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    var defaultName: String { "\(action.title): \(query.description)" }

    /// Rules on Copilot's output wait for a decision.
    func matches(_ entry: TriageEntry, viewer: String, now: Date = .now) -> Bool {
        if query.phase == .ai, entry.decision == nil { return false }
        return query.matches(entry, viewer: viewer, now: now)
    }

    /// Filters describing `entry`, most useful first, for building a rule from it.
    static func suggestedTokens(for entry: TriageEntry, viewer: String) -> [SearchToken] {
        let item = entry.item
        let facts = item.pullRequest
        var result: [SearchToken] = []
        func add(_ kind: SearchToken.Kind, _ value: String) {
            let token = SearchToken(kind: kind, value: value)
            if !result.contains(token) { result.append(token) }
        }
        switch item.reviewRequestKind(viewer: viewer) {
        case .team?: add(.is, "team")
        case .direct?: add(.is, "direct")
        case nil:
            switch item.primaryRelationship {
            case .assigned?: add(.is, "assigned")
            case .authored?: add(.is, "mine")
            case .mentioned?: add(.is, "mentioned")
            case .commented?: add(.is, "commented")
            case .reviewRequested?, nil: break
            }
        }
        for signal in entry.decision?.signals ?? [] { add(.signal, signal) }
        for topic in entry.decision?.topics ?? [] { add(.topic, topic) }
        if facts?.checks == .failure || facts?.checks == .error { add(.status, "failing") }
        for run in (facts?.checkRuns ?? []).filter({ $0.result == .failing }).prefix(2) { add(.check, "\(run.name):failing") }
        for team in (facts?.requestedReviewers ?? []).filter({ $0.contains("/") }).prefix(2) { add(.team, team) }
        add(.repo, item.repository)
        if let author = item.author { add(.author, author) }
        for bot in Set(item.recentActivity.map(\.author)).filter({ $0.hasSuffix("[bot]") }).sorted().prefix(2) { add(.commenter, bot) }
        for label in item.labels.prefix(3) { add(.label, label) }
        if facts?.isDraft == true { add(.is, "draft") }
        return result
    }
}

/// What a rule does. Exclude hides; Route moves to a section; Rank nudges order.
enum TriageRuleAction: Hashable, Sendable {
    enum Route: String, CaseIterable, Sendable {
        case needsAction, inbox, waiting, noAction

        var disposition: TriageDisposition {
            switch self {
            case .needsAction: .act
            case .inbox: .review
            case .waiting: .wait
            case .noAction: .none
            }
        }

        var title: String {
            switch self {
            case .needsAction: "Needs my action"
            case .inbox: "Inbox"
            case .waiting: "Waiting on Others"
            case .noAction: "No Action Needed"
            }
        }
    }

    enum Direction: String, CaseIterable, Sendable { case higher, lower }

    enum Strength: String, CaseIterable, Sendable {
        case small, medium, large

        var points: Int {
            switch self {
            case .small: 10
            case .medium: 20
            case .large: 35
            }
        }

        var title: String { rawValue.capitalized }
    }

    case exclude
    case route(Route)
    case rank(Direction, Strength)

    static let all: [TriageRuleAction] = [.exclude]
        + Route.allCases.map(TriageRuleAction.route)
        + Direction.allCases.flatMap { direction in Strength.allCases.map { .rank(direction, $0) } }

    var route: Route? { if case .route(let route) = self { route } else { nil } }

    var rankAdjustment: Int {
        guard case .rank(let direction, let strength) = self else { return 0 }
        return direction == .higher ? strength.points : -strength.points
    }

    var title: String {
        switch self {
        case .exclude: "Hide"
        case .route(let route): "Move to \(route.title)"
        case .rank(let direction, let strength): "Rank \(direction.rawValue) (\(strength.title.lowercased()))"
        }
    }

    var systemImage: String {
        switch self {
        case .exclude: "eye.slash"
        case .route(.needsAction): "exclamationmark.circle"
        case .route(.inbox): "tray.full"
        case .route(.waiting): "hourglass"
        case .route(.noAction): "checkmark.circle"
        case .rank(.higher, _): "arrow.up.circle"
        case .rank(.lower, _): "arrow.down.circle"
        }
    }

    var hint: String {
        switch self {
        case .exclude: "the user has hidden this."
        case .route(.needsAction): "the user treats this as needing their action."
        case .route(.inbox): "the user always wants this in their Inbox (at least review)."
        case .route(.waiting): "the user treats this as waiting on others."
        case .route(.noAction): "the user treats this as needing no action."
        case .rank(.higher, _): "the user wants this ranked higher."
        case .rank(.lower, _): "the user wants this ranked lower."
        }
    }
}

extension TriageRuleAction: Codable {
    /// Stored as one string: `exclude`, `route:waiting`, `rank:lower:medium`.
    var storageValue: String {
        switch self {
        case .exclude: "exclude"
        case .route(let route): "route:\(route.rawValue)"
        case .rank(let direction, let strength): "rank:\(direction.rawValue):\(strength.rawValue)"
        }
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":").map(String.init)
        switch parts.first {
        case "exclude" where parts.count == 1: self = .exclude
        case "route" where parts.count == 2:
            guard let route = Route(rawValue: parts[1]) else { return nil }
            self = .route(route)
        case "rank" where parts.count == 3:
            guard let direction = Direction(rawValue: parts[1]), let strength = Strength(rawValue: parts[2]) else { return nil }
            self = .rank(direction, strength)
        default: return nil
        }
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let action = TriageRuleAction(storageValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown rule action \(value)"))
        }
        self = action
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}
