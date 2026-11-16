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
    /// Each pull request's individual checks and whether they're required.
    /// At most `GitHubGraphQLQueries.checkDetailsSlots` IDs per call.
    func checkDetails(pullRequestIDs: [GitHubNodeID]) async throws -> CheckDetails
    /// The GitHub Actions jobs on `headSHA` that aren't passing, standing in
    /// for check runs when GitHub withholds them from fine-grained tokens.
    func actionsChecks(repository: String, headSHA: String) async throws -> ActionsChecks
    /// Check names the branch's protection or rulesets require to merge.
    func requiredCheckNames(repository: String, branch: String) async throws -> Set<String>
}

struct CheckDetails: Equatable, Sendable {
    var checks: [GitHubNodeID: [CheckRunFact]]
    /// GitHub refused the check runs (fine-grained tokens can't read them);
    /// `checks` then holds only commit statuses.
    var withheld = false
}

/// Jobs from GitHub Actions; `complete` once every workflow run has finished.
struct ActionsChecks: Equatable, Sendable {
    var checks: [CheckRunFact]
    var complete: Bool
}

extension PersonalWorkSearchExecuting {
    func checkDetails(pullRequestIDs: [GitHubNodeID]) async throws -> CheckDetails { CheckDetails(checks: [:]) }
    func actionsChecks(repository: String, headSHA: String) async throws -> ActionsChecks { ActionsChecks(checks: [], complete: true) }
    func requiredCheckNames(repository: String, branch: String) async throws -> Set<String> { [] }
}

/// The `TriageCheckDetails` response: slots `p0`…`p4`, each a pull request.
struct CheckDetailsPage: Decodable, Sendable {
    struct PullRequest: Decodable, Sendable {
        let id: GitHubNodeID?
        let commits: Commits?
    }
    struct Commits: Decodable, Sendable { let nodes: [CommitNode?] }
    struct CommitNode: Decodable, Sendable { let commit: Commit? }
    struct Commit: Decodable, Sendable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable, Sendable { let contexts: PersonalWorkSearchPage.Contexts? }

    private struct SlotKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    let pullRequests: [PullRequest]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: SlotKey.self)
        pullRequests = try container.allKeys.filter { $0.stringValue.hasPrefix("p") }.compactMap {
            try container.decodeIfPresent(PullRequest.self, forKey: $0)
        }
    }

    var checks: [GitHubNodeID: [CheckRunFact]] {
        var result: [GitHubNodeID: [CheckRunFact]] = [:]
        for pullRequest in pullRequests {
            guard let id = pullRequest.id else { continue }
            result[id] = pullRequest.commits?.nodes.compactMap(\.self).last?.commit?.statusCheckRollup?.contexts?.checkRuns ?? []
        }
        return result
    }
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
        let baseRefName: String?
        let reviewRequests: ReviewRequests?
        let latestReviews: Reviews?
        let commits: Commits?
        let reviewThreads: Threads?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename", id, number, title, url, state, createdAt, updatedAt, body, author, repository, labels, assignees, comments, isDraft, merged, reviewDecision, mergeable, additions, deletions, baseRefName, reviewRequests, latestReviews, commits, reviewThreads
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
        let oid: String?
        let statusCheckRollup: StatusCheckRollup?
        let committedDate: Date?
        let authors: CommitAuthors?
    }
    struct CommitAuthors: Decodable, Sendable { let nodes: [CommitAuthor?] }
    struct CommitAuthor: Decodable, Sendable { let user: Actor? }
    struct StatusCheckRollup: Decodable, Sendable { let state: String? }
    struct Contexts: Decodable, Sendable { let nodes: [Context?] }
    struct Context: Decodable, Sendable {
        let typename: String
        let name: String?
        let status: String?
        let conclusion: String?
        let context: String?
        let state: String?
        let isRequired: Bool?
        enum CodingKeys: String, CodingKey { case typename = "__typename", name, status, conclusion, context, state, isRequired }
    }
    struct Threads: Decodable, Sendable { let nodes: [Thread?] }
    struct Thread: Decodable, Sendable { let isResolved: Bool }
}

struct GitHubPersonalWorkSearchExecutor: PersonalWorkSearchExecuting {
    private static let logger = Logger(subsystem: "com.triage.mac", category: "Discovery")
    private let client: GitHubGraphQLClient
    private let organizationLogin: String
    /// GitHub's numeric organization ID, matched against single sign-on evidence.
    private let organizationDatabaseID: UInt64?
    private let rest: GitHubRESTClient?

    init(
        client: GitHubGraphQLClient, organizationLogin: String, organizationDatabaseID: UInt64?,
        rest: GitHubRESTClient? = nil
    ) {
        self.client = client
        self.organizationLogin = organizationLogin
        self.organizationDatabaseID = organizationDatabaseID
        self.rest = rest
    }

