import Foundation

/// Local changes shown immediately, before the store confirms them: Done,
/// Snooze, and Restore, and read or unread.
struct OptimisticChanges: Equatable, Sendable {
    private(set) var local: [GitHubNodeID: LocalStatus] = [:]
    /// `nil` marks unread.
    private(set) var readAt: [GitHubNodeID: Date?] = [:]

    var isEmpty: Bool { local.isEmpty && readAt.isEmpty }

    mutating func set(_ status: LocalStatus?, for id: GitHubNodeID) { local[id] = status }
    mutating func setRead(_ date: Date?, for id: GitHubNodeID) { readAt[id] = .some(date) }
    mutating func clearRead(for id: GitHubNodeID) { readAt[id] = nil }

    func apply(to entries: [TriageEntry]) -> [TriageEntry] {
        guard !isEmpty else { return entries }
        return entries.map { entry in
            var entry = entry
            if let status = local[entry.id] { entry.local = status }
            if let date = readAt[entry.id] { entry.readAt = date }
            return entry
        }
    }

    /// Drops changes the store now reflects.
    mutating func dropConfirmed(by entries: [TriageEntry]) {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        local = local.filter { id, status in byID[id]?.local != status }
        readAt = readAt.filter { id, date in
            let stored = byID[id]?.readAt
            guard let date else { return stored != nil }
            // The store keeps milliseconds; allow for rounding.
            return (stored ?? .distantPast) < date.addingTimeInterval(-0.001)
        }
    }
}
