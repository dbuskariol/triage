import Foundation

extension TriageQuery {
    /// Whether `entry` matches. `viewer` resolves `@me` and relationship
    /// filters; `now` anchors `updated:` and `created:`.
    func matches(_ entry: TriageEntry, viewer: String, now: Date = .now) -> Bool {
        Self.matches(root, entry, TriageQueryContext(viewer: viewer, now: now))
    }

    /// Matches on GitHub facts alone, before Copilot has decided.
    func matches(_ item: PersonalWorkItem, viewer: String, now: Date = .now) -> Bool {
        matches(TriageEntry(item: item, decision: nil, analysis: .pending, local: .active), viewer: viewer, now: now)
    }

    private static func matches(_ node: Node, _ entry: TriageEntry, _ context: TriageQueryContext) -> Bool {
        switch node {
        case .all(let nodes): nodes.allSatisfy { matches($0, entry, context) }
        case .any(let nodes): nodes.contains { matches($0, entry, context) }
        case .not(let inner): !matches(inner, entry, context)
        case .qualifier(let key, let value): matches(key, value, entry, context)
        case .text(let text): matchesText(text, entry)
        }
    }

    private static func matchesText(_ text: String, _ entry: TriageEntry) -> Bool {
        let item = entry.item
        func has(_ field: String?) -> Bool { field?.localizedCaseInsensitiveContains(text) == true }
        if has(item.title) || has(item.repository) || has("#\(item.number)") || has(item.author) || has(item.body) { return true }
        if item.labels.contains(where: has) || item.assignees.contains(where: has) { return true }
        if (item.pullRequest?.requestedReviewers ?? []).contains(where: has) { return true }
        if item.recentActivity.contains(where: { has($0.excerpt) || has($0.author) }) { return true }
        guard let decision = entry.decision else { return false }
        return has(decision.summary) || has(decision.reason) || has(decision.nextAction)
    }

    private static func matches(_ key: Qualifier, _ value: String, _ entry: TriageEntry, _ context: TriageQueryContext) -> Bool {
        let item = entry.item
        let facts = item.pullRequest
        func same(_ candidate: String?) -> Bool { context.matches(candidate, pattern: value) }
        func contains(_ candidate: String?) -> Bool { candidate?.localizedCaseInsensitiveContains(value) == true }
        switch key {
        case .repo:
            if value.contains("/") { return same(item.repository) }
            return same(item.repository) || same(item.repository.split(separator: "/").last.map(String.init))
        case .author: return same(item.author)
        case .assignee: return item.assignees.contains(where: same)
        case .commenter: return item.recentActivity.contains { same($0.author) }
        case .reviewer:
            return (facts?.latestReviews ?? []).contains { same($0.author) }
                || (facts?.requestedReviewers ?? []).contains { !$0.contains("/") && same($0) }
        case .team:
            return (facts?.requestedReviewers ?? []).contains { reviewer in
                reviewer.contains("/") && (same(reviewer) || same(reviewer.split(separator: "/").last.map(String.init)))
            }
        case .label: return item.labels.contains(where: same)
        case .is:
            switch value {
            case "pr": return item.kind == .pullRequest
            case "issue": return item.kind == .issue
            case "draft": return facts?.isDraft == true
            case "review": return item.relationships.contains(.reviewRequested)
            case "direct": return item.reviewRequestKind(viewer: context.viewer) == .direct
            case "team": return item.reviewRequestKind(viewer: context.viewer) == .team
            case "assigned": return item.relationships.contains(.assigned)
            case "mine": return item.relationships.contains(.authored)
            case "mentioned": return item.relationships.contains(.mentioned)
            case "unread": return entry.isUnread
            case "read": return !entry.isUnread
            default: return false
            }
        case .status:
            guard let facts else { return false }
            switch value {
            case "failing": return facts.checks == .failure || facts.checks == .error
            case "required-failing": return facts.hasFailingRequiredCheck
            case "passing": return facts.checks == .success
            case "pending": return facts.checks == .pending || facts.checks == .expected
            case "conflicts": return facts.mergeable?.uppercased() == "CONFLICTING"
            case "approved": return facts.reviewDecision == .approved
            case "changes": return facts.reviewDecision == .changesRequested
            default: return false
            }
        case .check: return facts?.matchesCheck(value, same: same) == true
        case .title: return contains(item.title)
        case .body: return contains(item.body)
        case .comment: return item.recentActivity.contains { contains($0.excerpt) }
        case .updated: return context.age(of: item.updatedAt, matches: value)
        case .created: return context.age(of: item.createdAt, matches: value)
        case .size:
            guard let facts, let comparison = TriageQueryComparison(number: value) else { return false }
            return comparison.holds(facts.additions + facts.deletions)
        case .priority:
            guard let priority = entry.decision?.priority else { return false }
            if let band = PriorityBand(rawValue: value) { return PriorityBand(priority) == band }
            return TriageQueryComparison(number: value)?.holds(priority) == true
        case .effort: return entry.decision?.effort?.rawValue == value
        case .in:
            guard let disposition = entry.decision?.disposition else { return false }
            switch value {
            case "action": return disposition == .act
            case "review": return disposition == .review
            case "inbox": return disposition.isInbox
            case "waiting": return disposition == .wait
            case "none": return disposition == .none
            default: return false
            }
        case .signal: return entry.decision?.signals?.contains { $0.caseInsensitiveCompare(value) == .orderedSame } == true
        case .topic: return entry.decision?.topics?.contains { $0.caseInsensitiveCompare(value) == .orderedSame } == true
        }
    }
}

struct TriageQueryContext: Sendable {
    let viewer: String
    let now: Date

    /// Case-insensitive equality; `*` is a wildcard and `@me` is the viewer.
    func matches(_ candidate: String?, pattern: String) -> Bool {
        guard let candidate else { return false }
        let pattern = pattern.caseInsensitiveCompare("@me") == .orderedSame ? viewer : pattern
        guard !pattern.isEmpty else { return false }
        guard pattern.contains("*") else { return candidate.caseInsensitiveCompare(pattern) == .orderedSame }
        return Self.glob(Array(pattern.lowercased()), Array(candidate.lowercased()))
    }

    func age(of date: Date, matches value: String) -> Bool {
        guard let comparison = TriageQueryComparison(age: value) else { return false }
        return comparison.holds(now.timeIntervalSince(date) / 86_400)
    }

    private static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == text[t] {
                p += 1; t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p; mark = t; p += 1
            } else if star >= 0 {
                p = star + 1; mark += 1; t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}

extension PullRequestFacts {
    /// Until check runs are known, a failing rollup is the best evidence.
    var hasFailingRequiredCheck: Bool { checks == .failure || checks == .error }

    func matchesCheck(_ value: String, same: (String?) -> Bool) -> Bool { false }
}
