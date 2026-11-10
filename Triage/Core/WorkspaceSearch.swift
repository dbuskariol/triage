import Foundation

/// A filter chip in the search field. Chips and typed text are one
/// `TriageQuery`: a chip is exactly the qualifier it shows.
struct SearchToken: Identifiable, Hashable, Codable, Sendable {
    typealias Kind = TriageQuery.Qualifier

    let kind: Kind
    let value: String

    init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    var id: String { title }
    var title: String { TriageQuery(.qualifier(kind, value)).description }

    var systemImage: String {
        switch kind {
        case .repo: "folder"
        case .author, .assignee, .commenter, .reviewer: "person"
        case .label: "tag"
        case .team: "person.3"
        case .is, .in: "line.3.horizontal.decrease"
        case .status, .check: "exclamationmark.triangle"
        case .priority: "flag"
        case .effort: "clock"
        case .title, .body, .comment: "text.magnifyingglass"
        case .updated, .created: "calendar"
        case .size: "plusminus"
        case .signal: "sparkles"
        case .topic: "number"
        }
    }

    /// Fixed values per qualifier, with descriptions for menus and suggestions.
    static var knownValues: [Kind: [(String, String)]] {
        Dictionary(uniqueKeysWithValues: Kind.allCases.compactMap { kind in
            kind.knownValues.map { (kind, $0.map { ($0.value, $0.title) }) }
        })
    }

    func matches(_ entry: TriageEntry, viewer: String) -> Bool {
        (try? TriageQuery(parsing: title))?.matches(entry, viewer: viewer) == true
    }
}

/// The workspace search: typed query text plus chips, within one section or all work.
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

    /// The chips and typed text as one query string.
    var queryText: String {
        (tokens.map(\.title) + [text.trimmingCharacters(in: .whitespaces)]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The query in canonical form when valid, otherwise as typed.
    var canonicalQueryText: String {
        if case .success(let query?) = query { query.description } else { queryText }
    }

    /// A short description for naming a saved search.
    var summary: String { queryText }

    /// The compiled query; `nil` when the search is empty.
    var query: Result<TriageQuery?, TriageQueryError> {
        let text = queryText
        guard !text.isEmpty else { return .success(nil) }
        do { return .success(try TriageQuery(parsing: text)) } catch { return .failure(error) }
    }

    /// What's wrong with the typed text, if anything. Shown under the field.
    var error: TriageQueryError? {
        if case .failure(let error) = query { error } else { nil }
    }

    /// `error`, unless it is in the word still being typed.
    var visibleError: TriageQueryError? {
        guard let error else { return nil }
        guard text.last.map({ !$0.isWhitespace }) == true, let range = text.range(of: #"\S+$"#, options: .regularExpression) else { return error }
        let typingStart = queryText.count - text.distance(from: range.lowerBound, to: text.endIndex)
        return error.position >= typingStart ? nil : error
    }

    /// An invalid search matches nothing, so a typo never shows everything.
    func matches(_ entry: TriageEntry, viewer: String, now: Date = .now) -> Bool {
        switch query {
        case .success(let query?): query.matches(entry, viewer: viewer, now: now)
        case .success(nil): true
        case .failure: false
        }
    }

    /// Kinds whose values come from current work.
    static let dynamicKinds: [SearchToken.Kind] = [.repo, .author, .label, .team, .assignee, .commenter, .reviewer]

    /// Suggestions for the word being typed: matching repositories, people,
    /// labels, teams, and known filter values. Empty text offers common filters.
    func suggestions(from entries: [TriageEntry], limit: Int = 8) -> [SearchToken] {
        let typed = text.last?.isWhitespace == true ? "" : (Self.lastWord(text) ?? "")
        let applied = Set(tokens)
        guard !typed.isEmpty else {
            let common: [(SearchToken.Kind, String)] = [
                (.in, "action"), (.is, "direct"), (.is, "team"), (.status, "conflicts"),
                (.status, "failing"), (.priority, "high"),
            ]
            return common.map { SearchToken(kind: $0.0, value: $0.1) }.filter { !applied.contains($0) }
        }
        var kind: SearchToken.Kind?
        var fragment = typed.hasPrefix("-") ? String(typed.dropFirst()) : typed
        if let colon = fragment.firstIndex(of: ":") {
            kind = SearchToken.Kind(rawValue: fragment[..<colon].lowercased())
            guard kind != nil else { return [] }
            fragment = String(fragment[fragment.index(after: colon)...]).replacingOccurrences(of: "\"", with: "")
        }
        func candidates(_ kind: SearchToken.Kind) -> [String] {
            if let known = kind.knownValues { return known.map(\.value) }
            return entries.flatMap { Self.values(of: kind, in: $0.item) }
        }
        let kinds = kind.map { [$0] } ?? Self.dynamicKinds + [.is, .status, .in]
        var seen = Set<SearchToken>()
        var results: [SearchToken] = []
        for kind in kinds {
            var counts: [String: Int] = [:]
            for value in candidates(kind) where fragment.isEmpty || value.localizedCaseInsensitiveContains(fragment) {
                counts[value, default: 0] += 1
            }
            let ordered = kind.knownValues != nil
                ? (kind.knownValues ?? []).map(\.value).filter { counts[$0] != nil }
                : counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).map(\.key)
            for value in ordered {
                let token = SearchToken(kind: kind, value: value)
                if !applied.contains(token), seen.insert(token).inserted { results.append(token) }
            }
        }
        return Array(results.prefix(limit))
    }

    /// Values of a people, place, or label qualifier present on `item`.
    static func values(of kind: SearchToken.Kind, in item: PersonalWorkItem) -> [String] {
        let facts = item.pullRequest
        return switch kind {
        case .repo: [item.repository.split(separator: "/").last.map(String.init) ?? item.repository]
        case .author: item.author.map { [$0] } ?? []
        case .label: item.labels
        case .team: (facts?.requestedReviewers ?? []).filter { $0.contains("/") }
        case .assignee: item.assignees
        case .commenter: Array(Set(item.recentActivity.map(\.author)))
        case .reviewer: Array(Set((facts?.latestReviews ?? []).map(\.author) + (facts?.requestedReviewers ?? []).filter { !$0.contains("/") }))
        default: []
        }
    }

    /// The text with the word being typed removed, used when a suggestion
    /// becomes a token.
    var textWithoutLastWord: String {
        guard let range = text.range(of: #"\S+$"#, options: .regularExpression) else { return text }
        return String(text[..<range.lowerBound])
    }

    private static func lastWord(_ text: String) -> String? {
        text.range(of: #"\S+$"#, options: .regularExpression).map { String(text[$0]) }
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
        let rows = sections.flatMap { entries(in: $0, sortedBy: field, ascending: ascending) }
        switch search.query {
        case .success(let query?):
            let now = Date.now
            return rows.filter { query.matches($0, viewer: viewer, now: now) }
        case .success(nil): return rows
        case .failure: return []
        }
    }

    func section(containing entry: TriageEntry) -> Section? {
        Section.allCases.first { $0 != .analyzing && entries(in: $0).contains { $0.id == entry.id } }
    }
}
