import Foundation

/// The AI-first presentation of one workspace. Pure value derived from the
/// store's entries and the engine's status; views never sort or filter raw
/// items themselves.
struct WorkspacePresentation: Equatable, Sendable {
    enum Section: String, CaseIterable, Identifiable, Sendable {
        /// Copilot says the user should act or review. The product's front door.
        case inbox
        /// The next move belongs to someone else.
        case waiting
        /// Informational; Copilot found nothing for the user to do.
        case informational
        /// Copilot's queue: new work, decided work being re-checked after new
        /// activity or changed preferences, and failures waiting to retry.
        /// Re-checked items also stay in their decided section.
        case analyzing
        /// Hidden until a chosen time, or until someone else responds.
        case snoozed
        /// Marked done, by you or automatically when you handled it on GitHub.
        case done
        /// Hidden by one of the user's mute rules; never analyzed.
        case muted

        var id: String { rawValue }

        var title: String {
            switch self {
            case .inbox: "Inbox"
            case .waiting: "Waiting on Others"
            case .informational: "No Action Needed"
            case .analyzing: "Analyzing"
            case .done: "Done"
            case .snoozed: "Snoozed"
            case .muted: "Muted"
            }
        }

        var systemImage: String {
            switch self {
            case .inbox: "tray.full"
            case .waiting: "hourglass"
            case .informational: "info.circle"
            case .analyzing: "sparkles"
            case .done: "checkmark.circle"
            case .snoozed: "moon.zzz"
            case .muted: "speaker.slash"
            }
        }
    }

    let entries: [Section: [TriageEntry]]
    let status: TriageStatus

    func entries(in section: Section) -> [TriageEntry] { entries[section] ?? [] }
    /// Every entry once (Analyzing overlaps decided sections).
    var allEntries: [TriageEntry] {
        Section.allCases.filter { $0 != .analyzing }.flatMap { entries(in: $0) }
            + entries(in: .analyzing).filter { $0.decision == nil }
    }
    func count(in section: Section) -> Int { entries[section]?.count ?? 0 }

    static let empty = WorkspacePresentation(entries: [:], status: .initial)

    init(entries: [Section: [TriageEntry]], status: TriageStatus) {
        self.entries = entries
        self.status = status
    }

    /// Groups entries. Inbox is ordered by AI priority, then confidence;
    /// other sections by urgency of relationship, then recency.
    init(entries raw: [TriageEntry], status: TriageStatus, now: Date, rules: TriageRules = .empty, viewer: String = "") {
        let digest = rules.digest
        let all = raw.map { entry in
            var entry = rules.apply(to: entry, viewer: viewer)
            // Decided under different preferences: queued for re-analysis.
            if entry.analysis == .current, let decision = entry.decision, (decision.rulesDigest ?? "") != digest {
                entry.analysis = .pending
            }
            return entry
        }
        var grouped: [Section: [TriageEntry]] = [:]
        for entry in all {
            grouped[Self.section(for: entry, now: now, viewer: viewer), default: []].append(entry)
        }
        grouped[.analyzing] = all.filter {
            $0.analysis != .current && $0.isVisible(at: now, viewer: viewer) && !$0.isMuted
        }
        for (section, values) in grouped {
            grouped[section] = switch section {
            case .inbox: values.sorted(by: Self.priorityOrder)
            // Most recently finished first; soonest to return first.
            case .done: values.sorted { (WorkInsights.doneDate($0) ?? .distantPast) > (WorkInsights.doneDate($1) ?? .distantPast) }
            case .snoozed: values.sorted { (Self.snoozedUntil($0) ?? .distantFuture) < (Self.snoozedUntil($1) ?? .distantFuture) }
            default: values.sorted(by: Self.urgencyOrder)
            }
        }
        self.init(entries: grouped, status: status)
    }

    static func snoozedUntil(_ entry: TriageEntry) -> Date? {
        if case .snoozed(let until) = entry.local { return until }
        return nil
    }

    static func section(for entry: TriageEntry, now: Date, viewer: String = "") -> Section {
        guard entry.isVisible(at: now, viewer: viewer) else {
            if case .snoozed = entry.local { return .snoozed }
            return .done
        }
        guard !entry.isMuted else { return .muted }
        // A previous decision keeps the item in its section while changed
        // facts are re-analyzed, so the Inbox does not flicker.
        guard let decision = entry.decision else { return .analyzing }
        return section(for: decision.disposition)
    }

