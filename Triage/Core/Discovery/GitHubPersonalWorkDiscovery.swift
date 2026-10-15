import Foundation
import OSLog

enum PersonalWorkDiscoveryError: Error, Equatable, Sendable, LocalizedError {
    case invalidLogin
    case searchUnavailable
    /// The organization uses SAML single sign-on and the token isn't
    /// authorized for it, so GitHub left the organization's work out of search.
    case singleSignOnRequired(organization: String, authorizationURL: URL?)
    /// GitHub refused parts of the search because the token lacks these
    /// permissions (titles from `GitHubTokenRequirements`; empty if unknown).
    case missingTokenPermissions([String])

    var errorDescription: String? {
        switch self {
        case .invalidLogin: "This account or organization name isn't valid for GitHub search."
        case .searchUnavailable: "GitHub search timed out repeatedly. Showing saved work; Triage will try again automatically."
        case .singleSignOnRequired(let organization, _):
            "\(organization) uses SAML single sign-on, and your GitHub token isn't authorized for it. Authorize the token on GitHub, then try again."
        case .missingTokenPermissions(let permissions) where permissions.isEmpty:
            "Your GitHub token is missing a permission Triage needs. Compare it with Settings ▸ Accounts ▸ Replace Token…, then try again."
        case .missingTokenPermissions(let permissions):
            "Your GitHub token is missing read access to \(ListFormatter.localizedString(byJoining: permissions)). Add it to the token on GitHub (the token keeps its value), then try again."
        }
    }
}

protocol PersonalWorkSearchExecuting: Sendable {
    func search(query: String, cursor: String?) async throws -> PersonalWorkSearchPage
}

struct PersonalWorkSearchPage: Decodable, Sendable {
    let search: Search

    struct Search: Decodable, Sendable {
        let pageInfo: PageInfo
        let nodes: [Node?]
    }

    struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct Node: Decodable, Sendable {
        let typename: String
        let id: GitHubNodeID
        let number: Int
        let title: String
        let url: URL
        /// Issues and pull requests. Discussions use `closed` instead.
        let state: String?
        let createdAt: Date
        let updatedAt: Date
        /// GitHub-flavored Markdown source.
        let body: String
        let author: Actor?
        let repository: Repository
        let labels: Names?
        let assignees: Actors?
        let comments: Comments
        /// Discussions only.
        let closed: Bool?
        let category: Category?
        let isDraft: Bool?
        let merged: Bool?
        let reviewDecision: String?
        let mergeable: String?
        let additions: Int?
        let deletions: Int?
        let reviewRequests: ReviewRequests?
        let latestReviews: Reviews?
        let commits: Commits?
        let reviewThreads: Threads?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename", id, number, title, url, state, createdAt, updatedAt, body, author, repository, labels, assignees, comments, closed, category, isDraft, merged, reviewDecision, mergeable, additions, deletions, reviewRequests, latestReviews, commits, reviewThreads
        }
    }

    struct Category: Decodable, Sendable { let name: String }
    struct Actor: Decodable, Sendable { let login: String? }
    struct Repository: Decodable, Sendable { let nameWithOwner: String; let isArchived: Bool }
    struct Names: Decodable, Sendable { let nodes: [Name?] }
    struct Name: Decodable, Sendable { let name: String? }
    struct Actors: Decodable, Sendable { let nodes: [Actor?] }
    struct Comments: Decodable, Sendable { let nodes: [Comment?] }
    struct Comment: Decodable, Sendable { let author: Actor?; let createdAt: Date; let body: String }
    struct ReviewRequests: Decodable, Sendable { let nodes: [ReviewRequest?] }
    struct ReviewRequest: Decodable, Sendable { let requestedReviewer: Reviewer? }
    struct Reviewer: Decodable, Sendable {
        let typename: String
        let login: String?
        let combinedSlug: String?
        enum CodingKeys: String, CodingKey { case typename = "__typename", login, combinedSlug }
    }
    struct Reviews: Decodable, Sendable { let nodes: [Review?] }
    struct Review: Decodable, Sendable { let author: Actor?; let state: String; let submittedAt: Date? }
    struct Commits: Decodable, Sendable { let nodes: [CommitNode?] }
    struct CommitNode: Decodable, Sendable { let commit: Commit? }
    struct Commit: Decodable, Sendable {
        let statusCheckRollup: StatusCheckRollup?
        let committedDate: Date?
        let authors: CommitAuthors?
    }
    struct CommitAuthors: Decodable, Sendable { let nodes: [CommitAuthor?] }
    struct CommitAuthor: Decodable, Sendable { let user: Actor? }
    struct StatusCheckRollup: Decodable, Sendable { let state: String? }
    struct Threads: Decodable, Sendable { let nodes: [Thread?] }
    struct Thread: Decodable, Sendable { let isResolved: Bool }
}

