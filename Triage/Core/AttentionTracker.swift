import Foundation

/// Decides what deserves a notification, so you hear about work once: when
/// it first needs your action, and again only if it leaves and comes back.
/// Pure and persisted per organization; posting is `AttentionNotifier`'s job.
struct AttentionTracker: Codable, Equatable, Sendable {
    /// Items already announced as needing action.
    private(set) var announced: Set<String> = []
    /// Items present when tracking began but not yet analyzed; their first
    /// decision is not news.
    private(set) var awaitingFirstDecision: Set<String> = []
    private(set) var lastFollowUpReminder: Date?
    private(set) var isSeeded = false

    /// Records the workspace and returns entries that newly need your action.
    /// The first call only takes a baseline, so installing Triage or adding an
    /// organization never floods Notification Center.
    mutating func update(with presentation: WorkspacePresentation) -> [TriageEntry] {
        let all = presentation.allEntries
        guard !all.isEmpty else { return [] }
        let needsAction = presentation.entries(in: .inbox).filter { $0.decision?.disposition == .act }
        let actIDs = Set(needsAction.map(\.id.rawValue))
        guard isSeeded else {
            isSeeded = true
            announced = actIDs
            awaitingFirstDecision = Set(all.filter { $0.decision == nil }.map(\.id.rawValue))
            return []
        }
        let decided = Set(all.filter { $0.decision != nil }.map(\.id.rawValue))
        let quiet = awaitingFirstDecision.intersection(decided)
        awaitingFirstDecision.subtract(decided)
        awaitingFirstDecision.formIntersection(all.map(\.id.rawValue))
        let fresh = needsAction.filter { !announced.contains($0.id.rawValue) && !quiet.contains($0.id.rawValue) }
        // Forget items that stopped needing action, so their return is news.
        announced = actIDs
        return fresh
    }

    /// Whether to remind about overdue follow-ups: at most once a day.
    mutating func followUpReminderDue(count: Int, now: Date, calendar: Calendar = .current) -> Bool {
        guard count > 0 else { return false }
        if let last = lastFollowUpReminder, calendar.isDate(last, inSameDayAs: now) { return false }
        lastFollowUpReminder = now
        return true
    }
}

/// Hours when Triage stays silent. `start == end` means all day.
struct QuietHours: Equatable, Sendable {
    let start: Int
    let end: Int

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if start == end { return true }
        return start < end ? (start..<end).contains(hour) : hour >= start || hour < end
    }
}
