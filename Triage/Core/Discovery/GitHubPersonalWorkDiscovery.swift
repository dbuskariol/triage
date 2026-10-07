import Foundation
import OSLog

enum PersonalWorkDiscoveryError: Error, Equatable, Sendable, LocalizedError {
    case invalidLogin
    case searchUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidLogin: "This account or organization name isn't valid for GitHub search."
        case .searchUnavailable: "GitHub search timed out repeatedly. Showing saved work; Triage will try again automatically."
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
    struct Commit: Decodable, Sendable { let statusCheckRollup: StatusCheckRollup? }
    struct StatusCheckRollup: Decodable, Sendable { let state: String? }
    struct Threads: Decodable, Sendable { let nodes: [Thread?] }
    struct Thread: Decodable, Sendable { let isResolved: Bool }
}

struct GitHubPersonalWorkSearchExecutor: PersonalWorkSearchExecuting {
    private let client: GitHubGraphQLClient

    init(client: GitHubGraphQLClient) {
        self.client = client
    }

    func search(query: String, cursor: String?) async throws -> PersonalWorkSearchPage {
        struct Variables: Encodable, Sendable {
            let query: String
            let cursor: String?
        }
        return try await client.executeComplete(
            GitHubGraphQLQueries.personalWorkSearch(),
            variables: Variables(query: query, cursor: cursor),
            as: PersonalWorkSearchPage.self
        )
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
        let queries = try WorkRelationship.allCases.sorted { $0.urgencyRank < $1.urgencyRank }.map { relationship in
            (relationship, try Self.searchQuery(for: relationship, scope: scope, now: now()))
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

    static func searchQuery(for relationship: WorkRelationship, scope: WorkspaceScope, now: Date) throws -> String {
        try validate(scope: scope)
        let prefix = "org:\(scope.organizationLogin) is:open archived:false"
        let viewer = scope.viewerLogin
        switch relationship {
        case .reviewRequested: return "\(prefix) review-requested:\(viewer)"
        case .assigned: return "\(prefix) assignee:\(viewer)"
        case .authored: return "\(prefix) author:\(viewer)"
        case .mentioned: return "\(prefix) mentions:\(viewer) updated:>=\(dayString(now.addingTimeInterval(-60 * 86_400)))"
        case .commented: return "\(prefix) commenter:\(viewer) updated:>=\(dayString(now.addingTimeInterval(-60 * 86_400)))"
        }
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
                         excerpt: PersonalWorkItem.cleanedMarkdown($0.body, maximumBytes: PersonalWorkItem.maximumExcerptLength))
        }
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
            checks: checkStatus(node.commits?.nodes.compactMap(\.self).last?.commit?.statusCheckRollup?.state),
            mergeable: node.mergeable,
            unresolvedReviewThreads: node.reviewThreads?.nodes.compactMap(\.self).filter { !$0.isResolved }.count ?? 0,
            additions: node.additions ?? 0, deletions: node.deletions ?? 0
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
