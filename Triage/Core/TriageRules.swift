import CryptoKit
import Foundation

/// The user's triage preferences for one organization.
///
/// Two layers, following the "filters + custom instructions" pattern:
/// - `rules` are deterministic. Triage applies them on top of Copilot's
///   decision, so they always hold and take effect instantly.
/// - `instructions` are free-text guidance sent to Copilot in a delimited,
///   lower-precedence block after the fixed system policy.
struct TriageRules: Codable, Equatable, Sendable {
    static let maximumInstructionBytes = 2_000
    /// Bump when the triage prompt changes materially, so existing decisions
    /// are re-analyzed in the background with the improved prompt.
    static let promptVersion = "prompt-4"
    static let maximumRules = 100
    static let empty = TriageRules(instructions: "", rules: [])

    var instructions: String
    var rules: [TriageRule]
    /// Changed by "Re-analyze All" to make every decision stale.
    var reanalysisToken = ""

    init(instructions: String, rules: [TriageRule], reanalysisToken: String = "") {
        self.instructions = instructions
        self.rules = rules
        self.reanalysisToken = reanalysisToken
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instructions = try container.decode(String.self, forKey: .instructions)
        rules = try container.decode([TriageRule].self, forKey: .rules)
        reanalysisToken = try container.decodeIfPresent(String.self, forKey: .reanalysisToken) ?? ""
    }

    var trimmedInstructions: String? {
        let value = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var enabledRules: [TriageRule] { rules.filter { $0.isEnabled && $0.isValid } }

    /// Changes whenever anything Copilot sees changes, so decisions made under
    /// older preferences are re-analyzed. Disabled and invalid rules are ignored.
    /// Just the prompt version when there are no preferences.
    var digest: String {
        guard trimmedInstructions != nil || !enabledRules.isEmpty || !reanalysisToken.isEmpty else { return Self.promptVersion }
        struct Canonical: Encodable { let prompt: String; let instructions: String; let rules: [TriageRule]; let token: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Canonical(prompt: Self.promptVersion, instructions: trimmedInstructions ?? "", rules: enabledRules, token: reanalysisToken))) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func validated() throws -> TriageRules {
        guard instructions.utf8.count <= Self.maximumInstructionBytes else { throw TriageRulesError.instructionsTooLong }
        guard rules.count <= Self.maximumRules else { throw TriageRulesError.tooManyRules }
        guard rules.allSatisfy(\.isValid) else { throw TriageRulesError.invalidRule }
        return self
    }

    /// Enabled rules matching `item`, in list order. `viewer` is the signed-in
    /// login, needed for "requested from me directly / from my team".
    func matches(for item: PersonalWorkItem, viewer: String = "") -> [TriageRule] {
        enabledRules.filter { $0.matches(item, viewer: viewer) }
    }

    func isMuted(_ item: PersonalWorkItem, viewer: String = "") -> Bool {
        matches(for: item, viewer: viewer).contains { $0.effect == .mute }
    }

    /// Short, model-readable statements of what the user's rules will enforce.
    func hints(for item: PersonalWorkItem, viewer: String = "") -> [String] {
        matches(for: item, viewer: viewer).prefix(10).map { rule in
            String("User rule “\(rule.displayName)”: \(rule.effect.hint)".prefix(200))
        }
    }

    /// Applies hard rules on top of Copilot's decision. The first matching
    /// disposition rule wins; priority adjustments accumulate.
    func apply(to entry: TriageEntry, viewer: String = "") -> TriageEntry {
        let matched = matches(for: entry.item, viewer: viewer)
        guard !matched.isEmpty else { return entry }
        var result = entry
        result.appliedRules = matched.map(\.displayName)
        result.isMuted = matched.contains { $0.effect == .mute }
        guard let decision = entry.decision else { return result }
        var disposition = decision.disposition
        if let effect = matched.first(where: { $0.effect.disposition != nil })?.effect {
            // "Always Inbox" never downgrades an item Copilot already says needs action.
            disposition = effect == .alwaysInbox && decision.disposition.isInbox ? decision.disposition : effect.disposition!
        }
        let adjustment = matched.reduce(0) { $0 + $1.effect.priorityAdjustment }
        result.decision = TriageDecision(
            itemID: decision.itemID, disposition: disposition,
            priority: min(100, max(0, decision.priority + adjustment)),
            confidence: decision.confidence, summary: decision.summary, reason: decision.reason,
            nextAction: decision.nextAction, fingerprint: decision.fingerprint, modelID: decision.modelID,
            decidedAt: decision.decidedAt, rulesDigest: decision.rulesDigest,
            instructionNote: decision.instructionNote,
            handled: decision.handled, handledEvidence: decision.handledEvidence,
            effort: decision.effort
        )
        return result
    }
}

enum TriageRulesError: Error, Equatable, LocalizedError {
    case instructionsTooLong
    case tooManyRules
    case invalidRule