    private struct WorkflowRuns: Decodable, Sendable {
        struct Run: Decodable, Sendable { let id: Int; let status: String?; let conclusion: String? }
        let workflowRuns: [Run]
        enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
    }

    private struct WorkflowJobs: Decodable, Sendable {
        struct Job: Decodable, Sendable { let name: String; let status: String?; let conclusion: String? }
        let jobs: [Job]
    }

    /// Workflow runs whose jobs are read per commit; only runs that haven't passed.
    static let maximumActionsRuns = 5

    func actionsChecks(repository: String, headSHA: String) async throws -> ActionsChecks {
        guard let rest, Self.isRepositoryName(repository), headSHA.allSatisfy(\.isHexDigit), !headSHA.isEmpty else {
            return ActionsChecks(checks: [], complete: true)
        }
        let runs = try await rest.get(WorkflowRuns.self, request: GitHubRESTRequest(
            path: "/repos/\(repository)/actions/runs",
            query: [URLQueryItem(name: "head_sha", value: headSHA), URLQueryItem(name: "per_page", value: "30")]
        )).workflowRuns
        let unfinished = runs.filter { Self.result(status: $0.status, conclusion: $0.conclusion).needsDetail }
        var checks: [CheckRunFact] = []
        for run in unfinished.prefix(Self.maximumActionsRuns) {
            let jobs = try await rest.get(WorkflowJobs.self, request: GitHubRESTRequest(
                path: "/repos/\(repository)/actions/runs/\(run.id)/jobs",
                query: [URLQueryItem(name: "filter", value: "latest"), URLQueryItem(name: "per_page", value: "100")]
            )).jobs
            for job in jobs where !checks.contains(where: { $0.name == job.name }) {
                checks.append(CheckRunFact(name: job.name, result: Self.result(status: job.status, conclusion: job.conclusion).fact))
            }
        }
        return ActionsChecks(
            checks: Array(checks.prefix(PullRequestFacts.maximumCheckRuns)),
            complete: runs.allSatisfy { $0.status == "completed" }
        )
    }

    private struct BranchPayload: Decodable, Sendable {
        struct Protection: Decodable, Sendable {
            let requiredStatusChecks: Required?
            enum CodingKeys: String, CodingKey { case requiredStatusChecks = "required_status_checks" }
        }
        struct Required: Decodable, Sendable { let contexts: [String]? }
        let protection: Protection?
        var contexts: [String] { protection?.requiredStatusChecks?.contexts ?? [] }
    }

    private struct BranchRulePayload: Decodable, Sendable {
        struct Parameters: Decodable, Sendable {
            let requiredStatusChecks: [Check]?
            enum CodingKeys: String, CodingKey { case requiredStatusChecks = "required_status_checks" }
        }
        struct Check: Decodable, Sendable { let context: String }
        let type: String
        let parameters: Parameters?
        var contexts: [String] { type == "required_status_checks" ? (parameters?.requiredStatusChecks ?? []).map(\.context) : [] }
    }

    func requiredCheckNames(repository: String, branch: String) async throws -> Set<String> {
        // A branch name with a slash can't be sent as one path segment.
        guard let rest, Self.isRepositoryName(repository), !branch.isEmpty, !branch.contains("/"), branch != "..", branch != "." else {
            return []
        }
        var names = Set<String>()
        // Branch protection and rulesets are independent; use whichever answers.
        if let payload = try? await rest.get(BranchPayload.self, request: GitHubRESTRequest(path: "/repos/\(repository)/branches/\(branch)")) {
            names.formUnion(payload.contexts)
        }
        if let rules = try? await rest.get([BranchRulePayload].self, request: GitHubRESTRequest(path: "/repos/\(repository)/rules/branches/\(branch)")) {
            names.formUnion(rules.flatMap(\.contexts))
        }
        return names
    }

    static func isRepositoryName(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != ".." && part != "." && part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
    }

    /// A workflow run's or job's state as a check result.
    static func result(status: String?, conclusion: String?) -> (fact: CheckRunFact.Result, needsDetail: Bool) {
        guard status == "completed" else { return (.pending, true) }
        switch conclusion {
        case "success": return (.passing, false)
        case "skipped": return (.skipped, false)
        case "neutral": return (.neutral, false)
        default: return (.failing, true)
        }
    }

