import Foundation

/// One thing the user did that says how well Triage judged an item. Kept
/// locally (encrypted, 90 days) to suggest rules; never uploaded. Only
/// aggregates and a few item facts are sent to Copilot, and only when
/// rule suggestions are requested.
struct TriageFeedback: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// "Not right?" on a recommendation.
        case notRight
        /// Marked done without ever opening it.
        case doneUnopened
        /// Marked done within moments of opening something Copilot said needs action.
        case doneQuickly
        case snoozed
        case muted
        /// Sat unopened in the Inbox for a week.
        case ignoredInInbox
        /// A rule was created; `detail` holds its action and query.
        case ruleCreated
        case ruleDeleted

        var title: String {
            switch self {
            case .notRight: "Said a recommendation wasn't right"
            case .doneUnopened: "Marked done without opening"
            case .doneQuickly: "Marked done right after opening"
            case .snoozed: "Snoozed"
            case .muted: "Muted"
            case .ignoredInInbox: "Left unopened in the Inbox for a week"
            case .ruleCreated: "Created a rule"
            case .ruleDeleted: "Deleted a rule"
            }
        }

        /// Whether this outcome suggests the user doesn't want to see work like it.
        var isDismissive: Bool {
            switch self {
            case .notRight, .doneUnopened, .doneQuickly, .muted, .ignoredInInbox: true
            case .snoozed, .ruleCreated, .ruleDeleted: false
            }
        }
    }

    /// The facts about an item that rules can use, as they were at the time.
    struct Snapshot: Codable, Equatable, Hashable, Sendable {
        var repository: String
        var author: String?
        var labels: [String]
        var isPullRequest: Bool
        var isDraft: Bool
        var relationships: [String]
        var reviewRequest: String?
        var signals: [String]
        var topics: [String]
        var disposition: String?
        var priority: Int?
        var failingChecks: [String]
        var botCommenters: [String]
        var title: String

        init(_ entry: TriageEntry, viewer: String) {
            let item = entry.item
            repository = item.repository
            author = item.author
            labels = Array(item.labels.prefix(5))
            isPullRequest = item.kind == .pullRequest
            isDraft = item.pullRequest?.isDraft == true
            relationships = item.relationships.map(\.rawValue).sorted()
            reviewRequest = switch item.reviewRequestKind(viewer: viewer) {
            case .direct?: "direct"
            case .team?: "team"
            case nil: nil
            }
            signals = entry.decision?.signals ?? []
            topics = entry.decision?.topics ?? []
            disposition = entry.decision?.disposition.rawValue
            priority = entry.decision?.priority
            failingChecks = Array((item.pullRequest?.checkRuns ?? []).filter { $0.result == .failing }.map(\.name).prefix(3))
            botCommenters = Array(Set(item.recentActivity.map(\.author).filter { $0.hasSuffix("[bot]") }).sorted().prefix(3))
            title = String(item.title.prefix(120))
        }
    }

    static let retention: TimeInterval = 90 * 86_400

    var kind: Kind
    var itemID: GitHubNodeID?
    var at: Date
    var snapshot: Snapshot?
    /// Free detail, e.g. a rule's `action: query`.
    var detail: String?

    static func item(_ kind: Kind, _ entry: TriageEntry, viewer: String, at date: Date) -> TriageFeedback {
        TriageFeedback(kind: kind, itemID: entry.id, at: date, snapshot: Snapshot(entry, viewer: viewer), detail: nil)
    }

    /// What marking `entry` done says about it, if anything.
    static func done(_ entry: TriageEntry, viewer: String, at date: Date) -> TriageFeedback? {
        guard let readAt = entry.readAt else { return item(.doneUnopened, entry, viewer: viewer, at: date) }
        if entry.decision?.disposition == .act, date.timeIntervalSince(readAt) < 120 {
            return item(.doneQuickly, entry, viewer: viewer, at: date)
        }
        return nil
    }

    /// Inbox work never opened in the week since Copilot decided it.
    static func ignored(in presentation: WorkspacePresentation, viewer: String, now: Date) -> [TriageFeedback] {
        presentation.entries(in: .inbox).compactMap { entry in
            guard entry.readAt == nil, let decided = entry.decision?.decidedAt,
                  now.timeIntervalSince(decided) >= 7 * 86_400 else { return nil }
            return item(.ignoredInInbox, entry, viewer: viewer, at: now)
        }
    }
}

/// Local feedback history for one organization.
protocol TriageFeedbackStore: Sendable {
    /// Records events; `ignoredInInbox` is recorded at most once per item.
    func recordFeedback(_ events: [TriageFeedback], scope: WorkspaceScope) async throws
    /// Events since `date`, oldest first.
    func feedback(since date: Date, scope: WorkspaceScope) async throws -> [TriageFeedback]
    func clearFeedback(scope: WorkspaceScope) async throws
    /// Deletes events older than `date`.
    func pruneFeedback(before date: Date, scope: WorkspaceScope) async throws
}
