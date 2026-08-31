import Foundation
import GRDB

/// Read-only, local detail data. This repository never schedules a refresh or
/// contacts GitHub: it presents only data already normalized in the encrypted
/// account vault.
actor WorkDetailRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func source(for item: WorkItem) async throws -> WorkDetailSource? {
        try Task.checkCancellation()
        guard item.accountID == vault.accountID else { return nil }
        let source: WorkDetailSource? = try await vault.read { database -> WorkDetailSource? in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT body_markdown, source_revision, updated_at_ms, last_observed_at_ms
                    FROM github_nodes
                    WHERE github_node_id = ? AND account_id = ? AND organization_id = ?
                    """,
                arguments: [
                    item.primaryNodeID.rawValue,
                    item.accountID.rawValue,
                    item.organizationID.rawValue
                ]
            ),
            let sourceRevision: String = row["source_revision"],
            let updatedAtMilliseconds: Int64 = row["updated_at_ms"],
            let observedAtMilliseconds: Int64 = row["last_observed_at_ms"]
            else { return nil }
            return WorkDetailSource(
                bodyMarkdown: row["body_markdown"],
                sourceRevision: sourceRevision,
                updatedAt: Self.date(updatedAtMilliseconds),
                observedAt: Self.date(observedAtMilliseconds)
            )
        }
        try Task.checkCancellation()
        return source
    }

    /// Fetches one bounded page from the normalized local timeline. The
    /// cursor is a stable `(occurredAt, GitHub event ID)` tuple so events that
    /// share a timestamp are neither skipped nor repeated between pages.
    func timelinePage(
        for item: WorkItem,
        after cursor: WorkDetailTimelineCursor?,
        limit: Int
    ) async throws -> WorkDetailTimelinePage {
        try Task.checkCancellation()
        guard item.accountID == vault.accountID, limit > 0 else {
            return WorkDetailTimelinePage(entries: [], nextCursor: nil)
        }
        let page = try await vault.read { database in
            let cursorArguments: [DatabaseValueConvertible?]
            let predicate: String
            if let cursor {
                predicate = """
                    AND (occurred_at_ms > ? OR (occurred_at_ms = ? AND github_event_id > ?))
                    """
                cursorArguments = [
                    Self.milliseconds(cursor.occurredAt),
                    Self.milliseconds(cursor.occurredAt),
                    cursor.eventID.rawValue
                ]
            } else {
                predicate = ""
                cursorArguments = []
            }
            var arguments: [DatabaseValueConvertible?] = [item.primaryNodeID.rawValue]
            arguments.append(contentsOf: cursorArguments)
            arguments.append(limit + 1)
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT github_event_id, occurred_at_ms, payload_json, source_revision
                    FROM timeline_events
                    WHERE subject_node_id = ?
                    \(predicate)
                    ORDER BY occurred_at_ms ASC, github_event_id ASC
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments)
            )
            let decoded = try rows.map { row -> WorkDetailTimelineEntry in
                guard let eventID: String = row["github_event_id"],
                      let occurredAtMilliseconds: Int64 = row["occurred_at_ms"],
                      let payload: Data = row["payload_json"],
                      let sourceRevision: String = row["source_revision"]
                else { throw WorkDetailRepositoryError.invalidTimelineRecord }
                let event = try JSONDecoder().decode(TimelineEventSummary.self, from: payload)
                guard event.id.rawValue == eventID,
                      event.subjectNodeID == item.primaryNodeID,
                      Self.milliseconds(event.occurredAt) == occurredAtMilliseconds
                else { throw WorkDetailRepositoryError.invalidTimelineRecord }
                return WorkDetailTimelineEntry(event: event, sourceRevision: sourceRevision)
            }
            let pageEntries = Array(decoded.prefix(limit))
            let nextCursor = decoded.count > limit ? pageEntries.last.map {
                WorkDetailTimelineCursor(occurredAt: $0.event.occurredAt, eventID: $0.event.id)
            } : nil
            return WorkDetailTimelinePage(entries: pageEntries, nextCursor: nextCursor)
        }
        try Task.checkCancellation()
        return page
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

enum WorkDetailRepositoryError: Error, Equatable, Sendable {
    case invalidTimelineRecord
}

struct WorkDetailSource: Equatable, Sendable {
    let bodyMarkdown: String?
    let sourceRevision: String
    let updatedAt: Date
    let observedAt: Date
}

struct WorkDetailTimelineCursor: Equatable, Sendable {
    let occurredAt: Date
    let eventID: GitHubEventID
}

struct WorkDetailTimelineEntry: Equatable, Sendable, Identifiable {
    let event: TimelineEventSummary
    let sourceRevision: String

    var id: GitHubEventID { event.id }
}

struct WorkDetailTimelinePage: Equatable, Sendable {
    let entries: [WorkDetailTimelineEntry]
    let nextCursor: WorkDetailTimelineCursor?
}