struct GitHubPersonalWorkSearchExecutor: PersonalWorkSearchExecuting {
    private let client: GitHubGraphQLClient
    private let organizationLogin: String
    /// GitHub's numeric organization ID, matched against single sign-on evidence.
    private let organizationDatabaseID: UInt64?

    init(client: GitHubGraphQLClient, organizationLogin: String, organizationDatabaseID: UInt64?) {
        self.client = client
        self.organizationLogin = organizationLogin
        self.organizationDatabaseID = organizationDatabaseID
    }

    func search(query: String, cursor: String?) async throws -> PersonalWorkSearchPage {
        struct Variables: Encodable, Sendable {
            let query: String
            let cursor: String?
            /// `ISSUE` also returns pull requests. Discussions need their own type.
            let searchType: String
        }
        let response = try await client.execute(
            GitHubGraphQLQueries.personalWorkSearch(),
            variables: Variables(
                query: query,
                cursor: cursor,
                searchType: query.contains(" is:discussion ") ? "DISCUSSION" : "ISSUE"
            ),
            as: PersonalWorkSearchPage.self
        )
        try Self.checkSingleSignOn(
            response.metadata.ssoHeader, organizationLogin: organizationLogin, organizationDatabaseID: organizationDatabaseID
        )
        if let missing = Self.missingPermissions(in: response.errors) {
            throw PersonalWorkDiscoveryError.missingTokenPermissions(missing)
        }
        guard response.errors.isEmpty else { throw GitHubGraphQLError.partialResponse }
        guard let data = response.data else { throw GitHubGraphQLError.missingData }
        return data
    }

    /// GitHub refuses individual fields a fine-grained token can't read
    /// (`FORBIDDEN`) while answering the rest. Names the permissions that
    /// cover the refused fields; `nil` when nothing was refused.
    static func missingPermissions(in errors: [GitHubGraphQLPartialError]) -> [String]? {
        let refused = errors.filter { ($0.type ?? $0.extensions?.type) == "FORBIDDEN" }
        guard !refused.isEmpty else { return nil }
        // The innermost field is the one refused; outer fields are just where it sits.
        let fields = Set(refused.compactMap { error in
            (error.path ?? []).compactMap { component -> String? in
                if case .field(let name) = component { name } else { nil }
            }.last { $0 != "nodes" }
        })
        let byField: [(field: String, parameter: String)] = [
            ("commits", "contents"), ("requestedReviewer", "members"), ("statusCheckRollup", "statuses"),
            ("reviewRequests", "pull_requests"), ("latestReviews", "pull_requests"), ("reviewThreads", "pull_requests"),
            ("category", "discussions"), ("closed", "discussions"),
        ]
        let parameters = Set(byField.filter { fields.contains($0.field) }.map(\.parameter))
        let permissions = GitHubTokenRequirements.repositoryPermissions + GitHubTokenRequirements.organizationPermissions
        return permissions.filter { parameters.contains($0.parameter) }.map(\.title)
    }

    /// GitHub still answers a search when single sign-on hides an
    /// organization, so an empty result would look like having no work.
    static func checkSingleSignOn(
        _ header: GitHubSSOHeader?, organizationLogin: String, organizationDatabaseID: UInt64?
    ) throws {
        switch header {
        case .authorizationRequired(let url):
            throw PersonalWorkDiscoveryError.singleSignOnRequired(organization: organizationLogin, authorizationURL: url)
        case .partialResults(let organizations):
            // Searches are limited to one organization; without its ID, any omission is that organization's.
            guard organizationDatabaseID.map(organizations.contains) ?? true else { return }
            throw PersonalWorkDiscoveryError.singleSignOnRequired(organization: organizationLogin, authorizationURL: nil)
        case .malformed, nil:
            return
        }
    }
}