    var errorDescription: String? {
        switch self {
        case .instructionsTooLong: "Instructions can be at most \(TriageRules.maximumInstructionBytes) characters."
        case .tooManyRules: "You can have at most \(TriageRules.maximumRules) rules."
        case .invalidRule: "Every rule needs at least one condition with a value."
        }
    }
}

struct TriageRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var isEnabled = true
    /// All conditions must match.
    var conditions: [TriageRuleCondition]
    var effect: TriageRuleEffect

    var isValid: Bool { !conditions.isEmpty && conditions.allSatisfy(\.isValid) }

    /// Conditions describing `item`, most useful first, for building a rule from it.
    static func suggestedConditions(for item: PersonalWorkItem, viewer: String) -> [TriageRuleCondition] {
        typealias Condition = TriageRuleCondition
        var result: [Condition] = []
        switch item.reviewRequestKind(viewer: viewer) {
        case .team?: result.append(.init(field: .relationship, value: Condition.Field.reviewRequestedTeam))
        case .direct?: result.append(.init(field: .relationship, value: Condition.Field.reviewRequestedDirect))
        case nil:
            if let relationship = item.primaryRelationship {
                result.append(.init(field: .relationship, value: relationship.rawValue))
            }
        }
        result += (item.pullRequest?.requestedReviewers ?? []).filter { $0.contains("/") }.prefix(2)
            .map { .init(field: .requestedTeam, value: $0) }
        result.append(.init(field: .repository, value: item.repository))
        if let author = item.author { result.append(.init(field: .author, value: author)) }
        result += item.labels.prefix(3).map { .init(field: .label, value: $0) }
        if item.pullRequest?.isDraft == true { result.append(.init(field: .pullRequestStatus, value: "draft")) }
        return result
    }

    static func quick(_ effect: TriageRuleEffect, _ field: TriageRuleCondition.Field, _ value: String) -> TriageRule {
        TriageRule(name: "", conditions: [TriageRuleCondition(field: field, value: value)], effect: effect)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    var defaultName: String {
        "\(effect.title): \(conditions.map(\.summary).joined(separator: " and "))"
    }

    func matches(_ item: PersonalWorkItem, viewer: String = "") -> Bool {
        isValid && conditions.allSatisfy { $0.matches(item, viewer: viewer) }
    }
}

struct TriageRuleCondition: Codable, Equatable, Hashable, Sendable {
    enum Field: String, Codable, CaseIterable, Identifiable, Sendable {
        case relationship, requestedTeam, pullRequestStatus, repository, author, label, kind, titleContains, textContains, inactiveDays

        var id: String { rawValue }

        static let reviewRequestedDirect = "reviewRequestedDirect"
        static let reviewRequestedTeam = "reviewRequestedTeam"

        var title: String {
            switch self {
            case .repository: "Repository"
            case .author: "Author"
            case .label: "Label"
            case .relationship: "My relationship"
            case .requestedTeam: "Requested team"
            case .pullRequestStatus: "Pull request status"
            case .kind: "Type"
            case .titleContains: "Title contains"
            case .textContains: "Contains text"
            case .inactiveDays: "No updates for (days)"
            }
        }

        var placeholder: String {
            switch self {
            case .repository: "owner/name or owner/*"
            case .author: "login, e.g. dependabot[bot]"
            case .label: "label name"
            case .relationship, .kind, .pullRequestStatus: ""
            case .requestedTeam: "team slug or org/team"
            case .titleContains: "text"
            case .textContains: "words, ignoring formatting"
            case .inactiveDays: "e.g. 14"
            }
        }

        /// Fixed choices; `nil` means free text.
        var choices: [(value: String, title: String)]? {
            switch self {
            case .relationship:
                [
                    ("reviewRequested", "Review requested (direct or team)"),
                    (Self.reviewRequestedDirect, "Review requested from me directly"),
                    (Self.reviewRequestedTeam, "Review requested from my team only"),
                ] + WorkRelationship.allCases.filter { $0 != .reviewRequested }.map { ($0.rawValue, $0.title) }
            case .pullRequestStatus:
                [
                    ("draft", "Draft"), ("ready", "Ready for review"), ("approved", "Approved"),
                    ("changesRequested", "Changes requested"), ("checksFailing", "Checks failing"),
                    ("conflicts", "Has conflicts"),
                ]
            case .kind: [("issue", "Issue"), ("pullRequest", "Pull request"), ("draftPullRequest", "Draft pull request")]
            case .repository, .author, .label, .titleContains, .textContains, .requestedTeam, .inactiveDays: nil
            }
        }
    }

    var field: Field
    var value: String

