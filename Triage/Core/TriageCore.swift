import CryptoKit
import Foundation

// MARK: - Scope

/// One signed-in GitHub account looking at one organization. All personal
/// work, AI decisions, and local state are partitioned by this value.
struct WorkspaceScope: Hashable, Codable, Sendable {
    let accountID: AccountID
    let organizationID: OrganizationID
    /// GitHub organization login used in search qualifiers (`org:<login>`).
    let organizationLogin: String
    /// The signed-in user's GitHub login.
    let viewerLogin: String
}

// MARK: - Personal work (GitHub facts)

enum WorkKind: String, Codable, Sendable {
    case issue
    case pullRequest
}

enum WorkState: String, Codable, Sendable {
    case open
    case closed
    case merged
}

/// Why an item is personally relevant. Each case corresponds to exactly one
/// GitHub search qualifier, so GitHub itself is the authority for the claim.
enum WorkRelationship: String, Codable, Sendable, CaseIterable {
    /// `review-requested:<login>` (direct or via one of the user's teams).
    case reviewRequested
    /// `assignee:<login>`
    case assigned
    /// `author:<login>`
    case authored
    /// `mentions:<login>`
    case mentioned
    /// `commenter:<login>`
    case commented

    /// Lower is more urgent. Orders discovery and AI batches.
    var urgencyRank: Int {
        switch self {
        case .reviewRequested: 0
        case .assigned: 1
        case .authored: 2
        case .mentioned: 3
        case .commented: 4
        }
    }

    var title: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .assigned: "Assigned to you"
        case .authored: "Opened by you"
        case .mentioned: "Mentions you"
        case .commented: "You commented"
        }
    }
}

enum CheckStatus: String, Codable, Sendable {
    case success
    case failure
    case pending
    case error
    case expected
}

enum ReviewDecision: String, Codable, Sendable {
    case approved
    case changesRequested
    case reviewRequired
}

struct ReviewFact: Codable, Equatable, Sendable {
    let author: String
    /// GitHub review state: APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, PENDING.
    let state: String
    let submittedAt: Date?
}

struct PullRequestFacts: Codable, Equatable, Sendable {
    let isDraft: Bool
    let reviewDecision: ReviewDecision?
    /// Logins of requested users, and `org/team-slug` for requested teams.
    let requestedReviewers: [String]
    let latestReviews: [ReviewFact]
    let checks: CheckStatus?
    /// GitHub `mergeable`: MERGEABLE, CONFLICTING, UNKNOWN.
    let mergeable: String?
    let unresolvedReviewThreads: Int
    let additions: Int
    let deletions: Int
    /// The head commit, to tell whether the viewer or someone else pushed last.
    var lastCommitAt: Date? = nil
    var lastCommitAuthors: [String]? = nil
}

struct ActivityFact: Codable, Equatable, Sendable {
    let author: String
    let createdAt: Date
    /// Plain-text excerpt, at most `PersonalWorkItem.maximumExcerptLength` UTF-8 bytes.
    let excerpt: String
}

/// Everything Triage knows about one personally relevant issue or pull
/// request. Built from a single GitHub search response; never hydrated in
/// separate passes.
struct PersonalWorkItem: Identifiable, Codable, Equatable, Sendable {
    static let maximumBodyLength = 4_000
    static let maximumExcerptLength = 600
    static let maximumActivityCount = 5

