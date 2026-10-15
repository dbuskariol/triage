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
        XCTAssertEqual(
            try GitHubPersonalWorkDiscovery.searchQueries(for: .commented, scope: scope, now: date),
            [
                "org:octo is:issue is:open archived:false commenter:me updated:>=2024-11-16",
                "org:octo is:pr is:open archived:false commenter:me updated:>=2024-11-16",
                "org:octo is:discussion commenter:me updated:>=2024-11-16",
            ]
        )
        XCTAssertEqual(
            try GitHubPersonalWorkDiscovery.searchQueries(for: .authored, scope: scope, now: date).filter { $0.contains("is:discussion") },
            [
                "org:octo is:discussion is:open author:me",
                "org:octo is:discussion is:closed author:me updated:>=2024-11-16",
            ]
        )
        XCTAssertEqual(try GitHubPersonalWorkDiscovery.searchQueries(for: .watching, scope: scope, now: date), [])
        // Fine-grained tokens find nothing unless every search names a type.
        // Discussion search rejects archived:false, so those queries omit it.
        for relationship in WorkRelationship.allCases {
            for query in try GitHubPersonalWorkDiscovery.searchQueries(for: relationship, scope: scope, now: date) {
                XCTAssertTrue(
                    query.contains(" is:issue ") || query.contains(" is:pr ") || query.contains(" is:discussion "),
                    query
                )
                if query.contains(" is:discussion ") {
                    XCTAssertFalse(query.contains("archived:"), query)
                }
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

    func testDiscussionNodesKeepCategoryAndClosedState() async throws {
        let executor = FixtureExecutor(pages: [
            "commenter": [Self.page(Self.discussionNode(), hasNext: false)]
        ])
        let items = try await GitHubPersonalWorkDiscovery(
            executor: executor, now: { Date(timeIntervalSince1970: 1_736_899_200) }
        ).discover(scope: scope()) { _ in }
        let discussion = try XCTUnwrap(items.first { $0.id.rawValue == "D1" })
        XCTAssertEqual(discussion.kind, .discussion)
        XCTAssertEqual(discussion.state, .closed)
        XCTAssertEqual(discussion.labels, ["General"])
        XCTAssertEqual(discussion.relationships, [.commented])
        XCTAssertTrue(discussion.assignees.isEmpty)
        XCTAssertNil(discussion.pullRequest)
    }

    func testUnreadDiscussionInboxMergesWithSearch() async throws {
        let watched = try XCTUnwrap(Self.page(Self.discussionNode(id: "D2", number: 9, title: "Watched"), hasNext: false).search.nodes.compactMap { $0 }.first)
        let joined = try XCTUnwrap(Self.page(Self.discussionNode(), hasNext: false).search.nodes.compactMap { $0 }.first)
        let executor = FixtureExecutor(pages: [
            "commenter": [Self.page(Self.discussionNode(), hasNext: false)]
        ])
        let items = try await GitHubPersonalWorkDiscovery(
            executor: executor,
            inbox: FixtureInbox(hits: [
                InboxDiscussion(node: watched, relationship: .watching),
                InboxDiscussion(node: joined, relationship: .watching),
            ]),
            now: { Date(timeIntervalSince1970: 1_736_899_200) }
        ).discover(scope: scope()) { _ in }
        let existing = try XCTUnwrap(items.first { $0.id.rawValue == "D1" })
        XCTAssertEqual(existing.relationships, [.commented, .watching])
        let added = try XCTUnwrap(items.first { $0.id.rawValue == "D2" })
        XCTAssertEqual(added.kind, .discussion)
        XCTAssertEqual(added.relationships, [.watching])
    }

    func testReadNotificationStillKeepsARecentWatchedDiscussion() {
        let now = Date(timeIntervalSince1970: 1_736_899_200)
        XCTAssertTrue(GitHubDiscussionInbox.shouldKeep(
            lastSeenAt: now.addingTimeInterval(-86_400), updatedAt: now.addingTimeInterval(-50 * 86_400), now: now
        ))
        XCTAssertFalse(GitHubDiscussionInbox.shouldKeep(
            lastSeenAt: now.addingTimeInterval(-61 * 86_400), updatedAt: now.addingTimeInterval(-61 * 86_400), now: now
        ))
        XCTAssertTrue(GitHubDiscussionInbox.shouldKeep(
            lastSeenAt: now.addingTimeInterval(-90 * 86_400), updatedAt: now.addingTimeInterval(-2 * 86_400), now: now
        ))
    }

    func testRememberedDiscussionSurvivesAnEmptyInbox() async throws {
        let now = Date(timeIntervalSince1970: 1_736_899_200)
        let memory = MemoryInbox()
        try await memory.remember([WatchedDiscussionRef(
            owner: "octo", name: "repo", number: 9, lastSeenAt: now.addingTimeInterval(-86_400)
        )])
        let session = DiscussionRouteSession(notificationsStatus: 200, updatedAt: "2025-01-02T00:00:00Z")
        let inbox = try GitHubDiscussionInbox(
            rest: GitHubRESTClient(transport: try GitHubRESTTransport(session: session), credential: SecretValue("token")),
            graphql: GitHubGraphQLClient(session: session, credential: SecretValue("token")),
            organizationLogin: "octo",
            organizationDatabaseID: nil,
            memory: memory,
            now: { now }
        )
        let hits = try await inbox.unreadDiscussions()
        XCTAssertEqual(hits.map(\.node.id.rawValue), ["D9"])
        XCTAssertEqual(hits.map(\.relationship), [.watching])
        let kept = try await memory.refs()
        XCTAssertEqual(kept.map(\.number), [9])
    }

    func testForbiddenInboxStillKeepsRememberedDiscussions() async throws {
        let now = Date(timeIntervalSince1970: 1_736_899_200)
        let memory = MemoryInbox()
        try await memory.remember([WatchedDiscussionRef(
            owner: "octo", name: "repo", number: 9, lastSeenAt: now.addingTimeInterval(-86_400)
        )])
        let session = DiscussionRouteSession(notificationsStatus: 403, updatedAt: "2025-01-02T00:00:00Z")
        let inbox = try GitHubDiscussionInbox(
            rest: GitHubRESTClient(transport: try GitHubRESTTransport(session: session), credential: SecretValue("token")),
            graphql: GitHubGraphQLClient(session: session, credential: SecretValue("token")),
            organizationLogin: "octo",
            organizationDatabaseID: nil,
            memory: memory,
            now: { now }
        )
        let hits = try await inbox.unreadDiscussions()
        XCTAssertEqual(hits.map(\.node.id.rawValue), ["D9"])
        let kept = try await memory.refs()
        XCTAssertEqual(kept.map(\.number), [9])
    }

    func testQuietRememberedDiscussionIsForgotten() async throws {
        let now = Date(timeIntervalSince1970: 1_736_899_200)
        let memory = MemoryInbox()
        try await memory.remember([WatchedDiscussionRef(
            owner: "octo", name: "repo", number: 9, lastSeenAt: now.addingTimeInterval(-90 * 86_400)
        )])
        let session = DiscussionRouteSession(notificationsStatus: 200, updatedAt: "2024-10-01T00:00:00Z")
        let inbox = try GitHubDiscussionInbox(
            rest: GitHubRESTClient(transport: try GitHubRESTTransport(session: session), credential: SecretValue("token")),
            graphql: GitHubGraphQLClient(session: session, credential: SecretValue("token")),
            organizationLogin: "octo",
            organizationDatabaseID: nil,
            memory: memory,
            now: { now }
        )
        let hits = try await inbox.unreadDiscussions()
        XCTAssertTrue(hits.isEmpty)
        let kept = try await memory.refs()
        XCTAssertTrue(kept.isEmpty)
    }

    func testNotificationReasonsAndDiscussionURLs() throws {
        XCTAssertEqual(GitHubDiscussionInbox.relationship(forNotificationReason: "subscribed"), .watching)
        XCTAssertEqual(GitHubDiscussionInbox.relationship(forNotificationReason: "manual"), .watching)
        XCTAssertEqual(GitHubDiscussionInbox.relationship(forNotificationReason: "state_change"), .watching)
        XCTAssertEqual(GitHubDiscussionInbox.relationship(forNotificationReason: "team_mention"), .mentioned)
        XCTAssertEqual(GitHubDiscussionInbox.relationship(forNotificationReason: "author"), .authored)
        XCTAssertEqual(GitHubDiscussionInbox.relationship(forNotificationReason: "comment"), .commented)
        XCTAssertNil(GitHubDiscussionInbox.relationship(forNotificationReason: "ci_activity"))
        let api = URL(string: "https://api.github.com/repos/Octo/Repo/discussions/12")!
        XCTAssertEqual(GitHubDiscussionInbox.discussion(in: api)?.owner, "Octo")
        XCTAssertEqual(GitHubDiscussionInbox.discussion(in: api)?.number, 12)
        XCTAssertEqual(
            GitHubDiscussionInbox.discussion(in: URL(string: "https://github.com/octo/repo/discussions/3"))?.name,
            "repo"
        )
        XCTAssertNil(GitHubDiscussionInbox.discussion(in: URL(string: "https://api.github.com/repos/octo/repo/issues/3")))
        XCTAssertNil(GitHubDiscussionInbox.discussion(in: nil))
    }

    func testMissingNotificationScopeSkipsTheInbox() throws {
        XCTAssertTrue(try GitHubDiscussionInbox.missingScope(
            GitHubFailure(kind: .forbidden, statusCode: 403),
            organizationLogin: "octo", organizationDatabaseID: 7
        ))
        XCTAssertFalse(try GitHubDiscussionInbox.missingScope(
            GitHubFailure(kind: .unauthorized, statusCode: 401),
            organizationLogin: "octo", organizationDatabaseID: 7
        ))
        XCTAssertThrowsError(try GitHubDiscussionInbox.missingScope(
            GitHubFailure(
                kind: .forbidden, statusCode: 403,
                ssoHeader: .partialResults([7])
            ),
            organizationLogin: "octo", organizationDatabaseID: 7
        ))
    }

    func testForbiddenInboxDoesNotBlankSearch() async throws {
        let executor = FixtureExecutor(pages: ["author": [Self.page(Self.node(), hasNext: false)]])
        let items = try await GitHubPersonalWorkDiscovery(
            executor: executor,
            inbox: ThrowingInbox(error: GitHubFailure(kind: .forbidden, statusCode: 403))
        ).discover(scope: scope()) { _ in }
        XCTAssertEqual(items.map(\.id.rawValue), ["I1"])
    }

    func testMissingDiscussionPermissionDoesNotBlankOtherWork() async throws {
        let executor = DiscussionPermissionExecutor(issue: Self.page(Self.node(), hasNext: false))
        let items = try await GitHubPersonalWorkDiscovery(executor: executor).discover(scope: scope()) { _ in }
        XCTAssertEqual(items.map(\.id.rawValue), ["I1"])
        let skipped = await executor.discussionCalls
        XCTAssertGreaterThan(skipped, 0)
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
        XCTAssertEqual(calls, 14) // 12 searches, 2 retried
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

    private static func discussionNode(id: String = "D1", number: Int = 2150, title: String = "Offsite") -> String {
        """
        { "__typename": "Discussion", "id": "\(id)", "number": \(number), "title": "\(title)", "url": "https://github.com/octo/repo/discussions/\(number)", "createdAt": "2025-01-01T00:00:00Z", "updatedAt": "2025-01-02T00:00:00Z", "body": "hello", "closed": true, "author": { "login": "me" }, "repository": { "nameWithOwner": "octo/repo", "isArchived": false }, "category": { "name": "General" }, "labels": { "nodes": [] }, "comments": { "nodes": [{ "author": { "login": "me" }, "createdAt": "2025-01-02T00:00:00Z", "body": "reply" }] } }
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

private actor MemoryInbox: WatchedDiscussionMemory {
    private var values: [WatchedDiscussionRef] = []
    func refs() async throws -> [WatchedDiscussionRef] { values }
    func remember(_ refs: [WatchedDiscussionRef]) async throws {
        for ref in refs {
            values.removeAll { $0.owner == ref.owner && $0.name == ref.name && $0.number == ref.number }
            values.append(ref)
        }
    }
    func forget(_ refs: [WatchedDiscussionRef]) async throws {
        values.removeAll { current in
            refs.contains { $0.owner == current.owner && $0.name == current.name && $0.number == current.number }
        }
    }
}

private struct DiscussionRouteSession: HTTPSession {
    let notificationsStatus: Int
    let updatedAt: String

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let body: Data
        let status: Int
        if url.path == "/notifications" {
            body = Data("[]".utf8)
            status = notificationsStatus
        } else {
            body = Data("""
            {"data":{"repository":{"discussion":{"__typename":"Discussion","id":"D9","number":9,"title":"Watched","url":"https://github.com/octo/repo/discussions/9","createdAt":"2025-01-01T00:00:00Z","updatedAt":"\(updatedAt)","body":"hello","closed":false,"author":{"login":"ada"},"repository":{"nameWithOwner":"octo/repo","isArchived":false},"category":{"name":"General"},"labels":{"nodes":[]},"comments":{"nodes":[]}}},"rateLimit":{"cost":1,"remaining":4000,"resetAt":"2025-01-16T00:00:00Z"}}}
            """.utf8)
            status = 200
        }
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct FixtureInbox: DiscussionInboxFetching {
    let hits: [InboxDiscussion]
    func unreadDiscussions() async throws -> [InboxDiscussion] { hits }
}

private struct ThrowingInbox: DiscussionInboxFetching {
    let error: GitHubFailure
    func unreadDiscussions() async throws -> [InboxDiscussion] {
        if try GitHubDiscussionInbox.missingScope(error, organizationLogin: "octo", organizationDatabaseID: 7) {
            return []
        }
        throw error
    }
}

private actor DiscussionPermissionExecutor: PersonalWorkSearchExecuting {
    private let issue: PersonalWorkSearchPage
    private(set) var discussionCalls = 0

    init(issue: PersonalWorkSearchPage) {
        self.issue = issue
    }

    func search(query: String, cursor: String?) async throws -> PersonalWorkSearchPage {
        if query.contains(" is:discussion ") {
            discussionCalls += 1
            throw PersonalWorkDiscoveryError.missingTokenPermissions(["Discussions"])
        }
        return issue
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