    private static func section(for disposition: TriageDisposition) -> Section {
        switch disposition {
        case .act, .review: .inbox
        case .wait: .waiting
        case .none: .informational
        }
    }

    private static func priorityOrder(_ lhs: TriageEntry, _ rhs: TriageEntry) -> Bool {
        let left = lhs.decision, right = rhs.decision
        if left?.disposition != right?.disposition { return left?.disposition == .act }
        if left?.priority != right?.priority { return (left?.priority ?? 0) > (right?.priority ?? 0) }
        if left?.confidence != right?.confidence { return (left?.confidence ?? 0) > (right?.confidence ?? 0) }
        return lhs.item.updatedAt > rhs.item.updatedAt
    }

    private static func urgencyOrder(_ lhs: TriageEntry, _ rhs: TriageEntry) -> Bool {
        let left = lhs.item.primaryRelationship?.urgencyRank ?? .max
        let right = rhs.item.primaryRelationship?.urgencyRank ?? .max
        if left != right { return left < right }
        return lhs.item.updatedAt > rhs.item.updatedAt
    }
}

/// User-selectable list order. `recommended` is Copilot's order: priority in
/// the Inbox, relationship urgency elsewhere.
enum WorkspaceSortField: String, CaseIterable, Identifiable, Sendable {
    case recommended, priority, updated, created, repository, title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: "Recommended"
        case .priority: "Priority"
        case .updated: "Date Updated"
        case .created: "Date Created"
        case .repository: "Repository"
        case .title: "Title"
        }
    }

    /// Natural direction when the field is first chosen.
    var defaultAscending: Bool {
        switch self {
        case .repository, .title: true
        case .recommended, .priority, .updated, .created: false
        }
    }

    var supportsDirection: Bool { self != .recommended }
}

extension WorkspacePresentation {
    func entries(in section: Section, sortedBy field: WorkspaceSortField, ascending: Bool) -> [TriageEntry] {
        let values = entries(in: section)
        guard field != .recommended else { return values }
        return values.sorted { lhs, rhs in
            let order = Self.compare(lhs, rhs, by: field)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            if lhs.item.updatedAt != rhs.item.updatedAt { return lhs.item.updatedAt > rhs.item.updatedAt }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private static func compare(_ lhs: TriageEntry, _ rhs: TriageEntry, by field: WorkspaceSortField) -> ComparisonResult {
        func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
        switch field {
        case .recommended: return .orderedSame
        // Undecided items sort below every decided priority.
        case .priority: return order(lhs.decision?.priority ?? -1, rhs.decision?.priority ?? -1)
        case .updated: return order(lhs.item.updatedAt, rhs.item.updatedAt)
        case .created: return order(lhs.item.createdAt, rhs.item.createdAt)
        case .repository:
            let result = lhs.item.repository.localizedStandardCompare(rhs.item.repository)
            return result == .orderedSame ? order(lhs.item.number, rhs.item.number) : result
        case .title: return lhs.item.title.localizedStandardCompare(rhs.item.title)
        }
    }
}

/// Actions a workspace view can request. Implemented by the app model.
@MainActor
protocol WorkspaceActions: AnyObject {
    func refreshNow()
    func markDone(_ entry: TriageEntry)
    func snooze(_ entry: TriageEntry, until date: Date)
    func restore(_ entry: TriageEntry)
    func openOnGitHub(_ entry: TriageEntry)
    func openCopilotSettings()
    /// Adds a hard rule for the selected organization (quick rules, feedback).
    func addRule(_ rule: TriageRule)
    /// Opens the rule editor prefilled from `entry`. `correcting` (from
    /// "Not right?") suggests moving the item somewhere else.
    func beginRule(from entry: TriageEntry, correcting: Bool)
    func openRulesSettings()
    /// Opens a list, optionally filtered.
    func open(_ destination: WorkspaceDestination, search: WorkspaceSearch)
    /// Works through `entries` one at a time in Focus.
    func startFocus(_ entries: [TriageEntry])
    /// Saves the current search to the sidebar.
    func saveSearch(named name: String)
    /// Selects `entry`, switching to the section that contains it.
    func show(_ entry: TriageEntry)
}