    /// Keeps Markdown structure (line breaks, lists, headings) but drops HTML
    /// comments such as issue-template hints, trailing spaces, and runs of
    /// blank lines, then truncates to `maximumBytes` UTF-8 bytes.
    static func cleanedMarkdown(_ text: String, maximumBytes: Int) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        value = value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
        value = value.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return truncated(value.trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: maximumBytes)
    }

    static func truncated(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            guard bytes + size <= maximumBytes else { break }
            result.append(character)
            bytes += size
        }
        return result
    }

    let id: GitHubNodeID
    let kind: WorkKind
    /// `owner/name`
    let repository: String
    let number: Int
    let title: String
    let url: URL
    let state: WorkState
    let author: String?
    let createdAt: Date
    let updatedAt: Date
    let relationships: Set<WorkRelationship>
    let labels: [String]
    let assignees: [String]
    /// Cleaned Markdown, truncated to `maximumBodyLength` UTF-8 bytes.
    let body: String
    let pullRequest: PullRequestFacts?
    /// Most recent comments, oldest first, at most `maximumActivityCount`.
    let recentActivity: [ActivityFact]

    var reference: String { "\(repository)#\(number)" }

    enum ReviewRequestKind { case direct, team }

    /// Whether `viewer` was asked to review directly, or only through a team
    /// they belong to. `nil` when there is no review request for them.
    func reviewRequestKind(viewer: String) -> ReviewRequestKind? {
        guard relationships.contains(.reviewRequested) else { return nil }
        let reviewers = pullRequest?.requestedReviewers ?? []
        if !viewer.isEmpty, reviewers.contains(where: { $0.caseInsensitiveCompare(viewer) == .orderedSame }) {
            return .direct
        }
        // GitHub's search says you're requested; if not by name, it was via a team.
        return .team
    }

    /// The newest activity by anyone other than `viewer` (comments, reviews,
    /// the head commit). `nil` when there is none.
    func latestActivity(excluding viewer: String) -> Date? {
        func isViewer(_ login: String) -> Bool { !viewer.isEmpty && login.caseInsensitiveCompare(viewer) == .orderedSame }
        var dates = recentActivity.filter { !isViewer($0.author) }.map(\.createdAt)
        if let facts = pullRequest {
            dates += facts.latestReviews.filter { !isViewer($0.author) }.compactMap(\.submittedAt)
            if let at = facts.lastCommitAt, !(facts.lastCommitAuthors ?? []).contains(where: isViewer) {
                dates.append(at)
            }
        }
        return dates.max()
    }

    /// Plain statements of what `viewer` did after `since`, for Copilot to
    /// judge whether its previous next step was handled.
    func viewerActivity(since: Date, viewer: String) -> [String] {
        guard !viewer.isEmpty else { return [] }
        func isViewer(_ login: String) -> Bool { login.caseInsensitiveCompare(viewer) == .orderedSame }
        func when(_ date: Date) -> String { date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)) }
        var facts: [String] = []
        for comment in recentActivity where isViewer(comment.author) && comment.createdAt > since {
            facts.append("Commented at \(when(comment.createdAt)): \(comment.excerpt.prefix(140))")
        }
        if let pullRequest {
            for review in pullRequest.latestReviews where isViewer(review.author) && (review.submittedAt ?? .distantPast) > since {
                facts.append("Submitted a \(review.state.lowercased().replacingOccurrences(of: "_", with: " ")) review at \(when(review.submittedAt!))")
            }
            if let at = pullRequest.lastCommitAt, at > since, (pullRequest.lastCommitAuthors ?? []).contains(where: isViewer) {
                facts.append("Pushed commits at \(when(at))")
            }
        }
        if state != .open { facts.append("The item is now \(state.rawValue)") }
        return facts.map { String($0.prefix(200)) }
    }

    /// The most urgent relationship, used for ordering.
    var primaryRelationship: WorkRelationship? {
        relationships.min { $0.urgencyRank < $1.urgencyRank }
    }

    /// Stable hash of the decision-relevant facts. A decision is reused only
    /// while this is unchanged.
    var fingerprint: String {
        struct Canonical: Encodable {
            let item: PersonalWorkItem
            let relationships: [String]
            let labels: [String]
            let assignees: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        // `Set` encoding order is unspecified; hash a sorted projection instead.
        let normalized = PersonalWorkItem(
            id: id, kind: kind, repository: repository, number: number, title: title,
            url: url, state: state, author: author, createdAt: createdAt, updatedAt: updatedAt,
            relationships: [], labels: [], assignees: [], body: body,
            pullRequest: pullRequest, recentActivity: recentActivity
        )
        let canonical = Canonical(
            item: normalized,
            relationships: relationships.map(\.rawValue).sorted(),
            labels: labels.sorted(),
            assignees: assignees.sorted()
        )
        let data = (try? encoder.encode(canonical)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - AI decisions

enum TriageDisposition: String, Codable, Sendable, CaseIterable {
    /// The user must act now (review, respond, fix, unblock someone).
    case act
    /// Worth the user's attention soon, but not blocking anyone.
    case review
    /// The next move belongs to someone else.
    case wait
    /// Informational; no action needed.
    case none

    var isInbox: Bool { self == .act || self == .review }
}

/// Copilot priority bands, shared by labels, search, and rules.
enum PriorityBand: String, CaseIterable, Sendable {
    case high, medium, low

    init(_ priority: Int) {
        self = priority >= 70 ? .high : priority >= 40 ? .medium : .low
    }

    var title: String { rawValue.capitalized }
}

struct TriageDecision: Codable, Equatable, Sendable {
    let itemID: GitHubNodeID
    let disposition: TriageDisposition
    /// 0 (lowest) ... 100 (highest)
    let priority: Int
    /// 0 ... 1
    let confidence: Double
    /// One sentence: what this item is about right now.
    let summary: String
    /// One sentence: why it does (or does not) need the user.
    let reason: String
    /// Imperative, concrete next step for the user, when one exists.
    let nextAction: String?
    /// `PersonalWorkItem.fingerprint` of the facts this decision was made from.
    let fingerprint: String
    let modelID: String
    let decidedAt: Date
    /// `TriageRules.digest` the decision was made under; a different digest
    /// means the user's preferences changed and the item is re-analyzed.
    var rulesDigest: String? = nil
    /// How the user's instructions changed this decision, per Copilot.
    var instructionNote: String? = nil
    /// Whether the viewer's activity since the previous decision completed its
    /// next step (only set when there was such activity), with evidence.
    var handled: HandledState? = nil
    var handledEvidence: String? = nil
}

struct TriageHandledContext: Equatable, Sendable {
    let previousNextAction: String
    let viewerActivity: [String]
}

enum HandledState: String, Codable, Sendable {
    case yes, partial, no
}

// MARK: - Local state

/// The user's local handling of an item. Never written back to GitHub.
enum LocalStatus: Codable, Equatable, Sendable {
    case active
    /// Hidden until someone other than the viewer acts on the item after `at`.
    /// `handledEvidence` is set when Triage marked it done because the viewer
    /// handled Copilot's next step. Legacy values without `at` return when the
    /// fingerprint changes.
    case done(fingerprint: String, at: Date? = nil, handledEvidence: String? = nil)
    /// Hidden until the date passes.
    case snoozed(until: Date)
}

enum AnalysisState: Equatable, Sendable {
    /// No decision exists for the current facts yet.
    case pending
    /// The last attempt failed; it will be retried automatically.
    case failed(reason: String, retryAt: Date)
    /// `decision` matches the current facts.
    case current
}

/// One row of the workspace: an item, its latest AI decision, and local state.
struct TriageEntry: Identifiable, Equatable, Sendable {
    let item: PersonalWorkItem
    /// The newest decision, even if it was made from older facts. Once
    /// presented, the user's hard rules have been applied to it.
    var decision: TriageDecision?
    var analysis: AnalysisState
    var local: LocalStatus
    /// Names of the user's rules that matched (set by `TriageRules.apply`).
    var appliedRules: [String] = []
    var isMuted = false

    var id: GitHubNodeID { item.id }

    /// Done work stays hidden until someone *other than* `viewer` acts on it,
    /// so your own follow-up never brings it back.
    func isVisible(at date: Date, viewer: String = "") -> Bool {
        switch local {
        case .active: true
        case .done(let fingerprint, let doneAt, _):
            if let doneAt { (item.latestActivity(excluding: viewer) ?? .distantPast) > doneAt }
            else { fingerprint != item.fingerprint }
        case .snoozed(let until): until <= date
        }
    }

    var handledEvidence: String? {
        if case .done(_, _, let evidence) = local { evidence } else { nil }
    }
}

// MARK: - Engine status

struct TriageStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// Searching GitHub; `found` distinct items so far.
        case searching(found: Int)
        /// Copilot is analyzing; `completed` of `total` items needing analysis.
        case analyzing(completed: Int, total: Int)
    }

    enum Problem: Equatable, Sendable {
        /// Copilot cannot be used; the message says what to fix.
        case copilotUnavailable(String)
        /// GitHub refresh failed; showing saved work.
        case gitHubUnavailable(String)
        /// Some analyses failed; they retry automatically.
        case analysisFailed(String)
    }

    var phase: Phase = .idle
    var problem: Problem?
    var lastRefreshAt: Date?
    var nextRefreshAt: Date?
    /// Items marked done in the last analysis because the viewer handled them.
    var recentlyHandled = 0

    static let initial = TriageStatus()
}

// MARK: - Component contracts

struct DiscoveryProgress: Sendable {
    let relationship: WorkRelationship
    let found: Int
}

/// Finds the signed-in user's relevant open work in one organization.
protocol PersonalWorkDiscovering: Sendable {
    /// Returns every open issue and pull request matched by at least one
    /// personal relationship, merged by node ID with relationships unioned.
    func discover(
        scope: WorkspaceScope,
        progress: @escaping @Sendable (DiscoveryProgress) async -> Void
    ) async throws -> [PersonalWorkItem]
}

/// Encrypted local storage for the workspace.
protocol TriageStore: Sendable {
    /// Upserts `items` and deactivates every other item in `scope` (it no
    /// longer matches a personal search, e.g. closed or unassigned).
    func replaceItems(_ items: [PersonalWorkItem], scope: WorkspaceScope, at date: Date) async throws
    /// Active items with no decision for their current fingerprint whose retry
    /// time (if any) has passed, most urgent first.
    /// Also returns items whose decision was made under a different `rulesDigest`.
    func itemsNeedingAnalysis(
        scope: WorkspaceScope, rulesDigest: String, at date: Date, limit: Int
    ) async throws -> [PersonalWorkItem]
    func saveDecisions(_ decisions: [TriageDecision], scope: WorkspaceScope) async throws
    func recordAnalysisFailure(
        itemIDs: [GitHubNodeID], reason: String, retryAt: Date, scope: WorkspaceScope
    ) async throws
    func setLocalStatus(_ status: LocalStatus, itemID: GitHubNodeID, scope: WorkspaceScope) async throws
    /// Emits all active entries immediately and again whenever they change.
    func entries(scope: WorkspaceScope) async throws -> AsyncThrowingStream<[TriageEntry], Error>
    func lastRefreshAt(scope: WorkspaceScope) async throws -> Date?
    func rules(scope: WorkspaceScope) async throws -> TriageRules
    /// Current decisions for `ids` (any fingerprint).
    func decisions(for ids: [GitHubNodeID], scope: WorkspaceScope) async throws -> [GitHubNodeID: TriageDecision]
    /// Marks an active item done because the viewer handled it. Returns false
    /// (and changes nothing) if the user already set a local status.
    func markHandled(
        itemID: GitHubNodeID, fingerprint: String, evidence: String, at date: Date, scope: WorkspaceScope
    ) async throws -> Bool
    func saveRules(_ rules: TriageRules, scope: WorkspaceScope) async throws
}

/// Makes Copilot triage decisions for one batch of items.
protocol TriageDeciding: Sendable {
    /// Maximum items per request.
    var maximumBatchSize: Int { get }
    /// Returns exactly one decision per input item, or throws.
    /// Decisions carry `rules.digest`. Muted items are never passed in.
    /// `contexts` holds, per item, the previous next step and what the viewer
    /// did since, so the decision can say whether that step was handled.
    func decide(
        _ items: [PersonalWorkItem], scope: WorkspaceScope, rules: TriageRules,
        contexts: [GitHubNodeID: TriageHandledContext]
    ) async throws -> [TriageDecision]
}
