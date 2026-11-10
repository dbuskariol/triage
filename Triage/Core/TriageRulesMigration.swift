import Foundation

/// Rules saved before rules were queries: all-of conditions plus one effect.
/// Decoded only to migrate them; never written.
struct LegacyTriageRule: Decodable, Sendable {
    struct Condition: Decodable, Sendable {
        let field: String
        let value: String
    }

    let conditions: [Condition]
    let effect: String

    /// The equivalent query and action, or `nil` if nothing usable remains.
    func migrated() -> (query: TriageQuery, action: TriageRuleAction)? {
        let nodes = conditions.compactMap(Self.node)
        guard !nodes.isEmpty, nodes.count == conditions.count, let action = Self.action(effect) else { return nil }
        return (TriageQuery(.all(nodes)), action)
    }

    static func action(_ effect: String) -> TriageRuleAction? {
        switch effect {
        case "alwaysInbox": .route(.inbox)
        case "needsAction": .route(.needsAction)
        case "waiting": .route(.waiting)
        case "noAction": .route(.noAction)
        case "raisePriority": .rank(.higher, .medium)
        case "lowerPriority": .rank(.lower, .medium)
        case "mute": .exclude
        default: nil
        }
    }

    static func node(_ condition: Condition) -> TriageQuery.Node? {
        let value = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        func q(_ key: TriageQuery.Qualifier, _ value: String) -> TriageQuery.Node { .qualifier(key, value) }
        switch condition.field {
        case "repository": return q(.repo, value)
        case "author": return q(.author, value)
        case "label": return q(.label, value)
        case "requestedTeam": return q(.team, value)
        case "titleContains": return q(.title, value)
        case "inactiveDays":
            guard let days = Int(value), days > 0 else { return nil }
            return q(.updated, ">=\(days)d")
        case "relationship":
            switch value {
            case "reviewRequested": return q(.is, "review")
            case "reviewRequestedDirect": return q(.is, "direct")
            case "reviewRequestedTeam": return q(.is, "team")
            case "assigned": return q(.is, "assigned")
            case "authored": return q(.is, "mine")
            case "mentioned": return q(.is, "mentioned")
            case "commented": return q(.is, "commented")
            default: return nil
            }
        case "pullRequestStatus":
            switch value {
            case "draft": return q(.is, "draft")
            case "ready": return .all([q(.is, "pr"), .not(q(.is, "draft"))])
            case "approved": return q(.status, "approved")
            case "changesRequested": return q(.status, "changes")
            case "checksFailing": return q(.status, "failing")
            case "conflicts": return q(.status, "conflicts")
            default: return nil
            }
        case "kind":
            switch value {
            case "issue": return q(.is, "issue")
            case "pullRequest": return q(.is, "pr")
            case "draftPullRequest": return q(.is, "draft")
            default: return nil
            }
        default:
            return nil
        }
    }
}