    var isValid: Bool {
        guard !normalizedValue.isEmpty else { return false }
        if field == .textContains { return !PersonalWorkItem.plainText(from: normalizedValue).isEmpty }
        return field != .inactiveDays || (Int(normalizedValue) ?? 0) > 0
    }

    private var normalizedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var summary: String {
        let shown = field.choices?.first { $0.value == normalizedValue }?.title ?? normalizedValue
        switch field {
        case .titleContains: return "title contains “\(shown)”"
        case .textContains: return "text contains “\(PersonalWorkItem.plainText(from: normalizedValue))”"
        case .inactiveDays: return "no updates for \(shown)+ days"
        case .relationship, .pullRequestStatus: return shown.prefix(1).lowercased() + shown.dropFirst()
        default: return "\(field.title.lowercased()) is \(shown)"
        }
    }

    func matches(_ item: PersonalWorkItem, viewer: String = "", now: Date = .now) -> Bool {
        let value = normalizedValue
        guard !value.isEmpty else { return false }
        func same(_ other: String?) -> Bool { other?.caseInsensitiveCompare(value) == .orderedSame }
        switch field {
        case .repository:
            if value.hasSuffix("/*") {
                return item.repository.lowercased().hasPrefix(String(value.dropLast()).lowercased())
            }
            return same(item.repository) || same(item.repository.split(separator: "/").last.map(String.init))
        case .author: return same(item.author)
        case .label: return item.labels.contains { same($0) }
        case .relationship:
            switch value {
            case Field.reviewRequestedDirect: return item.reviewRequestKind(viewer: viewer) == .direct
            case Field.reviewRequestedTeam: return item.reviewRequestKind(viewer: viewer) == .team
            default: return item.relationships.contains { $0.rawValue == value }
            }
        case .requestedTeam:
            // Matches "org/team" exactly, or just the team slug.
            return (item.pullRequest?.requestedReviewers ?? []).contains { reviewer in
                reviewer.contains("/") && (same(reviewer) || same(reviewer.split(separator: "/").last.map(String.init)))
            }
        case .pullRequestStatus:
            guard let facts = item.pullRequest else { return false }
            switch value {
            case "draft": return facts.isDraft
            case "ready": return !facts.isDraft && item.state == .open
            case "approved": return facts.reviewDecision == .approved
            case "changesRequested": return facts.reviewDecision == .changesRequested
            case "checksFailing": return facts.checks == .failure || facts.checks == .error
            case "conflicts": return facts.mergeable?.uppercased() == "CONFLICTING"
            default: return false
            }
        case .inactiveDays:
            guard let days = Int(value), days > 0 else { return false }
            return now.timeIntervalSince(item.updatedAt) >= TimeInterval(days * 86_400)
        case .kind:
            switch value {
            case "issue": return item.kind == .issue
            case "pullRequest": return item.kind == .pullRequest
            case "draftPullRequest": return item.pullRequest?.isDraft == true
            default: return false
            }
        case .titleContains: return item.title.localizedCaseInsensitiveContains(value)
        case .textContains:
            let query = PersonalWorkItem.plainText(from: value)
            guard !query.isEmpty else { return false }
            return item.searchablePlainText.localizedCaseInsensitiveContains(query)
        }
    }
}

enum TriageRuleEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case alwaysInbox, needsAction, waiting, noAction, raisePriority, lowerPriority, mute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysInbox: "Always show in Inbox"
        case .needsAction: "Mark as needs my action"
        case .waiting: "Move to Waiting on Others"
        case .noAction: "Move to No Action Needed"
        case .raisePriority: "Raise priority"
        case .lowerPriority: "Lower priority"
        case .mute: "Mute"
        }
    }

    var systemImage: String {
        switch self {
        case .alwaysInbox: "tray.full"
        case .needsAction: "exclamationmark.circle"
        case .waiting: "hourglass"
        case .noAction: "checkmark.circle"
        case .raisePriority: "arrow.up.circle"
        case .lowerPriority: "arrow.down.circle"
        case .mute: "speaker.slash"
        }
    }

    /// Hard disposition this effect enforces, if any.
    var disposition: TriageDisposition? {
        switch self {
        case .alwaysInbox: .review
        case .needsAction: .act
        case .waiting: .wait
        case .noAction: .none
        case .raisePriority, .lowerPriority, .mute: nil
        }
    }

    var priorityAdjustment: Int {
        switch self {
        case .raisePriority: 25
        case .lowerPriority: -25
        default: 0
        }
    }

    var hint: String {
        switch self {
        case .alwaysInbox: "the user always wants this in their Inbox (at least review)."
        case .needsAction: "the user treats this as needing their action."
        case .waiting: "the user treats this as waiting on others."
        case .noAction: "the user treats this as needing no action."
        case .raisePriority: "the user wants this ranked higher."
        case .lowerPriority: "the user wants this ranked lower."
        case .mute: "the user has muted this."
        }
    }
}