    func checkDetails(pullRequestIDs: [GitHubNodeID]) async throws -> CheckDetails {
        guard let last = pullRequestIDs.last, pullRequestIDs.count <= GitHubGraphQLQueries.checkDetailsSlots else {
            return CheckDetails(checks: [:])
        }
        var variables: [String: String] = [:]
        for slot in 0..<GitHubGraphQLQueries.checkDetailsSlots {
            variables["id\(slot)"] = (slot < pullRequestIDs.count ? pullRequestIDs[slot] : last).rawValue
        }
        let response = try await client.execute(
            GitHubGraphQLQueries.checkDetails(), variables: variables, as: CheckDetailsPage.self
        )
        // Fine-grained tokens can't read check runs; GitHub refuses just those.
        let errors = response.errors.filter { !Self.isCheckRunRefusal($0) }
        guard errors.isEmpty, let data = response.data else { throw GitHubGraphQLError.partialResponse }
        return CheckDetails(checks: data.checks, withheld: errors.count < response.errors.count)
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
        let errors = response.errors
        if let missing = Self.missingPermissions(in: errors) {
            let fields = errors.compactMap { $0.path?.compactMap { if case .field(let name) = $0 { name } else { nil } }.joined(separator: ".") }
            Self.logger.error("search refused fields=\(fields.joined(separator: " "), privacy: .public)")
            throw PersonalWorkDiscoveryError.missingTokenPermissions(missing)
        }
        guard errors.isEmpty else { throw GitHubGraphQLError.partialResponse }
        guard let data = response.data else { throw GitHubGraphQLError.missingData }
        return data
    }

    /// A refusal of a pull request's check runs, which commit statuses survive.
    static func isCheckRunRefusal(_ error: GitHubGraphQLPartialError) -> Bool {
        guard (error.type ?? error.extensions?.type) == "FORBIDDEN" else { return false }
        return (error.path ?? []).contains { component in
            if case .field("contexts") = component { true } else { false }
        }
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
        try await discoverWork(scope: scope, progress: progress).items
    }

    func discoverWork(
        scope: WorkspaceScope,
        progress: @escaping @Sendable (DiscoveryProgress) async -> Void
    ) async throws -> DiscoveredWork {
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
        let (items, withheld) = await withCheckDetails(await collector.items())
        guard withheld else { return DiscoveredWork(items: items) }
        return await withActionsChecks(items, references: collector.references())
    }

    /// Pull requests whose individual checks are read per refresh.
    static let maximumCheckDetailPullRequests = 50

