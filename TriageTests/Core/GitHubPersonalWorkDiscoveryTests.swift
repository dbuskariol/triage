import Foundation
import XCTest
@testable import Triage

final class GitHubPersonalWorkDiscoveryTests: XCTestCase {
    func testSearchesNameTheirTypeAndUseASixtyDayWindow() throws {
        let scope = scope()
        let date = Date(timeIntervalSince1970: 1_736_899_200) // 2025-01-15 UTC
        XCTAssertEqual(
            try GitHubPersonalWorkDiscovery.searchQueries(for: .reviewRequested, scope: scope, now: date),
            ["org:octo is:pr is:open archived:false review-requested:me"]
        )
        XCTAssertEqual(
            try GitHubPersonalWorkDiscovery.searchQueries(for: .mentioned, scope: scope, now: date),
            [
                "org:octo is:issue is:open archived:false mentions:me updated:>=2024-11-16",
                "org:octo is:pr is:open archived:false mentions:me updated:>=2024-11-16",
            ]
        )
        // Fine-grained tokens find nothing unless every search names is:issue or is:pr.
        for relationship in WorkRelationship.allCases {
            for query in try GitHubPersonalWorkDiscovery.searchQueries(for: relationship, scope: scope, now: date) {
                XCTAssertTrue(query.contains(" is:issue ") || query.contains(" is:pr "), query)
            }
        }
    }

    func testSingleSignOnThatHidesTheOrganizationFailsInsteadOfLookingEmpty() throws {
        let url = URL(string: "https://github.com/orgs/acme/sso?authorization_request=1")!
        XCTAssertThrowsError(try GitHubPersonalWorkSearchExecutor.checkSingleSignOn(
            .authorizationRequired(url), organizationLogin: "acme", organizationDatabaseID: 7
        )) { error in
            XCTAssertEqual(error as? PersonalWorkDiscoveryError, .singleSignOnRequired(organization: "acme", authorizationURL: url))
        }
        XCTAssertThrowsError(try GitHubPersonalWorkSearchExecutor.checkSingleSignOn(
            .partialResults([7, 9]), organizationLogin: "acme", organizationDatabaseID: 7
        )) { error in
            XCTAssertEqual(error as? PersonalWorkDiscoveryError, .singleSignOnRequired(organization: "acme", authorizationURL: nil))
        }
        // Another organization's single sign-on doesn't affect this organization's search.
        XCTAssertNoThrow(try GitHubPersonalWorkSearchExecutor.checkSingleSignOn(
            .partialResults([9]), organizationLogin: "acme", organizationDatabaseID: 7
        ))
        XCTAssertNoThrow(try GitHubPersonalWorkSearchExecutor.checkSingleSignOn(
            nil, organizationLogin: "acme", organizationDatabaseID: 7
        ))
    }

    func testRefusedFieldsNameTheMissingTokenPermissions() throws {
        func refused(_ path: String...) -> GitHubGraphQLPartialError {
            GitHubGraphQLPartialError(
                message: "Resource not accessible by personal access token",
                path: path.map { GitHubGraphQLErrorPathComponent.field($0) },
                type: "FORBIDDEN", extensions: nil
            )
        }
        XCTAssertEqual(
            GitHubPersonalWorkSearchExecutor.missingPermissions(in: [
                refused("search", "nodes", "commits", "nodes"),
                refused("search", "nodes", "reviewRequests", "nodes", "requestedReviewer"),
            ]),
            ["Contents", "Members"]
        )
        XCTAssertNil(GitHubPersonalWorkSearchExecutor.missingPermissions(in: []))
        XCTAssertEqual(GitHubPersonalWorkSearchExecutor.missingPermissions(in: [refused("search", "nodes", "unknown")]), [])
        XCTAssertFalse(GitHubPersonalWorkDiscovery.isTransient(PersonalWorkDiscoveryError.missingTokenPermissions(["Contents"])))
    }

