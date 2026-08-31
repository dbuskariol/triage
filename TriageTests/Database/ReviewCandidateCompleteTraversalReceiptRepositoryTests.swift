import Foundation
import GRDB
import XCTest
@testable import Triage

final class ReviewCandidateCompleteTraversalReceiptRepositoryTests: XCTestCase {
    func testMigratedSchemaProvidesReceiptTablesAndDurableRawProtection() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }

        try await fixture.vault.read { database in
            XCTAssertTrue(try database.tableExists("review_candidate_complete_traversal_receipts"))
            XCTAssertTrue(try database.tableExists("review_candidate_complete_traversal_segments"))
            XCTAssertTrue(try database.tableExists("review_candidate_complete_traversal_pages"))
            let trigger = try String.fetchOne(
                database,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?",
                arguments: ["review_candidate_complete_traversal_protect_snapshot_update"]
            )
            XCTAssertTrue(trigger?.contains("provenance is immutable") == true)
        }
    }

    func testReviewReceiptPersistsCompleteTerminalSegmentsAndRawBindings() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        let traversal = fixture.reviewTraversal()

        let token = try await fixture.repository.persist(traversal)

        try await fixture.vault.read { database in
            try ReviewCandidateCompleteTraversalReceiptRepository.validate(token, in: database)
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_complete_traversal_receipts"), 1)
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_complete_traversal_segments"), 2)
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_complete_traversal_pages"), 3)
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots"), 3)
        }
    }

    func testRejectsArbitraryOrCrossEndpointRESTReceiptPages() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        let source = fixture.reviewTraversal()
        let requestedKey = "GET /repos/acme/repo/pulls/7/requested_reviewers"
        for invalidHistoryPage in [
            fixture.page(ordinal: 1, requestKey: "GET /arbitrary", terminal: true),
            fixture.page(ordinal: 1, requestKey: requestedKey, terminal: true)
        ] {
            let traversal = ReviewCandidateCompleteTraversal(
                scope: source.scope, feature: .reviews, streamID: source.streamID,
                candidate: source.candidate, candidateSourceRevision: source.candidateSourceRevision,
                parserVersion: source.parserVersion, observedAt: source.observedAt,
                normalizedDigest: source.normalizedDigest,
                segments: [
                    .init(kind: .reviewHistory, pages: [invalidHistoryPage]),
                    source.segments[1]
                ]
            )
            await XCTAssertThrowsErrorAsync({ try await fixture.repository.persist(traversal) }) { error in
                XCTAssertEqual(error as? ReviewCandidateCompleteTraversalReceiptRepositoryError, .invalidRawPage)
            }
        }
    }

    func testRejectsGraphQLCommentPageWhosePayloadNamesDifferentThread() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        let threadA = GitHubNodeID(rawValue: "THREAD_A")!
        let root = ReviewCandidateTraversalPage(
            ordinal: 1, rawSnapshotID: .make(),
            requestIdentity: .init(scope: fixture.scope, feature: .reviewThreads, streamID: fixture.threadStreamID, requestKey: "graphql:TriagePullRequestReviewThreads/pull-request=RECEIPT_PR/after=none"),
            endpoint: "graphql:TriagePullRequestReviewThreads/page=1",
            payload: Data("{\"data\":{\"node\":{\"id\":\"RECEIPT_PR\",\"reviewThreads\":{\"nodes\":[{\"id\":\"THREAD_A\"}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}".utf8),
            isTerminal: true
        )
        let mismatchedComment = ReviewCandidateTraversalPage(
            ordinal: 1, rawSnapshotID: .make(),
            requestIdentity: .init(scope: fixture.scope, feature: .reviewThreads, streamID: fixture.threadStreamID, requestKey: "graphql:TriagePullRequestReviewThreadComments/thread=THREAD_A/after=none"),
            endpoint: "graphql:TriagePullRequestReviewThreadComments/thread=THREAD_A/page=1",
            payload: Data("{\"data\":{\"node\":{\"id\":\"THREAD_B\",\"comments\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}".utf8),
            isTerminal: true
        )
        let traversal = ReviewCandidateCompleteTraversal(
            scope: fixture.scope, feature: .reviewThreads, streamID: fixture.threadStreamID,
            candidate: fixture.candidate, candidateSourceRevision: "rev-1", parserVersion: 1,
            observedAt: fixture.date, normalizedDigest: Data(repeating: 4, count: 32),
            discoveredThreadNodeIDs: [threadA],
            segments: [
                .init(kind: .reviewThreads, pages: [root]),
                .init(kind: .threadComments, parentThreadNodeID: threadA, pages: [mismatchedComment])
            ]
        )

        await XCTAssertThrowsErrorAsync({ try await fixture.repository.persist(traversal) }) { error in
            XCTAssertEqual(error as? ReviewCandidateCompleteTraversalReceiptRepositoryError, .invalidRawPage)
        }
    }

    func testRejectsGraphQLCursorChainAndTerminalPageInfoMismatches() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        func rootPage(ordinal: Int, after: String, hasNextPage: Bool, endCursor: String?) -> ReviewCandidateTraversalPage {
            let endCursorJSON = endCursor.map { "\"\($0)\"" } ?? "null"
            return .init(
                ordinal: ordinal, rawSnapshotID: .make(),
                requestIdentity: .init(scope: fixture.scope, feature: .reviewThreads, streamID: fixture.threadStreamID, requestKey: "graphql:TriagePullRequestReviewThreads/pull-request=RECEIPT_PR/after=\(after)"),
                endpoint: "graphql:TriagePullRequestReviewThreads/page=\(ordinal)",
                payload: Data("{\"data\":{\"node\":{\"id\":\"RECEIPT_PR\",\"reviewThreads\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":\(hasNextPage),\"endCursor\":\(endCursorJSON)}}}}}".utf8),
                isTerminal: ordinal == 2
            )
        }
        let cursorMismatch = ReviewCandidateCompleteTraversal(
            scope: fixture.scope, feature: .reviewThreads, streamID: fixture.threadStreamID,
            candidate: fixture.candidate, candidateSourceRevision: "rev-1", parserVersion: 1,
            observedAt: fixture.date, normalizedDigest: Data(repeating: 3, count: 32),
            segments: [
                .init(kind: .reviewThreads, pages: [
                    rootPage(ordinal: 1, after: "none", hasNextPage: true, endCursor: "cursor-one"),
                    rootPage(ordinal: 2, after: Data("wrong".utf8).base64EncodedString(), hasNextPage: false, endCursor: nil)
                ])
            ]
        )
        let terminalMismatch = ReviewCandidateCompleteTraversal(
            scope: fixture.scope, feature: .reviewThreads, streamID: fixture.threadStreamID,
            candidate: fixture.candidate, candidateSourceRevision: "rev-1", parserVersion: 1,
            observedAt: fixture.date, normalizedDigest: Data(repeating: 2, count: 32),
            segments: [
                .init(kind: .reviewThreads, pages: [
                    ReviewCandidateTraversalPage(
                        ordinal: 1, rawSnapshotID: .make(),
                        requestIdentity: .init(scope: fixture.scope, feature: .reviewThreads, streamID: fixture.threadStreamID, requestKey: "graphql:TriagePullRequestReviewThreads/pull-request=RECEIPT_PR/after=none"),
                        endpoint: "graphql:TriagePullRequestReviewThreads/page=1",
                        payload: Data("{\"data\":{\"node\":{\"id\":\"RECEIPT_PR\",\"reviewThreads\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"cursor-one\"}}}}}".utf8),
                        isTerminal: true
                    )
                ])
            ]
        )

        for traversal in [cursorMismatch, terminalMismatch] {
            await XCTAssertThrowsErrorAsync({ try await fixture.repository.persist(traversal) }) { error in
                XCTAssertEqual(error as? ReviewCandidateCompleteTraversalReceiptRepositoryError, .invalidRawPage)
            }
        }
    }

    func testPageGapRollsBackAllRawAndReceiptWrites() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        let source = fixture.reviewTraversal()
        let invalid = ReviewCandidateCompleteTraversal(
            id: source.id, scope: source.scope, feature: source.feature, streamID: source.streamID,
            candidate: source.candidate, candidateSourceRevision: source.candidateSourceRevision,
            parserVersion: source.parserVersion, observedAt: source.observedAt,
            normalizedDigest: source.normalizedDigest,
            segments: [
                .init(kind: .reviewHistory, pages: [
                    fixture.page(ordinal: 1, requestKey: "reviews/1", terminal: false),
                    fixture.page(ordinal: 3, requestKey: "reviews/3", terminal: true)
                ]),
                .init(kind: .requestedReviewers, pages: [
                    fixture.page(ordinal: 1, requestKey: "requested", terminal: true)
                ])
            ]
        )

        await XCTAssertThrowsErrorAsync({ try await fixture.repository.persist(invalid) }) { error in
            XCTAssertEqual(error as? ReviewCandidateCompleteTraversalReceiptRepositoryError, .invalidTraversal)
        }
        try await fixture.vault.read { database in
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_complete_traversal_receipts"), 0)
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots"), 0)
        }
    }

    func testTokenStopsAuthorizingAfterCandidateSourceRevisionChanges() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        let token = try await fixture.repository.persist(fixture.reviewTraversal())
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE github_nodes SET source_revision = 'rev-2' WHERE github_node_id = ?",
                arguments: [fixture.candidate.nodeID.rawValue]
            )
            XCTAssertThrowsError(
                try ReviewCandidateCompleteTraversalReceiptRepository.validate(token, in: database)
            ) { error in
                XCTAssertEqual(error as? ReviewCandidateCompleteTraversalReceiptRepositoryError, .staleCandidateSourceRevision)
            }
        }
    }

    func testThreadReceiptRequiresExactlyOneTerminalCommentSegmentPerDiscoveredThread() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        let threadA = GitHubNodeID(rawValue: "THREAD_A")!
        let threadB = GitHubNodeID(rawValue: "THREAD_B")!
        let traversal = ReviewCandidateCompleteTraversal(
            scope: fixture.scope, feature: .reviewThreads, streamID: fixture.threadStreamID,
            candidate: fixture.candidate, candidateSourceRevision: "rev-1", parserVersion: 1,
            observedAt: fixture.date, normalizedDigest: Data(repeating: 9, count: 32),
            discoveredThreadNodeIDs: [threadA, threadB],
            segments: [
                .init(kind: .reviewThreads, pages: [fixture.threadPage(ordinal: 1, key: "threads", terminal: true)]),
                .init(kind: .threadComments, parentThreadNodeID: threadA, pages: [fixture.threadPage(ordinal: 1, key: "thread-a", terminal: true)])
            ]
        )

        await XCTAssertThrowsErrorAsync({ try await fixture.repository.persist(traversal) }) { error in
            XCTAssertEqual(error as? ReviewCandidateCompleteTraversalReceiptRepositoryError, .invalidTraversal)
        }
    }

    func testRejectsDuplicateRawPageIdentityBeforeAnyPublication() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        let thread = GitHubNodeID(rawValue: "DUPLICATE_THREAD")!
        let sharedPage = fixture.threadPage(ordinal: 1, key: "threads", terminal: true)
        let traversal = ReviewCandidateCompleteTraversal(
            scope: fixture.scope, feature: .reviewThreads, streamID: fixture.threadStreamID,
            candidate: fixture.candidate, candidateSourceRevision: "rev-1", parserVersion: 1,
            observedAt: fixture.date, normalizedDigest: Data(repeating: 6, count: 32),
            discoveredThreadNodeIDs: [thread],
            segments: [
                .init(kind: .reviewThreads, pages: [sharedPage]),
                .init(kind: .threadComments, parentThreadNodeID: thread, pages: [sharedPage])
            ]
        )

        await XCTAssertThrowsErrorAsync({ try await fixture.repository.persist(traversal) }) { error in
            XCTAssertEqual(error as? ReviewCandidateCompleteTraversalReceiptRepositoryError, .invalidTraversal)
        }
        try await fixture.vault.read { database in
            XCTAssertEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots"), 0)
        }
    }

    func testRejectsDuplicateDiscoveredThreadIdentityBeforeAnyPublication() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        let thread = GitHubNodeID(rawValue: "DUPLICATE_THREAD")!
        let traversal = ReviewCandidateCompleteTraversal(
            scope: fixture.scope, feature: .reviewThreads, streamID: fixture.threadStreamID,
            candidate: fixture.candidate, candidateSourceRevision: "rev-1", parserVersion: 1,
            observedAt: fixture.date, normalizedDigest: Data(repeating: 5, count: 32),
            discoveredThreadNodeIDs: [thread, thread],
            segments: [
                .init(kind: .reviewThreads, pages: [fixture.threadPage(ordinal: 1, key: "threads", terminal: true)]),
                .init(kind: .threadComments, parentThreadNodeID: thread, pages: [fixture.threadPage(ordinal: 1, key: "thread", terminal: true)])
            ]
        )

        await XCTAssertThrowsErrorAsync({ try await fixture.repository.persist(traversal) }) { error in
            XCTAssertEqual(error as? ReviewCandidateCompleteTraversalReceiptRepositoryError, .invalidTraversal)
        }
    }

    func testRawEvidenceIsImmutableAndPinnedByReceiptForeignKey() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        let traversal = fixture.reviewTraversal()
        _ = try await fixture.repository.persist(traversal)
        let page = traversal.segments[0].pages[0]

        try await fixture.vault.write { database in
            XCTAssertThrowsError(
                try RawAPISnapshotRepository.save(
                    .init(
                        id: page.rawSnapshotID, accountID: fixture.accountID,
                        githubNodeID: fixture.candidate.nodeID, endpoint: page.endpoint,
                        eTag: page.eTag, lastModified: page.lastModified, parserVersion: 1,
                        observedAt: fixture.date, payload: Data("tampered".utf8),
                        requestIdentity: page.requestIdentity
                    ),
                    in: database
                )
            ) { error in
                XCTAssertEqual(error as? RawAPISnapshotRepositoryError, .immutableSnapshotConflict)
            }
            XCTAssertThrowsError(
                try database.execute(
                    sql: "DELETE FROM raw_api_snapshots WHERE id = ?",
                    arguments: [page.rawSnapshotID.rawValue]
                )
            )
        }
    }

    func testReceiptTokenCannotBeReplayedUnderDifferentAuthorityScope() async throws {
        let fixture = try await ReviewTraversalReceiptFixture()
        defer { fixture.remove() }
        let token = try await fixture.repository.persist(fixture.reviewTraversal())
        let replay = ReviewCandidateCompleteTraversalReceiptToken(
            id: token.id,
            scope: .init(
                accountID: fixture.accountID, organizationID: fixture.organizationID,
                credentialRevision: CredentialRevision(rawValue: "credential-2")!,
                capabilityRevision: fixture.scope.capabilityRevision
            ),
            feature: token.feature, streamID: token.streamID,
            candidateNodeID: token.candidateNodeID, repositoryID: token.repositoryID,
            candidateSourceRevision: token.candidateSourceRevision
        )

        try await fixture.vault.read { database in
            XCTAssertThrowsError(
                try ReviewCandidateCompleteTraversalReceiptRepository.validate(replay, in: database)
            ) { error in
                XCTAssertEqual(error as? ReviewCandidateCompleteTraversalReceiptRepositoryError, .staleSynchronizationScope)
            }
        }
    }
}

private final class ReviewTraversalReceiptFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "receipt-org")!
    let repositoryID = RepositoryID(rawValue: "receipt-repository")!
    let streamID = SyncStreamID(rawValue: "receipt-reviews")!
    let threadStreamID = SyncStreamID(rawValue: "receipt-threads")!
    let date = Date(timeIntervalSinceReferenceDate: 50_000)
    let vault: AccountVault
    let repository: ReviewCandidateCompleteTraversalReceiptRepository
    let candidate = PullRequestReviewCandidate(
        nodeID: GitHubNodeID(rawValue: "RECEIPT_PR")!,
        repositoryID: RepositoryID(rawValue: "receipt-repository")!,
        repository: try! GitHubRepositoryPath(owner: "acme", repository: "repo"),
        number: 7
    )

    var scope: SynchronizationScope {
        .init(accountID: accountID, organizationID: organizationID,
              credentialRevision: CredentialRevision(rawValue: "credential-1")!,
              capabilityRevision: CapabilityRevision(rawValue: "capability-1")!)
    }

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(accountID: accountID, vaultKey: try VaultKey.generate())
        repository = ReviewCandidateCompleteTraversalReceiptRepository(vault: vault)
        try await AccountRepository(vault: vault).save(
            GitHubAccount(id: accountID, githubUserID: 1, nodeID: GitHubNodeID(rawValue: "RECEIPT_USER")!, login: "octocat", authenticationKind: .oauth, credentialID: .make(), credentialStatus: .active, createdAt: date, lastValidatedAt: date),
            credentialRevision: scope.credentialRevision
        )
        try await AccountRepository(vault: vault).save(
            GitHubOrganization(id: organizationID, githubOrganizationID: 2, nodeID: GitHubNodeID(rawValue: "RECEIPT_ORG")!, login: "acme"),
            access: OrganizationAccess(accountID: accountID, organizationID: organizationID, state: .available, capabilityRevision: scope.capabilityRevision, capabilities: [], checkedAt: date), selectedAt: date
        )
        for (id, feature) in [(streamID, CoverageFeature.reviews), (threadStreamID, .reviewThreads)] {
            try await SyncStreamRepository(vault: vault).save(.init(id: id, accountID: accountID, organizationID: organizationID, feature: feature, highWater: nil, lastSuccessfulAt: nil, lastAttemptAt: nil, status: .partial, failureDetail: nil))
        }
        try await vault.write { database in
            try database.execute(sql: """
                INSERT INTO repositories (id, organization_id, github_repository_id, github_node_id, owner_login, name, is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms)
                VALUES (?, ?, 'repo-id', 'RECEIPT_REPO', 'acme', 'repo', 1, 0, 0, 'https://github.com/acme/repo', ?, NULL)
                """, arguments: [repositoryID.rawValue, organizationID.rawValue, Self.milliseconds(date)])
            try database.execute(sql: "INSERT INTO account_repository_access (account_id, repository_id, access_state, observed_at_ms) VALUES (?, ?, 'available', ?)", arguments: [accountID.rawValue, repositoryID.rawValue, Self.milliseconds(date)])
            try database.execute(sql: """
                INSERT INTO github_nodes (github_node_id, account_id, organization_id, repository_id, kind, numeric_id, number, title, state, html_url, body_markdown, author_id, created_at_ms, updated_at_ms, closed_at_ms, merged_at_ms, source_revision, last_observed_at_ms, accessibility_state)
                VALUES (?, ?, ?, ?, 'pull_request', NULL, 7, 'PR', 'open', 'https://github.com/acme/repo/pull/7', NULL, NULL, ?, ?, NULL, NULL, 'rev-1', ?, 'accessible')
                """, arguments: [candidate.nodeID.rawValue, accountID.rawValue, organizationID.rawValue, repositoryID.rawValue, Self.milliseconds(date), Self.milliseconds(date), Self.milliseconds(date)])
            try database.execute(sql: "INSERT INTO pull_requests (github_node_id, is_draft, mergeable_state, head_ref, base_ref, review_decision, unresolved_thread_count, latest_commit_at_ms, updated_at_ms) VALUES (?, 0, NULL, NULL, NULL, NULL, 0, NULL, ?)", arguments: [candidate.nodeID.rawValue, Self.milliseconds(date)])
        }
    }

    func reviewTraversal() -> ReviewCandidateCompleteTraversal {
        .init(scope: scope, feature: .reviews, streamID: streamID, candidate: candidate,
              candidateSourceRevision: "rev-1", parserVersion: 1, observedAt: date,
              normalizedDigest: Data(repeating: 7, count: 32), segments: [
                .init(kind: .reviewHistory, pages: [
                    page(ordinal: 1, requestKey: "GET /repos/acme/repo/pulls/7/reviews?per_page=100", terminal: false),
                    page(ordinal: 2, requestKey: "GET /repos/acme/repo/pulls/7/reviews?page=2&per_page=100", terminal: true)
                ]),
                .init(kind: .requestedReviewers, pages: [page(ordinal: 1, requestKey: "GET /repos/acme/repo/pulls/7/requested_reviewers", terminal: true)])
              ])
    }

    func page(ordinal: Int, requestKey: String, terminal: Bool) -> ReviewCandidateTraversalPage {
        .init(ordinal: ordinal, rawSnapshotID: .make(), requestIdentity: .init(scope: scope, feature: .reviews, streamID: streamID, requestKey: requestKey), endpoint: requestKey, eTag: "etag-\(requestKey)", lastModified: "Mon, 01 Jan 2024 00:00:00 GMT", payload: Data("{}".utf8), isTerminal: terminal)
    }

    func threadPage(ordinal: Int, key: String, terminal: Bool) -> ReviewCandidateTraversalPage {
        .init(ordinal: ordinal, rawSnapshotID: .make(), requestIdentity: .init(scope: scope, feature: .reviewThreads, streamID: threadStreamID, requestKey: key), endpoint: "graphql/\(key)", payload: Data("{}".utf8), isTerminal: terminal)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do { _ = try await expression(); XCTFail("Expected an error") }
    catch { handler(error) }
}