    /// Reads individual checks, and which are required, for pull requests
    /// whose checks are failing or still running. Best effort: without them,
    /// work keeps its overall check state.
    private func withCheckDetails(_ items: [PersonalWorkItem]) async -> (items: [PersonalWorkItem], withheld: Bool) {
        let candidates = items.filter { Self.needsCheckDetail($0) }.prefix(Self.maximumCheckDetailPullRequests).map(\.id)
        guard !candidates.isEmpty else { return (items, false) }
        var checks: [GitHubNodeID: [CheckRunFact]] = [:]
        var withheld = false
        for start in stride(from: 0, to: candidates.count, by: GitHubGraphQLQueries.checkDetailsSlots) {
            let batch = Array(candidates[start..<min(start + GitHubGraphQLQueries.checkDetailsSlots, candidates.count)])
            do {
                let details = try await executor.checkDetails(pullRequestIDs: batch)
                checks.merge(details.checks) { $1 }
                withheld = withheld || details.withheld
            } catch {
                Self.logger.notice("check-details outcome=skipped errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                break
            }
        }
        let enriched = items.map { item -> PersonalWorkItem in
            guard let runs = checks[item.id], !runs.isEmpty, var facts = item.pullRequest else { return item }
            facts.checkRuns = Array(runs.prefix(PullRequestFacts.maximumCheckRuns))
            return item.replacingPullRequest(facts)
        }
        return (enriched, withheld)
    }

    static func needsCheckDetail(_ item: PersonalWorkItem) -> Bool {
        guard let checks = item.pullRequest?.checks else { return false }
        return [.failure, .error, .pending, .expected].contains(checks)
    }

    /// Pull requests whose jobs are read from GitHub Actions per refresh.
    static let maximumActionsPullRequests = 25
    private static let actionsCache = ActionsChecksCache()

    /// When GitHub withholds check runs, reads GitHub Actions jobs for pull
    /// requests whose checks are failing or still running, and which of them
    /// the base branch requires. Best effort: without Actions access, work
    /// keeps its overall check state and commit statuses.
    private func withActionsChecks(
        _ items: [PersonalWorkItem], references: [GitHubNodeID: PullRequestReference]
    ) async -> DiscoveredWork {
        let candidates = items.filter { Self.needsCheckDetail($0) && references[$0.id]?.headSHA != nil }
            .prefix(Self.maximumActionsPullRequests)
        var jobs: [GitHubNodeID: [CheckRunFact]] = [:]
        var missing: [String] = []
        for item in candidates {
            guard let reference = references[item.id], let sha = reference.headSHA else { continue }
            let key = "\(item.repository)@\(sha)"
            if let cached = await Self.actionsCache.value(for: key) {
                jobs[item.id] = cached
                continue
            }
            do {
                let result = try await executor.actionsChecks(repository: item.repository, headSHA: sha)
                jobs[item.id] = result.checks
                if result.complete { await Self.actionsCache.store(result.checks, for: key) }
            } catch let failure as GitHubFailure where failure.kind == .forbidden {
                missing = ["Actions"]
                Self.logger.notice("actions-checks outcome=forbidden")
                break
            } catch is CancellationError {
                break
            } catch {
                Self.logger.notice("actions-checks outcome=skipped errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
        var required: [String: Set<String>] = [:]
        for item in candidates where jobs[item.id]?.contains(where: { $0.result == .failing }) == true
            || item.pullRequest?.checkRuns?.contains(where: { $0.result == .failing }) == true {
            guard let branch = references[item.id]?.baseRefName else { continue }
            let key = "\(item.repository)#\(branch)"
            if required[key] == nil {
                required[key] = (try? await executor.requiredCheckNames(repository: item.repository, branch: branch)) ?? []
            }
        }
        let enriched = items.map { item -> PersonalWorkItem in
            guard var facts = item.pullRequest else { return item }
            var runs = facts.checkRuns ?? []
            for job in jobs[item.id] ?? [] where !runs.contains(where: { $0.name == job.name }) { runs.append(job) }
            if let branch = references[item.id]?.baseRefName, let names = required["\(item.repository)#\(branch)"], !names.isEmpty {
                runs = runs.map { run in
                    var run = run
                    run.isRequired = names.contains(run.name)
                    return run
                }
            }
            guard runs != (facts.checkRuns ?? []) else { return item }
            facts.checkRuns = Array(runs.prefix(PullRequestFacts.maximumCheckRuns))
            return item.replacingPullRequest(facts)
        }
        return DiscoveredWork(items: enriched, missingOptionalPermissions: missing)
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

struct PullRequestReference: Equatable, Sendable {
    let headSHA: String?
    let baseRefName: String?
}

/// GitHub Actions jobs for commits whose workflow runs have all finished;
/// those never change, so later refreshes don't ask again.
actor ActionsChecksCache {
    static let capacity = 500
    private var values: [String: [CheckRunFact]] = [:]
    private var order: [String] = []

    func value(for key: String) -> [CheckRunFact]? { values[key] }

    func store(_ checks: [CheckRunFact], for key: String) {
        if values.updateValue(checks, forKey: key) == nil { order.append(key) }
        while order.count > Self.capacity { values[order.removeFirst()] = nil }
    }
}

private actor Collector {
    private let organizationLogin: String
    private var values: [GitHubNodeID: PersonalWorkItem] = [:]
    private var pullRequestReferences: [GitHubNodeID: PullRequestReference] = [:]

    func references() -> [GitHubNodeID: PullRequestReference] { pullRequestReferences }

    init(organizationLogin: String) {
        self.organizationLogin = organizationLogin
    }

    func add(_ nodes: [PersonalWorkSearchPage.Node?], relationship: WorkRelationship) -> Int {
        for node in nodes.compactMap({ $0 })
        where !node.repository.isArchived &&
            node.repository.nameWithOwner.lowercased().hasPrefix("\(organizationLogin.lowercased())/") {
            guard let item = map(node, relationship: relationship) else { continue }
            if item.kind == .pullRequest {
                pullRequestReferences[item.id] = PullRequestReference(
                    headSHA: node.commits?.nodes.compactMap(\.self).last?.commit?.oid, baseRefName: node.baseRefName
                )
            }
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

extension PersonalWorkSearchPage.Contexts {
    var checkRuns: [CheckRunFact] {
        nodes.compactMap { node -> CheckRunFact? in
            guard let node else { return nil }
            switch node.typename {
            case "CheckRun":
                guard let name = node.name else { return nil }
                return CheckRunFact(
                    name: name, result: Self.checkRunResult(status: node.status, conclusion: node.conclusion), isRequired: node.isRequired
                )
            case "StatusContext":
                guard let name = node.context else { return nil }
                let result: CheckRunFact.Result = switch node.state {
                case "SUCCESS": .passing
                case "FAILURE", "ERROR": .failing
                default: .pending
                }
                return CheckRunFact(name: name, result: result, isRequired: node.isRequired)
            default:
                return nil
            }
        }.prefix(PullRequestFacts.maximumCheckRuns).map(\.self)
    }

    private static func checkRunResult(status: String?, conclusion: String?) -> CheckRunFact.Result {
        guard status == "COMPLETED" else { return .pending }
        return switch conclusion {
        case "SUCCESS": .passing
        case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": .failing
        case "SKIPPED": .skipped
        default: .neutral
        }
    }
}