struct GitHubPersonalWorkDiscovery: PersonalWorkDiscovering {
    static let maximumPages = 40
    static let maximumAttemptsPerPage = 3
    private static let logger = Logger(subsystem: "com.triage.mac", category: "Discovery")
    private let executor: any PersonalWorkSearchExecuting
    private let inbox: (any DiscussionInboxFetching)?
    private let now: @Sendable () -> Date
    private let retryDelay: @Sendable (Int) async throws -> Void

    init(
        executor: any PersonalWorkSearchExecuting,
        inbox: (any DiscussionInboxFetching)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        retryDelay: @escaping @Sendable (Int) async throws -> Void = { attempt in
            try await Task.sleep(for: .seconds(2 * attempt))
        }
    ) {
        self.executor = executor
        self.inbox = inbox
        self.now = now
        self.retryDelay = retryDelay
    }

    func discover(
        scope: WorkspaceScope,
        progress: @escaping @Sendable (DiscoveryProgress) async -> Void
    ) async throws -> [PersonalWorkItem] {
        try Self.validate(scope: scope)
        let queries = try WorkRelationship.allCases.sorted { $0.urgencyRank < $1.urgencyRank }.flatMap { relationship in
            try Self.searchQueries(for: relationship, scope: scope, now: now()).map { (relationship, $0) }
        }
        let collector = Collector(organizationLogin: scope.organizationLogin)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var index = 0
            while index < min(2, queries.count) {
                let query = queries[index]
                group.addTask { try await search(query.0, query.1, collector, progress) }
                index += 1
            }
            while try await group.next() != nil {
                guard index < queries.count else { continue }
                let query = queries[index]
                group.addTask { try await search(query.0, query.1, collector, progress) }
                index += 1
            }
        }
        if let inbox {
            let hits = try await inbox.unreadDiscussions()
            if !hits.isEmpty {
                var found = 0
                for hit in hits {
                    found = await collector.add([hit.node], relationship: hit.relationship)
                }
                await progress(.init(relationship: .watching, found: found))
            }
        }
        return await collector.items()
    }

    /// One search per item type. Fine-grained tokens grant Issues, Pull
    /// requests, and Discussions separately, so GitHub returns nothing for a
    /// search that doesn't name a type (REST rejects it; GraphQL answers with
    /// no results). Discussion search also rejects `archived:false`.
    static func searchQueries(for relationship: WorkRelationship, scope: WorkspaceScope, now: Date) throws -> [String] {
        try validate(scope: scope)
        let viewer = scope.viewerLogin
        let recent = "updated:>=\(dayString(now.addingTimeInterval(-60 * 86_400)))"
        let (types, qualifier): ([String], String) = switch relationship {
        case .reviewRequested: (["is:pr"], "review-requested:\(viewer)")
        case .assigned: (["is:issue", "is:pr"], "assignee:\(viewer)")
        case .authored: (["is:issue", "is:pr"], "author:\(viewer)")
        case .mentioned: (["is:issue", "is:pr"], "mentions:\(viewer) \(recent)")
        case .commented: (["is:issue", "is:pr"], "commenter:\(viewer) \(recent)")
        case .watching: ([], "")
        }
        var queries = types.map { "org:\(scope.organizationLogin) \($0) is:open archived:false \(qualifier)" }
        // GitHub discussion search does not honour `mentions:`. `commenter:`
        // and `author:` do. Closed discussions still receive comments, so the
        // comment window is not limited to `is:open`.
        let org = "org:\(scope.organizationLogin)"
        switch relationship {
        case .authored:
            queries.append("\(org) is:discussion is:open author:\(viewer)")
            queries.append("\(org) is:discussion is:closed author:\(viewer) \(recent)")
        case .commented:
            queries.append("\(org) is:discussion commenter:\(viewer) \(recent)")
        case .reviewRequested, .assigned, .mentioned, .watching:
            break
        }
        return queries
    }

    private func search(
        _ relationship: WorkRelationship,
        _ query: String,
        _ collector: Collector,
        _ progress: @escaping @Sendable (DiscoveryProgress) async -> Void
    ) async throws {
        var cursor: String?
        for pageNumber in 1...Self.maximumPages {
            try Task.checkCancellation()
            let page: PersonalWorkSearchPage
            do {
                page = try await fetchPage(query: query, cursor: cursor, relationship: relationship, pageNumber: pageNumber)
            } catch PersonalWorkDiscoveryError.missingTokenPermissions where query.contains(" is:discussion ") {
                // A token without Discussions read must not blank the inbox.
                Self.logger.error("discussion search skipped reason=missingPermission")
                return
            }
            let found = await collector.add(page.search.nodes, relationship: relationship)
            await progress(.init(relationship: relationship, found: found))
            Self.logger.notice("search relationship=\(relationship.rawValue, privacy: .public) page=\(pageNumber, privacy: .public) results=\(page.search.nodes.count, privacy: .public) totalFound=\(found, privacy: .public)")
            guard page.search.pageInfo.hasNextPage, let next = page.search.pageInfo.endCursor else { return }
            cursor = next
        }
    }

    /// GitHub search occasionally times out on heavy pages and answers with an
    /// empty or partial body. Retry those transient failures a few times;
    /// authentication, permission, and rate-limit failures surface immediately.
    private func fetchPage(
        query: String, cursor: String?, relationship: WorkRelationship, pageNumber: Int
    ) async throws -> PersonalWorkSearchPage {
        var attempt = 1
        while true {
            do {
                return try await executor.search(query: query, cursor: cursor)
            } catch where Self.isTransient(error) && attempt < Self.maximumAttemptsPerPage {
                Self.logger.notice("search retry relationship=\(relationship.rawValue, privacy: .public) page=\(pageNumber, privacy: .public) attempt=\(attempt, privacy: .public) errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                try await retryDelay(attempt)
                attempt += 1
            } catch where Self.isTransient(error) {
                Self.logger.error("search failed relationship=\(relationship.rawValue, privacy: .public) page=\(pageNumber, privacy: .public) attempts=\(attempt, privacy: .public)")
                throw PersonalWorkDiscoveryError.searchUnavailable
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? URLError { return error.code != .cancelled }
        if error is DecodingError { return true }
        switch error as? GitHubGraphQLError {
        case .invalidResponse, .partialResponse, .missingData: return true
        case .requestFailed(let failure): return failure.statusCode >= 500 && failure.retryAfter == nil
        default: return false
        }
    }

    private static func validate(scope: WorkspaceScope) throws {
        guard isValidLogin(scope.organizationLogin), isValidLogin(scope.viewerLogin) else {
            throw PersonalWorkDiscoveryError.invalidLogin
        }
    }

    private static func isValidLogin(_ value: String) -> Bool {
        guard (1...39).contains(value.count), let first = value.unicodeScalars.first,
              first.isASCII && (first.properties.isAlphabetic || first.properties.numericType != nil)
        else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}

struct InboxDiscussion: Sendable {
    let node: PersonalWorkSearchPage.Node
    let relationship: WorkRelationship
}

protocol DiscussionInboxFetching: Sendable {
    /// Unread discussions in the current organization. Empty when the token
    /// can't call `GET /notifications` (fine-grained, or classic without the
    /// scope). Throws when single sign-on hides the organization.
    func unreadDiscussions() async throws -> [InboxDiscussion]
}

/// Unread discussion threads from `GET /notifications`. Search cannot see a
/// discussion the viewer only watches. This call needs a classic token with
/// the `notifications` scope, and it never marks a thread read.
struct GitHubDiscussionInbox: DiscussionInboxFetching {
    static let maximumPages = 8
    static let maximumHydrations = 40
    /// Same window as comment search. A read notification does not drop the
    /// discussion while it, or the notification, is still inside this window.
    static let retention: TimeInterval = 60 * 86_400

    private let rest: GitHubRESTClient
    private let graphql: GitHubGraphQLClient
    private let organizationLogin: String
    private let organizationDatabaseID: UInt64?
    private let memory: (any WatchedDiscussionMemory)?
    private let now: @Sendable () -> Date

    init(
        rest: GitHubRESTClient,
        graphql: GitHubGraphQLClient,
        organizationLogin: String,
        organizationDatabaseID: UInt64?,
        memory: (any WatchedDiscussionMemory)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rest = rest
        self.graphql = graphql
        self.organizationLogin = organizationLogin
        self.organizationDatabaseID = organizationDatabaseID
        self.memory = memory
        self.now = now
    }

    static func shouldKeep(lastSeenAt: Date, updatedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastSeenAt) <= retention || now.timeIntervalSince(updatedAt) <= retention
    }

    func unreadDiscussions() async throws -> [InboxDiscussion] {
        let candidates = try await notificationCandidates()

        var hits: [InboxDiscussion] = []
        var seen = Set<String>()
        var remember: [WatchedDiscussionRef] = []
        let seenAt = now()
        for candidate in candidates {
            let key = Self.key(candidate.owner, candidate.name, candidate.number)
            seen.insert(key)
            switch try await hydrate(owner: candidate.owner, name: candidate.name, number: candidate.number) {
            case .discussion(let node) where !node.repository.isArchived:
                hits.append(InboxDiscussion(node: node, relationship: candidate.relationship))
                if candidate.relationship == .watching {
                    remember.append(WatchedDiscussionRef(
                        owner: candidate.owner.lowercased(), name: candidate.name.lowercased(),
                        number: candidate.number, lastSeenAt: seenAt
                    ))
                }
            case .discussion, .missing, .unavailable:
                break
            }
        }

        var forget: [WatchedDiscussionRef] = []
        var rememberedHydrations = 0
        let remembered = (try await memory?.refs() ?? []).sorted { $0.lastSeenAt > $1.lastSeenAt }
        for ref in remembered where !seen.contains(Self.key(ref.owner, ref.name, ref.number)) {
            if rememberedHydrations == Self.maximumHydrations { break }
            rememberedHydrations += 1
            switch try await hydrate(owner: ref.owner, name: ref.name, number: ref.number) {
            case .discussion(let node) where node.repository.isArchived:
                forget.append(ref)
            case .discussion(let node) where !Self.shouldKeep(lastSeenAt: ref.lastSeenAt, updatedAt: node.updatedAt, now: seenAt):
                forget.append(ref)
            case .discussion(let node)
                where node.repository.nameWithOwner.lowercased().hasPrefix("\(organizationLogin.lowercased())/"):
                hits.append(InboxDiscussion(node: node, relationship: .watching))
            case .discussion:
                forget.append(ref)
            case .missing:
                forget.append(ref)
            case .unavailable:
                break
            }
        }
        if let memory {
            try await memory.remember(remember)
            try await memory.forget(forget)
        }
        return hits
    }

    private static func key(_ owner: String, _ name: String, _ number: Int) -> String {
        "\(owner.lowercased())/\(name.lowercased())#\(number)"
    }

    /// Unread discussion threads. Empty when the token can't call the inbox.
    /// A missing scope must not skip discussions already remembered.
    private func notificationCandidates() async throws -> [(owner: String, name: String, number: Int, relationship: WorkRelationship)] {
        var request = try GitHubRESTRequest(
            path: "/notifications",
            query: [
                URLQueryItem(name: "all", value: "false"),
                URLQueryItem(name: "participating", value: "false"),
                URLQueryItem(name: "per_page", value: "50"),
            ]
        )
        var candidates: [(owner: String, name: String, number: Int, relationship: WorkRelationship)] = []
        for _ in 1...Self.maximumPages {
            let page: GitHubPage<NotificationThread>
            do {
                page = try await rest.getPage(NotificationThread.self, request: request)
            } catch {
                if try Self.missingScope(error, organizationLogin: organizationLogin, organizationDatabaseID: organizationDatabaseID) {
                    return []
                }
                throw error
            }
            try GitHubPersonalWorkSearchExecutor.checkSingleSignOn(
                page.ssoHeader, organizationLogin: organizationLogin, organizationDatabaseID: organizationDatabaseID
            )
            for thread in page.values where thread.subject.type == "Discussion" {
                guard let parsed = Self.discussion(in: thread.subject.url),
                      parsed.owner.caseInsensitiveCompare(organizationLogin) == .orderedSame,
                      let relationship = Self.relationship(forNotificationReason: thread.reason)
                else { continue }
                candidates.append((parsed.owner, parsed.name, parsed.number, relationship))
                if candidates.count == Self.maximumHydrations { break }
            }
            guard candidates.count < Self.maximumHydrations, let next = page.nextPageURL else { break }
            request = try GitHubRESTRequest(nextPageURL: next)
        }
        return candidates
    }

    /// `true` when a classic `notifications` scope is missing. Single sign-on
    /// refusals still throw, so a hidden organization doesn't look empty.
    static func missingScope(
        _ error: Error, organizationLogin: String, organizationDatabaseID: UInt64?
    ) throws -> Bool {
        guard let failure = error as? GitHubFailure, failure.kind == .forbidden else { return false }
        try GitHubPersonalWorkSearchExecutor.checkSingleSignOn(
            failure.ssoHeader, organizationLogin: organizationLogin, organizationDatabaseID: organizationDatabaseID
        )
        return true
    }

    static func relationship(forNotificationReason reason: String) -> WorkRelationship? {
        switch reason {
        case "subscribed", "manual", "state_change": .watching
        case "mention", "team_mention": .mentioned
        case "author": .authored
        case "comment": .commented
        default: nil
        }
    }

    /// `subject.url` is `https://api.github.com/repos/{owner}/{repo}/discussions/{number}`.
    static func discussion(in url: URL?) -> (owner: String, name: String, number: Int)? {
        guard let url else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let owner: String
        let name: String
        let numberText: String
        if parts.count == 5, parts[0] == "repos", parts[3] == "discussions" {
            owner = parts[1]
            name = parts[2]
            numberText = parts[4]
        } else if parts.count == 4, parts[2] == "discussions" {
            owner = parts[0]
            name = parts[1]
            numberText = parts[3]
        } else {
            return nil
        }
        guard let number = Int(numberText), number > 0,
              !owner.isEmpty, !name.isEmpty, !owner.contains("."), !name.contains("..")
        else { return nil }
        return (owner, name, number)
    }

    private enum Hydration: Sendable {
        case discussion(PersonalWorkSearchPage.Node)
        case missing
        case unavailable
    }

    private func hydrate(owner: String, name: String, number: Int) async throws -> Hydration {
        struct Variables: Encodable, Sendable {
            let owner: String
            let name: String
            let number: Int
        }
        struct Lookup: Decodable, Sendable {
            struct Repository: Decodable, Sendable {
                let discussion: PersonalWorkSearchPage.Node?
            }
            let repository: Repository?
        }
        let response: GitHubGraphQLResponse<Lookup>
        do {
            response = try await graphql.execute(
                GitHubGraphQLQueries.discussionLookup(),
                variables: Variables(owner: owner, name: name, number: number),
                as: Lookup.self
            )
        } catch let error as GitHubGraphQLError {
            if case .requestFailed(let failure) = error {
                if failure.kind == .notFound { return .missing }
                if failure.kind == .forbidden { return .unavailable }
            }
            throw error
        }
        try GitHubPersonalWorkSearchExecutor.checkSingleSignOn(
            response.metadata.ssoHeader, organizationLogin: organizationLogin, organizationDatabaseID: organizationDatabaseID
        )
        if GitHubPersonalWorkSearchExecutor.missingPermissions(in: response.errors) != nil {
            return .unavailable
        }
        guard response.errors.isEmpty else { return .unavailable }
        guard let discussion = response.data?.repository?.discussion else { return .missing }
        return .discussion(discussion)
    }
}

private struct NotificationThread: Decodable, Sendable {
    let reason: String
    let subject: Subject

    struct Subject: Decodable, Sendable {
        let type: String
        let url: URL?
    }
}

private actor Collector {
    private let organizationLogin: String
    private var values: [GitHubNodeID: PersonalWorkItem] = [:]

    init(organizationLogin: String) {
        self.organizationLogin = organizationLogin
    }

    func add(_ nodes: [PersonalWorkSearchPage.Node?], relationship: WorkRelationship) -> Int {
        for node in nodes.compactMap({ $0 })
        where !node.repository.isArchived &&
            node.repository.nameWithOwner.lowercased().hasPrefix("\(organizationLogin.lowercased())/") {
            guard let item = map(node, relationship: relationship) else { continue }
            if var current = values[item.id] {
                let relationships = current.relationships.union(item.relationships)
                current = newer(current, item)
                values[item.id] = PersonalWorkItem(
                    id: current.id, kind: current.kind, repository: current.repository, number: current.number,
                    title: current.title, url: current.url, state: current.state, author: current.author,
                    createdAt: current.createdAt, updatedAt: current.updatedAt,
                    relationships: relationships, labels: current.labels,
                    assignees: current.assignees, body: current.body, pullRequest: current.pullRequest,
                    recentActivity: current.recentActivity
                )
            } else {
                values[item.id] = item
            }
        }
        return values.count
    }

    func items() -> [PersonalWorkItem] {
        values.values.sorted { lhs, rhs in
            let lhsRank = lhs.primaryRelationship?.urgencyRank ?? .max
            let rhsRank = rhs.primaryRelationship?.urgencyRank ?? .max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private func newer(_ lhs: PersonalWorkItem, _ rhs: PersonalWorkItem) -> PersonalWorkItem {
        lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
    }

    private func map(_ node: PersonalWorkSearchPage.Node, relationship: WorkRelationship) -> PersonalWorkItem? {
        let kind: WorkKind
        switch node.typename {
        case "Issue": kind = .issue
        case "PullRequest": kind = .pullRequest
        case "Discussion": kind = .discussion
        default: return nil
        }
        let body = PersonalWorkItem.cleanedMarkdown(node.body, maximumBytes: PersonalWorkItem.maximumBodyLength)
        let activity = node.comments.nodes.compactMap { $0 }.sorted { $0.createdAt < $1.createdAt }.map {
            ActivityFact(author: $0.author?.login ?? "ghost", createdAt: $0.createdAt,
                         excerpt: PersonalWorkItem.cleanedMarkdown($0.body, maximumBytes: PersonalWorkItem.maximumBodyLength))
        }
        let headCommit = node.commits?.nodes.compactMap(\.self).last?.commit
        let pullRequest = kind == .pullRequest ? PullRequestFacts(
            isDraft: node.isDraft ?? false,
            reviewDecision: reviewDecision(node.reviewDecision),
            requestedReviewers: node.reviewRequests?.nodes.compactMap { request in
                guard let reviewer = request?.requestedReviewer else { return nil }
                return reviewer.typename == "Team" ? reviewer.combinedSlug : reviewer.login
            } ?? [],
            latestReviews: node.latestReviews?.nodes.compactMap { review in
                guard let review else { return nil }
                return ReviewFact(author: review.author?.login ?? "ghost", state: review.state, submittedAt: review.submittedAt)
            } ?? [],
            checks: checkStatus(headCommit?.statusCheckRollup?.state),
            mergeable: node.mergeable,
            unresolvedReviewThreads: node.reviewThreads?.nodes.compactMap(\.self).filter { !$0.isResolved }.count ?? 0,
            additions: node.additions ?? 0, deletions: node.deletions ?? 0,
            lastCommitAt: headCommit?.committedDate,
            lastCommitAuthors: headCommit?.authors?.nodes.compactMap { $0?.user?.login }
        ) : nil
        return PersonalWorkItem(
            id: node.id, kind: kind, repository: node.repository.nameWithOwner, number: node.number,
            title: node.title, url: node.url,
            state: workState(kind: kind, node: node),
            author: node.author?.login, createdAt: node.createdAt, updatedAt: node.updatedAt,
            relationships: [relationship], labels: labels(node),
            assignees: node.assignees?.nodes.compactMap { $0?.login } ?? [], body: body,
            pullRequest: pullRequest, recentActivity: activity
        )
    }


    private func workState(kind: WorkKind, node: PersonalWorkSearchPage.Node) -> WorkState {
        if kind == .discussion { return node.closed == true ? .closed : .open }
        if kind == .pullRequest && node.merged == true { return .merged }
        return node.state == "OPEN" ? .open : .closed
    }

    /// Discussion category is kept as a label so existing label rules can match it.
    private func labels(_ node: PersonalWorkSearchPage.Node) -> [String] {
        var names = node.labels?.nodes.compactMap { $0?.name } ?? []
        if let category = node.category?.name, !names.contains(category) {
            names.insert(category, at: 0)
        }
        return names
    }

    private func reviewDecision(_ value: String?) -> ReviewDecision? {
        switch value {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: nil
        }
    }

    private func checkStatus(_ value: String?) -> CheckStatus? {
        switch value {
        case "SUCCESS": .success
        case "FAILURE": .failure
        case "PENDING": .pending
        case "ERROR": .error
        case "EXPECTED": .expected
        default: nil
        }
    }
}
