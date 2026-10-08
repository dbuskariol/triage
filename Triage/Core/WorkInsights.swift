import Foundation

/// Facts derived from saved work, shared by the Briefing, Review, grouping,
/// follow-ups, and notifications so each is computed one way.
enum WorkInsights {
    // MARK: Related items

    /// `owner/repo#number` references in an item's description and recent
    /// comments, from `#123`, `owner/repo#123`, and GitHub URLs.
    static func references(in item: PersonalWorkItem) -> Set<String> {
        let text = ([item.body] + item.recentActivity.map(\.excerpt)).joined(separator: "\n")
        let ownRepository = item.repository.lowercased()
        var found = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        for match in urlPattern.matches(in: text, range: range) {
            guard let repository = substring(text, match.range(at: 1)),
                  let number = substring(text, match.range(at: 2))
            else { continue }
            found.insert("\(repository.lowercased())#\(number)")
        }
        for match in shorthandPattern.matches(in: text, range: range) {
            guard let number = substring(text, match.range(at: 2)) else { continue }
            let repository = substring(text, match.range(at: 1))?.lowercased() ?? ownRepository
            found.insert("\(repository)#\(number)")
        }
        found.remove("\(ownRepository)#\(item.number)")
        return found
    }

    /// For each entry, the other entries it references or that reference it.
    static func relatedEntries(_ entries: [TriageEntry]) -> [GitHubNodeID: [TriageEntry]] {
        var byReference: [String: TriageEntry] = [:]
        for entry in entries { byReference[key(entry.item)] = entry }
        var related: [GitHubNodeID: [GitHubNodeID: TriageEntry]] = [:]
        for entry in entries {
            for reference in references(in: entry.item) {
                guard let other = byReference[reference], other.id != entry.id else { continue }
                related[entry.id, default: [:]][other.id] = other
                related[other.id, default: [:]][entry.id] = entry
            }
        }
        return related.mapValues { $0.values.sorted { $0.item.updatedAt > $1.item.updatedAt } }
    }

    static func key(_ item: PersonalWorkItem) -> String {
        "\(item.repository.lowercased())#\(item.number)"
    }

    // MARK: Waiting

    /// How long the next move has been with `viewer`: since the latest
    /// activity by someone else (or creation).
    static func waitingOnYouSince(_ item: PersonalWorkItem, viewer: String) -> Date {
        item.latestActivity(excluding: viewer) ?? item.createdAt
    }

    /// How long the viewer has been waiting on others: since the last update.
    static func waitingOnOthersSince(_ item: PersonalWorkItem) -> Date {
        item.updatedAt
    }

    /// Waiting-on-others work with no movement for at least `days`.
    static func overdueFollowUps(in presentation: WorkspacePresentation, days: Int, now: Date) -> [TriageEntry] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return presentation.entries(in: .waiting)
            .filter { waitingOnOthersSince($0.item) <= cutoff }
            .sorted { waitingOnOthersSince($0.item) < waitingOnOthersSince($1.item) }
    }

    static func days(since date: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    // MARK: Done history

    /// When an entry was marked done, if it was.
    static func doneDate(_ entry: TriageEntry) -> Date? {
        if case .done(_, let at, _) = entry.local { return at }
        return nil
    }

    // MARK: Private

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https://github\.com/([A-Za-z0-9-]+/[A-Za-z0-9._-]+)/(?:issues|pull)/(\d+)"#
    )
    private static let shorthandPattern = try! NSRegularExpression(
        pattern: #"(?<![\w/#])(?:([A-Za-z0-9-]+/[A-Za-z0-9._-]+))?#(\d{1,7})\b"#
    )

    private static func substring(_ text: String, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}

/// How the list can be grouped. Grouping is additive: the same rows, in the
/// same order within each group.
enum WorkspaceGrouping: String, CaseIterable, Identifiable, Sendable {
    case none, effort, repository, relationship

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .effort: "Effort"
        case .repository: "Repository"
        case .relationship: "Why It's Yours"
        }
    }

    /// Ordered groups of `entries`, keeping their order within each group.
    func groups(_ entries: [TriageEntry]) -> [(title: String, entries: [TriageEntry])] {
        guard self != .none else { return [("", entries)] }
        var order: [String] = []
        var groups: [String: [TriageEntry]] = [:]
        for entry in entries {
            let title = groupTitle(entry)
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(entry)
        }
        if self == .effort {
            let rank = Dictionary(uniqueKeysWithValues: (TriageEffort.allCases.map(\.title) + ["Not estimated"]).enumerated().map { ($1, $0) })
            order.sort { (rank[$0] ?? 99) < (rank[$1] ?? 99) }
        } else if self == .repository {
            order.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        } else if self == .relationship {
            let rank = Dictionary(uniqueKeysWithValues: WorkRelationship.allCases.map { ($0.title, $0.urgencyRank) })
            order.sort { (rank[$0] ?? 99) < (rank[$1] ?? 99) }
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func groupTitle(_ entry: TriageEntry) -> String {
        switch self {
        case .none: ""
        case .effort: entry.decision?.effort?.title ?? "Not estimated"
        case .repository: entry.item.repository
        case .relationship: entry.item.primaryRelationship?.title ?? "Related to you"
        }
    }
}