    func testInvalidLoginIsRejected() async {
        let invalidScope = WorkspaceScope(
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "org")!,
            organizationLogin: "not valid",
            viewerLogin: "me"
        )
        do {
            _ = try await GitHubPersonalWorkDiscovery(executor: CancellingExecutor()).discover(scope: invalidScope) { _ in }
            XCTFail("Expected invalid login")
        } catch let error as PersonalWorkDiscoveryError {
            XCTAssertEqual(error, .invalidLogin)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPaginationMergeAndMapping() async throws {
        let executor = FixtureExecutor(pages: [
            "review-requested": [Self.page(Self.node(id: "I1", title: "first"), hasNext: true, cursor: "next"), Self.page(Self.node(id: "I1", title: "newer", updated: "2025-01-03T00:00:00Z"), hasNext: false)],
            "assignee": [Self.page(Self.node(id: "I1", title: "older"), hasNext: false)],
            "author": [Self.page(Self.node(id: "P1", type: "PullRequest", author: nil, body: "  a\n b  ", pr: true), hasNext: false)],
            "mentions": [Self.page(Self.node(id: "ARCH", archived: true), hasNext: false)],
            "commenter": [Self.page(Self.node(id: "OTHER", repository: "other/repo"), hasNext: false)]
        ])
        let discovery = GitHubPersonalWorkDiscovery(executor: executor, now: { Date(timeIntervalSince1970: 1_736_899_200) })
        let items = try await discovery.discover(scope: scope()) { _ in }

        XCTAssertEqual(items.count, 2)
        let issue = try XCTUnwrap(items.first { $0.id.rawValue == "I1" })
        XCTAssertEqual(issue.title, "newer")
        XCTAssertEqual(issue.relationships, Set([WorkRelationship.reviewRequested, .assigned]))
        let pr = try XCTUnwrap(items.first { $0.id.rawValue == "P1" })
        XCTAssertEqual(pr.author, nil)
        XCTAssertEqual(pr.body, "a\n b")
        XCTAssertEqual(pr.state, WorkState.merged)
        let facts = try XCTUnwrap(pr.pullRequest)
        XCTAssertEqual(facts.reviewDecision, ReviewDecision.approved)
        XCTAssertEqual(facts.checks, CheckStatus.success)
        XCTAssertEqual(facts.requestedReviewers, ["me", "octo/team"])
        XCTAssertEqual(facts.unresolvedReviewThreads, 1)
        XCTAssertEqual(pr.recentActivity.map(\ActivityFact.author), ["ghost", "alice"])
    }

    func testCheckRunsMapEveryConclusion() throws {
        let json = #"""
        { "nodes": [
          { "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "FAILURE" },
          { "__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS" },
          { "__typename": "CheckRun", "name": "e2e", "status": "IN_PROGRESS", "conclusion": null },
          { "__typename": "CheckRun", "name": "docs", "status": "COMPLETED", "conclusion": "SKIPPED" },
          { "__typename": "CheckRun", "name": "slow", "status": "COMPLETED", "conclusion": "TIMED_OUT" },
          { "__typename": "CheckRun", "name": "info", "status": "COMPLETED", "conclusion": "NEUTRAL" },
          { "__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR" },
          { "__typename": "StatusContext", "context": "ci/ok", "state": "SUCCESS" },
          null
        ] }
        """#
        let contexts = try JSONDecoder().decode(PersonalWorkSearchPage.Contexts.self, from: Data(json.utf8))
        XCTAssertEqual(contexts.checkRuns, [
            CheckRunFact(name: "build", result: .failing), CheckRunFact(name: "lint", result: .passing),
            CheckRunFact(name: "e2e", result: .pending), CheckRunFact(name: "docs", result: .skipped),
            CheckRunFact(name: "slow", result: .failing), CheckRunFact(name: "info", result: .neutral),
            CheckRunFact(name: "ci/legacy", result: .failing), CheckRunFact(name: "ci/ok", result: .passing),
        ])
    }

    func testCheckDetailsResponseDecodesSlotsAndIgnoresRateLimit() throws {
        let json = #"""
        { "p0": { "id": "PR_1", "commits": { "nodes": [{ "commit": { "statusCheckRollup": { "contexts": { "nodes": [
              { "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "FAILURE", "isRequired": true },
              { "__typename": "StatusContext", "context": "ci/legacy", "state": "SUCCESS", "isRequired": false } ] } } } }] } },
          "p1": { "id": "PR_2", "commits": { "nodes": [] } },
          "p2": null,
          "rateLimit": { "cost": 1, "remaining": 4999, "resetAt": "2025-01-01T00:00:00Z" } }
        """#
        let page = try JSONDecoder().decode(CheckDetailsPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.checks, [
            GitHubNodeID(rawValue: "PR_1")!: [
                CheckRunFact(name: "build", result: .failing, isRequired: true),
                CheckRunFact(name: "ci/legacy", result: .passing, isRequired: false),
            ],
            GitHubNodeID(rawValue: "PR_2")!: [],
        ])
    }

    func testChecksAreReadOnlyForPullRequestsThatArentPassing() async throws {
        let failing = Self.pullRequest(id: "PF", state: "FAILURE")
        let pending = Self.pullRequest(id: "PW", state: "PENDING")
        let passing = Self.pullRequest(id: "PP", state: "SUCCESS")
        let build = CheckRunFact(name: "build", result: .failing, isRequired: true)
        let executor = CheckDetailsExecutor(
            page: Self.page("\(failing), \(pending), \(passing)", hasNext: false),
            details: CheckDetails(checks: [GitHubNodeID(rawValue: "PF")!: [build]])
        )
        let items = try await GitHubPersonalWorkDiscovery(executor: executor).discover(scope: scope()) { _ in }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id.rawValue, $0) })
        let requested = await executor.requested
        XCTAssertEqual(requested, [["PF", "PW"]])
        XCTAssertEqual(byID["PF"]?.pullRequest?.checkRuns, [build])
        XCTAssertNil(byID["PP"]?.pullRequest?.checkRuns)
        // Required-ness never changes the decision fingerprint.
        var unknown = try XCTUnwrap(byID["PF"]?.pullRequest)
        unknown.checkRuns = unknown.checkRuns?.map { CheckRunFact(name: $0.name, result: $0.result) }
        XCTAssertEqual(byID["PF"]?.fingerprint, byID["PF"]?.replacingPullRequest(unknown).fingerprint)
    }

    func testCheckDetailsFailureKeepsDiscoveredWork() async throws {
        let executor = CheckDetailsExecutor(page: Self.page(Self.pullRequest(id: "PF", state: "FAILURE"), hasNext: false), details: nil)
        let items = try await GitHubPersonalWorkDiscovery(executor: executor).discover(scope: scope()) { _ in }
        XCTAssertEqual(items.first?.pullRequest?.checks, .failure)
        XCTAssertNil(items.first?.pullRequest?.checkRuns)
    }

    private static func pullRequest(id: String, state: String, sha: String = "abc123") -> String {
        node(id: id, type: "PullRequest", author: "a", body: "", pr: true).replacingOccurrences(
            of: #""commits": { "nodes": [{ "commit": { "statusCheckRollup": { "state": "SUCCESS" } } }] }"#,
            with: #""baseRefName": "main", "commits": { "nodes": [{ "commit": { "oid": "\#(sha)", "statusCheckRollup": { "state": "\#(state)" } } }] }"#
        )
    }

    func testPaginationStopsAtPageCap() async throws {
        let executor = FixtureExecutor(pages: Dictionary(uniqueKeysWithValues: ["review-requested", "assignee", "author", "mentions", "commenter"].map {
            ($0, Array(repeating: Self.page(Self.node(id: "\($0)-id"), hasNext: true, cursor: "more"), count: GitHubPersonalWorkDiscovery.maximumPages))
        }))
        _ = try await GitHubPersonalWorkDiscovery(executor: executor).discover(scope: scope()) { _ in }
        let reviewRequestCalls = await executor.callCount(containing: "review-requested")
        XCTAssertEqual(reviewRequestCalls, GitHubPersonalWorkDiscovery.maximumPages)
    }

    func testMarkdownKeepsStructureAndDropsTemplateComments() {
        let source = "## Summary\r\n<!-- template hint -->\n- one  \n- two\n\n\n\nDone"
        XCTAssertEqual(PersonalWorkItem.cleanedMarkdown(source, maximumBytes: 4_000), "## Summary\n\n- one\n- two\n\nDone")
    }

    func testTruncationRespectsUTF8ByteLimitOnCharacterBoundaries() {
        let text = String(repeating: "é👍", count: 2_000)
        let truncated = PersonalWorkItem.truncated(text, maximumBytes: PersonalWorkItem.maximumBodyLength)
        XCTAssertLessThanOrEqual(truncated.utf8.count, PersonalWorkItem.maximumBodyLength)
        XCTAssertTrue(text.hasPrefix(truncated))
        XCTAssertEqual(PersonalWorkItem.truncated("short", maximumBytes: 10), "short")
    }

    func testTransientPageFailureIsRetried() async throws {
        let executor = FlakyExecutor(failures: 2, error: GitHubGraphQLError.invalidResponse, page: Self.page(Self.node(), hasNext: false))
        let items = try await GitHubPersonalWorkDiscovery(executor: executor, retryDelay: { _ in }).discover(scope: scope()) { _ in }
        XCTAssertEqual(items.map(\.id.rawValue), ["I1"])
        let calls = await executor.calls
        XCTAssertEqual(calls, 11) // 9 searches, 2 retried
    }

    func testRepeatedTransientFailureReportsSearchUnavailable() async {
        let executor = FlakyExecutor(failures: .max, error: URLError(.timedOut), page: Self.page(Self.node(), hasNext: false))
        do {
            _ = try await GitHubPersonalWorkDiscovery(executor: executor, retryDelay: { _ in }).discover(scope: scope()) { _ in }
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? PersonalWorkDiscoveryError, .searchUnavailable)
        }
    }

    func testAuthorizationFailureIsNotRetried() async {
        let failure = GitHubGraphQLError.requestFailed(GitHubFailure(kind: .unauthorized, statusCode: 401))
        let executor = FlakyExecutor(failures: .max, error: failure, page: Self.page(Self.node(), hasNext: false))
        do {
            _ = try await GitHubPersonalWorkDiscovery(executor: executor, retryDelay: { _ in }).discover(scope: scope()) { _ in }
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? GitHubGraphQLError, failure)
        }
        XCTAssertFalse(GitHubPersonalWorkDiscovery.isTransient(failure))
        XCTAssertFalse(GitHubPersonalWorkDiscovery.isTransient(CancellationError()))
    }

    func testCancellationStopsDiscovery() async {
        let workspace = scope()
        let task = Task {
            try await GitHubPersonalWorkDiscovery(executor: CancellingExecutor()).discover(scope: workspace) { _ in }
        }
        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
    }

    private func scope() -> WorkspaceScope {
        WorkspaceScope(accountID: AccountID(rawValue: "account")!, organizationID: OrganizationID(rawValue: "org")!, organizationLogin: "octo", viewerLogin: "me")
    }

    func testOnlyRefusedIndividualChecksAreTolerated() {
        func refused(_ path: String...) -> GitHubGraphQLPartialError {
            GitHubGraphQLPartialError(
                message: "Resource not accessible by personal access token",
                path: path.map { GitHubGraphQLErrorPathComponent.field($0) }, type: "FORBIDDEN", extensions: nil
            )
        }
        XCTAssertTrue(GitHubPersonalWorkSearchExecutor.isCheckRunRefusal(
            refused("search", "nodes", "commits", "nodes", "commit", "statusCheckRollup", "contexts", "nodes")
        ))
        XCTAssertFalse(GitHubPersonalWorkSearchExecutor.isCheckRunRefusal(refused("search", "nodes", "commits", "nodes")))
        // A deployment waiting on an environment approval is still running, not failed.
        XCTAssertEqual(GitHubPersonalWorkSearchExecutor.result(status: "waiting", conclusion: nil).fact, .pending)
        XCTAssertEqual(GitHubPersonalWorkSearchExecutor.result(status: "completed", conclusion: "action_required").fact, .failing)
        XCTAssertFalse(GitHubPersonalWorkSearchExecutor.result(status: "completed", conclusion: "success").needsDetail)
        XCTAssertTrue(GitHubPersonalWorkSearchExecutor.isRepositoryName("acme/deploy.tools"))
        XCTAssertFalse(GitHubPersonalWorkSearchExecutor.isRepositoryName("acme/../x"))
    }

    func testWithheldCheckRunsComeFromActionsWithRequiredChecks() async throws {
        let executor = ActionsExecutor(
            page: Self.page(Self.pullRequest(id: "PG", state: "FAILURE", sha: "a1b2c3"), hasNext: false),
            actions: .success(ActionsChecks(checks: [
                CheckRunFact(name: "compliance-approval", result: .failing), CheckRunFact(name: "unit tests", result: .pending),
            ], complete: false)),
            required: ["compliance-approval"]
        )
        let work = try await GitHubPersonalWorkDiscovery(executor: executor).discoverWork(scope: scope()) { _ in }
        XCTAssertEqual(work.missingOptionalPermissions, [])
        XCTAssertEqual(work.items.first?.pullRequest?.checkRuns, [
            CheckRunFact(name: "compliance-approval", result: .failing, isRequired: true),
            CheckRunFact(name: "unit tests", result: .pending, isRequired: false),
        ])
        let lookups = await executor.lookups
        XCTAssertEqual(lookups, ["octo/repo@a1b2c3", "octo/repo#main"])
    }

    func testActionsForbiddenKeepsWorkAndNamesThePermission() async throws {
        let executor = ActionsExecutor(
            page: Self.page(Self.pullRequest(id: "PG", state: "FAILURE", sha: "d4e5f6"), hasNext: false), actions: .failure(GitHubFailure(kind: .forbidden, statusCode: 403)), required: []
        )
        let work = try await GitHubPersonalWorkDiscovery(executor: executor).discoverWork(scope: scope()) { _ in }
        XCTAssertEqual(work.items.count, 1)
        XCTAssertEqual(work.items.first?.pullRequest?.checks, .failure)
        XCTAssertEqual(work.missingOptionalPermissions, ["Actions"])
    }

    private struct CancellingExecutor: PersonalWorkSearchExecuting {
        func search(query: String, cursor: String?) async throws -> PersonalWorkSearchPage {
            try await Task.sleep(for: .seconds(10))
            fatalError("Cancelled discovery must not complete a request")
        }
    }

    private static func node(
        id: String = "I1", type: String = "Issue", title: String = "title", updated: String = "2025-01-02T00:00:00Z",
        repository: String = "octo/repo", archived: Bool = false, author: String? = "author", body: String = "body", pr: Bool = false
    ) -> String {
        let authorJSON = author.map { #"{ "login": "\#($0)" }"# } ?? "null"
        let escapedBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        { "__typename": "\(type)", "id": "\(id)", "number": 1, "title": "\(title)", "url": "https://github.com/\(repository)/issues/1", "state": "OPEN", "createdAt": "2025-01-01T00:00:00Z", "updatedAt": "\(updated)", "body": "\(escapedBody)", "author": \(authorJSON), "repository": { "nameWithOwner": "\(repository)", "isArchived": \(archived) }, "labels": { "nodes": [{ "name": "bug" }] }, "assignees": { "nodes": [{ "login": "me" }] }, "comments": { "nodes": [{ "author": null, "createdAt": "2025-01-01T00:00:00Z", "body": "one" }, { "author": { "login": "alice" }, "createdAt": "2025-01-02T00:00:00Z", "body": "three" }] }\(pr ? #", "isDraft": false, "merged": true, "reviewDecision": "APPROVED", "mergeable": "MERGEABLE", "additions": 2, "deletions": 1, "reviewRequests": { "nodes": [{ "requestedReviewer": { "__typename": "User", "login": "me" } }, { "requestedReviewer": { "__typename": "Team", "combinedSlug": "octo/team" } }] }, "latestReviews": { "nodes": [{ "author": null, "state": "APPROVED", "submittedAt": null }] }, "commits": { "nodes": [{ "commit": { "statusCheckRollup": { "state": "SUCCESS" } } }] }, "reviewThreads": { "nodes": [{ "isResolved": false }, { "isResolved": true }] }"# : "") }
        """
    }

    private static func page(_ node: String, hasNext: Bool, cursor: String? = nil) -> PersonalWorkSearchPage {
        let cursorJSON = cursor.map { #""\#($0)""# } ?? "null"
        let json = #"{ "search": { "pageInfo": { "hasNextPage": \#(hasNext), "endCursor": \#(cursorJSON) }, "nodes": [\#(node)] } }"#
        do {
            return try JSONDecoder.github.decode(PersonalWorkSearchPage.self, from: Data(json.utf8))
        } catch {
            fatalError("\(error): \(json)")
        }
    }
}

private actor FixtureExecutor: PersonalWorkSearchExecuting {
    private var pages: [String: [PersonalWorkSearchPage]]
    private var calls: [String] = []

    init(pages: [String: [PersonalWorkSearchPage]]) {
        self.pages = pages
    }

    func search(query: String, cursor: String?) async throws -> PersonalWorkSearchPage {
        let key = ["review-requested", "assignee", "author", "mentions", "commenter"].first { query.contains($0) }!
        calls.append(key)
        // Each relationship searches issues and pull requests separately; unscripted searches find nothing.
        guard var remaining = pages[key], !remaining.isEmpty else {
            return try JSONDecoder().decode(
                PersonalWorkSearchPage.self,
                from: Data(#"{ "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [] } }"#.utf8)
            )
        }
        let page = remaining.removeFirst()
        pages[key] = remaining
        return page
    }

    func callCount(containing value: String) -> Int {
        calls.filter { $0.contains(value) }.count
    }
}

/// Returns one page for pull request searches and scripted check details (`nil` throws).
private actor CheckDetailsExecutor: PersonalWorkSearchExecuting {
    private let page: PersonalWorkSearchPage
    private let details: CheckDetails?
    private(set) var requested: [[String]] = []

    init(page: PersonalWorkSearchPage, details: CheckDetails?) {
        self.page = page
        self.details = details
    }

    func search(query: String, cursor: String?) async throws -> PersonalWorkSearchPage {
        let empty = #"{ "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [] } }"#
        guard query.contains("is:pr"), query.contains("assignee") else {
            return try JSONDecoder().decode(PersonalWorkSearchPage.self, from: Data(empty.utf8))
        }
        return page
    }

    func checkDetails(pullRequestIDs: [GitHubNodeID]) async throws -> CheckDetails {
        requested.append(pullRequestIDs.map(\.rawValue))
        guard let details else { throw GitHubGraphQLError.partialResponse }
        return details
    }
}

/// A fine-grained token's view: check runs withheld, GitHub Actions scripted.
private actor ActionsExecutor: PersonalWorkSearchExecuting {
    private let page: PersonalWorkSearchPage
    private let actions: Result<ActionsChecks, GitHubFailure>
    private let required: Set<String>
    private(set) var lookups: [String] = []

    init(page: PersonalWorkSearchPage, actions: Result<ActionsChecks, GitHubFailure>, required: Set<String>) {
        self.page = page
        self.actions = actions
        self.required = required
    }

    func search(query: String, cursor: String?) async throws -> PersonalWorkSearchPage {
        let empty = #"{ "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [] } }"#
        guard query.contains("is:pr"), query.contains("assignee") else {
            return try JSONDecoder().decode(PersonalWorkSearchPage.self, from: Data(empty.utf8))
        }
        return page
    }

    func checkDetails(pullRequestIDs: [GitHubNodeID]) async throws -> CheckDetails {
        CheckDetails(checks: [:], withheld: true)
    }

    func actionsChecks(repository: String, headSHA: String) async throws -> ActionsChecks {
        lookups.append("\(repository)@\(headSHA)")
        return try actions.get()
    }

    func requiredCheckNames(repository: String, branch: String) async throws -> Set<String> {
        lookups.append("\(repository)#\(branch)")
        return required
    }
}

/// Fails the first `failures` calls (across all queries), then returns `page`.
private actor FlakyExecutor: PersonalWorkSearchExecuting {
    private var remainingFailures: Int
    private let error: Error
    private let page: PersonalWorkSearchPage
    private(set) var calls = 0

    init(failures: Int, error: Error, page: PersonalWorkSearchPage) {
        remainingFailures = failures
        self.error = error
        self.page = page
    }

    func search(query: String, cursor: String?) async throws -> PersonalWorkSearchPage {
        calls += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw error
        }
        return page
    }
}

private extension JSONDecoder {
    static var github: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error")
    } catch is CancellationError {
    } catch {
        XCTFail("Expected cancellation, got \(error)")
    }
}
