import Foundation

/// What the content column shows: a list section, the Briefing, the Review,
/// or a saved search.
enum WorkspaceDestination: Hashable, Sendable {
    case section(WorkspacePresentation.Section)
    case briefing
    case review
    case savedSearch(UUID)
}

/// A named search kept in the sidebar.
struct SavedSearch: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var search: WorkspaceSearch
}

/// Saved searches for one organization, kept in user defaults.
struct SavedSearchStore: Sendable {
    let organizationID: OrganizationID

    private var key: String { "savedSearches.\(organizationID.rawValue)" }

    func load(defaults: UserDefaults = .standard) -> [SavedSearch] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedSearch].self, from: data)) ?? []
    }

    func save(_ searches: [SavedSearch], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(searches), forKey: key)
    }
}

/// The Briefing: what needs you, at a glance. Each part draws from the same
/// presentation the lists use, so counts always agree.
struct WorkspaceBriefing: Sendable {
    struct Part: Identifiable, Sendable {
        enum Kind: String, Sendable {
            case needsAction, waitingOnYou, quickWins, followUps, newToday, handledToday
        }

        let kind: Kind
        let entries: [TriageEntry]
        var id: Kind { kind }

        var title: String {
            switch kind {
            case .needsAction: "Needs Your Action"
            case .waitingOnYou: "Waiting on You Longest"
            case .quickWins: "Quick Wins"
            case .followUps: "Follow Up"
            case .newToday: "New Since Yesterday"
            case .handledToday: "Handled Today"
            }
        }

        var systemImage: String {
            switch kind {
            case .needsAction: "exclamationmark.circle"
            case .waitingOnYou: "hourglass.bottomhalf.filled"
            case .quickWins: "bolt"
            case .followUps: "arrowshape.turn.up.right"
            case .newToday: "sparkle"
            case .handledToday: "checkmark.circle"
            }
        }

        var footer: String {
            switch kind {
            case .needsAction: "Someone is blocked on you or asked you directly."
            case .waitingOnYou: "In your Inbox the longest since anyone else moved them."
            case .quickWins: "Copilot estimates each takes under 5 minutes."
            case .followUps: "Waiting on others with no movement. Consider a nudge."
            case .newToday: "Arrived or changed in the last day."
            case .handledToday: "Marked done today, including work you handled on GitHub."
            }
        }
    }

    static let partLimit = 5

    let parts: [Part]
    let needsActionCount: Int
    let quickWinCount: Int
    let followUpCount: Int

    init(presentation: WorkspacePresentation, viewer: String, followUpDays: Int, now: Date) {
        let inbox = presentation.entries(in: .inbox)
        let needsAction = inbox.filter { $0.decision?.disposition == .act }
            .sorted { ($0.decision?.priority ?? 0) > ($1.decision?.priority ?? 0) }
        let waiting = inbox.sorted {
            WorkInsights.waitingOnYouSince($0.item, viewer: viewer) < WorkInsights.waitingOnYouSince($1.item, viewer: viewer)
        }
        let quick = inbox.filter { $0.decision?.effort == .quick }
            .sorted { ($0.decision?.priority ?? 0) > ($1.decision?.priority ?? 0) }
        let followUps = WorkInsights.overdueFollowUps(in: presentation, days: followUpDays, now: now)
        let dayAgo = now.addingTimeInterval(-86_400)
        let fresh = (inbox + presentation.entries(in: .waiting))
            .filter { $0.item.createdAt >= dayAgo || $0.item.updatedAt >= dayAgo }
            .sorted { $0.item.updatedAt > $1.item.updatedAt }
        let startOfDay = Calendar.current.startOfDay(for: now)
        let handled = presentation.entries(in: .handled)
            .filter { (WorkInsights.doneDate($0) ?? .distantPast) >= startOfDay }
            .sorted { (WorkInsights.doneDate($0) ?? .distantPast) > (WorkInsights.doneDate($1) ?? .distantPast) }

        parts = [
            Part(kind: .needsAction, entries: needsAction),
            Part(kind: .waitingOnYou, entries: waiting),
            Part(kind: .quickWins, entries: quick),
            Part(kind: .followUps, entries: followUps),
            Part(kind: .newToday, entries: fresh),
            Part(kind: .handledToday, entries: handled),
        ].filter { !$0.entries.isEmpty }
        needsActionCount = needsAction.count
        quickWinCount = quick.count
        followUpCount = followUps.count
    }

    /// Rows in display order, for keyboard navigation.
    var orderedEntries: [TriageEntry] {
        var seen = Set<GitHubNodeID>()
        return parts.flatMap { $0.entries.prefix(Self.partLimit) }.filter { seen.insert($0.id).inserted }
    }
}

/// The weekly Review: what you got through, and what's slipping.
struct WorkspaceReview: Sendable {
    struct Day: Identifiable, Sendable {
        let date: Date
        let handledByYou: Int
        let done: Int
        var id: Date { date }
    }

    struct RepositoryCount: Identifiable, Sendable {
        let repository: String
        let count: Int
        var id: String { repository }
    }

    let days: [Day]
    let handledThisWeek: Int
    let handledByYouThisWeek: Int
    let inboxCount: Int
    let medianWaitingOnYouDays: Int?
    let byRepository: [RepositoryCount]
    let stale: [TriageEntry]
    let longestWaiting: [TriageEntry]

    static let staleDays = 14

    init(presentation: WorkspacePresentation, viewer: String, now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let done = presentation.entries(in: .handled).compactMap { entry in
            WorkInsights.doneDate(entry).map { (date: $0, byYou: entry.handledEvidence != nil) }
        }
        days = starts.map { start in
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            let inDay = done.filter { $0.date >= start && $0.date < end }
            return Day(date: start, handledByYou: inDay.filter(\.byYou).count, done: inDay.filter { !$0.byYou }.count)
        }
        handledThisWeek = days.reduce(0) { $0 + $1.done + $1.handledByYou }
        handledByYouThisWeek = days.reduce(0) { $0 + $1.handledByYou }

        let inbox = presentation.entries(in: .inbox)
        inboxCount = inbox.count
        let waits = inbox.map { WorkInsights.days(since: WorkInsights.waitingOnYouSince($0.item, viewer: viewer), now: now) }.sorted()
        medianWaitingOnYouDays = waits.isEmpty ? nil : waits[waits.count / 2]

        let open = inbox + presentation.entries(in: .waiting)
        var counts: [String: Int] = [:]
        for entry in open { counts[entry.item.repository, default: 0] += 1 }
        byRepository = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6).map { RepositoryCount(repository: $0.key, count: $0.value) }

        let staleCutoff = now.addingTimeInterval(-TimeInterval(Self.staleDays) * 86_400)
        stale = open.filter { $0.item.updatedAt < staleCutoff }.sorted { $0.item.updatedAt < $1.item.updatedAt }
        longestWaiting = inbox.sorted {
            WorkInsights.waitingOnYouSince($0.item, viewer: viewer) < WorkInsights.waitingOnYouSince($1.item, viewer: viewer)
        }
    }

    var orderedEntries: [TriageEntry] {
        var seen = Set<GitHubNodeID>()
        return (longestWaiting.prefix(5) + stale.prefix(5)).filter { seen.insert($0.id).inserted }
    }
}
