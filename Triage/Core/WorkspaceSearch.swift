import Foundation

/// A filter chip in the search field, or a GitHub-style `key:value` qualifier
/// typed as text. Both match the same way.
struct SearchToken: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case repo, author, label, team, `is`, status, priority, effort
    }

    let kind: Kind
    let value: String

    var id: String { "\(kind.rawValue):\(value)" }
    var title: String { "\(kind.rawValue):\(value)" }

    var systemImage: String {
        switch kind {
        case .repo: "folder"
        case .author: "person"
        case .label: "tag"
        case .team: "person.3"
        case .is: "line.3.horizontal.decrease"
        case .status: "exclamationmark.triangle"
        case .priority: "flag"
        case .effort: "clock"
        }
    }

    /// Accepted `is:`, `status:`, and `priority:` values, with descriptions for suggestions.
    static let knownValues: [Kind: [(String, String)]] = [
        .is: [
            ("pr", "Pull requests"), ("issue", "Issues"), ("discussion", "Discussions"), ("draft", "Draft pull requests"),
            ("review", "Review requested"), ("direct", "Review requested from you directly"),
            ("team", "Review requested from your team only"), ("assigned", "Assigned to you"),
            ("mine", "Opened by you"), ("mentioned", "Mentions you"), ("action", "Needs your action"),
            ("unread", "Unread"), ("read", "Read"),
        ],
        .status: [
            ("conflicts", "Has conflicts"), ("failing", "Checks failing"),
            ("approved", "Approved"), ("changes", "Changes requested"),
        ],
        .priority: [("high", "High priority"), ("medium", "Medium priority"), ("low", "Low priority")],
        .effort: TriageEffort.allCases.map { ($0.rawValue, "\($0.title) · \($0.detail)") },
    ]

    func matches(_ entry: TriageEntry, viewer: String) -> Bool {
        let item = entry.item
        let facts = item.pullRequest
        func contains(_ text: String?) -> Bool { text?.localizedCaseInsensitiveContains(value) == true }
        switch kind {
        case .repo: return contains(item.repository)
        case .author: return contains(item.author)
        case .label: return item.labels.contains { contains($0) }
        case .team: return (facts?.requestedReviewers ?? []).contains { $0.contains("/") && contains($0) }
        case .is:
            switch value.lowercased() {
            case "pr": return item.kind == .pullRequest
            case "issue": return item.kind == .issue
            case "discussion": return item.kind == .discussion
            case "draft": return facts?.isDraft == true
            case "review": return item.relationships.contains(.reviewRequested)
            case "direct": return item.reviewRequestKind(viewer: viewer) == .direct
            case "team": return item.reviewRequestKind(viewer: viewer) == .team
            case "assigned": return item.relationships.contains(.assigned)
            case "mine": return item.relationships.contains(.authored)
            case "mentioned": return item.relationships.contains(.mentioned)
            case "action": return entry.decision?.disposition == .act
            case "unread": return entry.isUnread
            case "read": return !entry.isUnread
            default: return false
            }
        case .status:
            switch value.lowercased() {
            case "conflicts": return facts?.mergeable?.uppercased() == "CONFLICTING"
            case "failing": return facts?.checks == .failure || facts?.checks == .error
            case "approved": return facts?.reviewDecision == .approved
            case "changes": return facts?.reviewDecision == .changesRequested
            default: return false
            }
        case .priority:
            guard let priority = entry.decision?.priority else { return false }
            return PriorityBand(rawValue: value.lowercased()) == PriorityBand(priority)
        case .effort:
            return entry.decision?.effort?.rawValue == value.lowercased()
        }
    }
}

/// The workspace search: free text plus tokens, within one section or all work.
struct WorkspaceSearch: Equatable, Codable, Sendable {
    enum Scope: String, Hashable, Codable, Sendable { case section, all }

    var text = ""
    var tokens: [SearchToken] = []
    var scope = Scope.section

