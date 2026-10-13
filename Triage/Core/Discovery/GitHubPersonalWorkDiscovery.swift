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
        let state: String
        let createdAt: Date
        let updatedAt: Date
        /// GitHub-flavored Markdown source.
        let body: String
        let author: Actor?
        let repository: Repository
        let labels: Names
        let assignees: Actors
        let comments: Comments
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
            case typename = "__typename", id, number, title, url, state, createdAt, updatedAt, body, author, repository, labels, assignees, comments, isDraft, merged, reviewDecision, mergeable, additions, deletions, reviewRequests, latestReviews, commits, reviewThreads
        }
    }

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
        }
        let response = try await client.execute(
            GitHubGraphQLQueries.personalWorkSearch(),
            variables: Variables(query: query, cursor: cursor),
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
    private let now: @Sendable () -> Date
    private let retryDelay: @Sendable (Int) async throws -> Void

    init(
        executor: any PersonalWorkSearchExecuting,
        now: @escaping @Sendable () -> Date = Date.init,
        retryDelay: @escaping @Sendable (Int) async throws -> Void = { attempt in
            try await Task.sleep(for: .seconds(2 * attempt))
        }
    ) {
        self.executor = executor
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
        return await collector.items()
    }

    /// One search per item type. Fine-grained tokens grant Issues and Pull
    /// requests separately, so GitHub returns nothing for a search that
    /// doesn't name a type (REST rejects it; GraphQL answers with no results).
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
        }
        return types.map { "org:\(scope.organizationLogin) \($0) is:open archived:false \(qualifier)" }
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
            let page = try await fetchPage(query: query, cursor: cursor, relationship: relationship, pageNumber: pageNumber)
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
            state: kind == .pullRequest && node.merged == true ? .merged : node.state == "OPEN" ? .open : .closed,
            author: node.author?.login, createdAt: node.createdAt, updatedAt: node.updatedAt,
            relationships: [relationship], labels: node.labels.nodes.compactMap { $0?.name },
            assignees: node.assignees.nodes.compactMap { $0?.login }, body: body,
            pullRequest: pullRequest, recentActivity: activity
        )
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