    var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty || !tokens.isEmpty }

    /// This search across all work, narrowed by `other` (a saved search
    /// refined by whatever is typed in the search field).
    func refined(by other: WorkspaceSearch) -> WorkspaceSearch {
        WorkspaceSearch(
            text: [text, other.text].filter { !$0.isEmpty }.joined(separator: " "),
            tokens: tokens + other.tokens.filter { !tokens.contains($0) },
            scope: .all
        )
    }

    /// A short description for naming a saved search.
    var summary: String {
        (tokens.map(\.title) + [text.trimmingCharacters(in: .whitespaces)]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Splits typed text into plain terms and `key:value` qualifiers (quotes
    /// keep phrases together: `"account takeover"`).
    func parsed() -> (terms: [String], tokens: [SearchToken]) {
        var terms: [String] = []
        var qualifiers: [SearchToken] = []
        for word in Self.words(text) {
            if let colon = word.firstIndex(of: ":"),
               let kind = SearchToken.Kind(rawValue: word[..<colon].lowercased()) {
                let value = String(word[word.index(after: colon)...])
                if !value.isEmpty { qualifiers.append(SearchToken(kind: kind, value: value)) }
            } else {
                terms.append(String(word))
            }
        }
        return (terms, tokens + qualifiers)
    }

    func matches(_ entry: TriageEntry, viewer: String) -> Bool {
        let (terms, tokens) = parsed()
        guard tokens.allSatisfy({ $0.matches(entry, viewer: viewer) }) else { return false }
        guard !terms.isEmpty else { return true }
        let item = entry.item
        let fields: [String] = [
            item.title, item.repository, "#\(item.number)", item.author ?? "", item.body,
            item.labels.joined(separator: " "), item.assignees.joined(separator: " "),
            (item.pullRequest?.requestedReviewers ?? []).joined(separator: " "),
            entry.decision?.summary ?? "", entry.decision?.nextAction ?? "", entry.decision?.reason ?? "",
        ]
        return terms.allSatisfy { term in fields.contains { $0.localizedCaseInsensitiveContains(term) } }
    }

    /// Suggestions for the word being typed: matching repositories, authors,
    /// labels, teams, and known qualifier values. Empty text offers common filters.
    func suggestions(from entries: [TriageEntry], limit: Int = 8) -> [SearchToken] {
        let typed = text.last?.isWhitespace == true ? "" : (Self.words(text).last.map(String.init) ?? "")
        let applied = Set(tokens)
        guard !typed.isEmpty else {
            let common: [(SearchToken.Kind, String)] = [
                (.is, "action"), (.is, "direct"), (.is, "team"), (.status, "conflicts"),
                (.status, "failing"), (.priority, "high"),
            ]
            return common.map { SearchToken(kind: $0.0, value: $0.1) }.filter { !applied.contains($0) }
        }
        var kind: SearchToken.Kind?
        var fragment = typed
        if let colon = typed.firstIndex(of: ":") {
            kind = SearchToken.Kind(rawValue: typed[..<colon].lowercased())
            guard kind != nil else { return [] }
            fragment = String(typed[typed.index(after: colon)...])
        }
        func candidates(_ kind: SearchToken.Kind) -> [String] {
            switch kind {
            case .repo: entries.map { $0.item.repository.split(separator: "/").last.map(String.init) ?? $0.item.repository }
            case .author: entries.compactMap(\.item.author)
            case .label: entries.flatMap(\.item.labels)
            case .team: entries.flatMap { ($0.item.pullRequest?.requestedReviewers ?? []).filter { $0.contains("/") } }
            case .is, .status, .priority, .effort: SearchToken.knownValues[kind]?.map(\.0) ?? []
            }
        }
        let kinds = kind.map { [$0] } ?? [.repo, .author, .label, .team, .is, .status]
        var seen = Set<SearchToken>()
        var results: [SearchToken] = []
        for kind in kinds {
            var counts: [String: Int] = [:]
            for value in candidates(kind) where fragment.isEmpty || value.localizedCaseInsensitiveContains(fragment) {
                counts[value, default: 0] += 1
            }
            for value in counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).map(\.key) {
                let token = SearchToken(kind: kind, value: value)
                if !applied.contains(token), seen.insert(token).inserted { results.append(token) }
            }
        }
        return Array(results.prefix(limit))
    }

    /// The text with the word being typed removed, used when a suggestion
    /// becomes a token.
    var textWithoutLastWord: String {
        guard let range = text.range(of: #"\S+$"#, options: .regularExpression) else { return text }
        return String(text[..<range.lowerBound])
    }

    private static func words(_ text: String) -> [Substring] {
        var words: [Substring] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { words.append(Substring(current)); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(Substring(current)) }
        return words
    }
}

/// Narrows the Done section by how the work was finished.
enum DoneFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All", byYou = "Handled by You", marked = "Marked Done"
    var id: Self { self }

    func includes(_ entry: TriageEntry) -> Bool {
        switch self {
        case .all: true
        case .byYou: entry.handledEvidence != nil
        case .marked: entry.handledEvidence == nil
        }
    }
}

extension WorkspacePresentation {
    /// The rows shown in the list, in order. The list view, keyboard
    /// navigation, and "select next after Done" all use this one definition.
    func visibleEntries(
        section: Section, search: WorkspaceSearch, doneFilter: DoneFilter,
        sortedBy field: WorkspaceSortField, ascending: Bool, grouping: WorkspaceGrouping = .none, viewer: String
    ) -> [TriageEntry] {
        let rows: [TriageEntry]
        if search.isActive {
            rows = searchResults(search, section: section, sortedBy: field, ascending: ascending, viewer: viewer)
        } else {
            let sorted = entries(in: section, sortedBy: field, ascending: ascending)
            rows = section == .done ? sorted.filter(doneFilter.includes) : sorted
        }
        // Grouped lists read top to bottom group by group; navigation follows that order.
        return grouping == .none ? rows : grouping.groups(rows).flatMap(\.entries)
    }

    /// Search results in the user's sort order, from the current section or all work.
    func searchResults(
        _ search: WorkspaceSearch, section: Section, sortedBy field: WorkspaceSortField, ascending: Bool, viewer: String
    ) -> [TriageEntry] {
        let sections = search.scope == .all ? Section.allCases.filter { $0 != .analyzing } : [section]
        return sections.flatMap { entries(in: $0, sortedBy: field, ascending: ascending) }
            .filter { search.matches($0, viewer: viewer) }
    }

    func section(containing entry: TriageEntry) -> Section? {
        Section.allCases.first { $0 != .analyzing && entries(in: $0).contains { $0.id == entry.id } }
    }
}
