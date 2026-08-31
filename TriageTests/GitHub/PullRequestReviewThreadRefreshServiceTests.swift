import Foundation
import GRDB
import XCTest
@testable import Triage

final class PullRequestReviewThreadRefreshServiceTests: XCTestCase {
    func testStaleScopeBeforeCandidateSelectionCancelsWithoutSchedulerWrites() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        try await fixture.rotate(.credential)

        do {
            _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [:])).refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                streamID: fixture.streamID
            )
            XCTFail("Expected stale scope cancellation.")
        } catch is CancellationError {
            // Expected supersession.
        }
        let durableState = try await fixture.durableState()
        XCTAssertEqual(durableState.schedulerShards, 0)
    }

    func testInaccessibleRetainedPullRequestDoesNotFetchOrAdvanceAndCoverageIsUnavailable() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        try await fixture.setFirstPullRequestAccessibility(.inaccessible)
        let before = try await fixture.durableState()

        let result = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [:])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            streamID: fixture.streamID
        )

        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertFalse(result.hasRemainingCandidates)
        XCTAssertTrue(result.hasBlockedKnownCandidates)
        XCTAssertEqual(result.coverageAssessment.status, .unavailable)
        let after = try await fixture.durableState()
        XCTAssertEqual(after, before)
    }

    func testTrueEmptyInventoryRemainsComplete() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        try await fixture.removeFirstPullRequest()

        let result = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [:])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            streamID: fixture.streamID
        )

        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertFalse(result.hasRemainingCandidates)
        XCTAssertFalse(result.hasBlockedKnownCandidates)
        XCTAssertEqual(result.coverageAssessment.status, .complete)
    }

    func testDuplicateThreadEvidenceFailsClosedAndCandidateRemainsSelected() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let valid = fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1")
        let invalid = GitHubPullRequestReviewThreadInventory(
            records: [valid.records[0], valid.records[0]],
            rawPages: valid.rawPages,
            metrics: valid.metrics
        )
        let before = try await fixture.durableState()

        await XCTAssertThrowsErrorAsync({
            _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
                fixture.firstPullRequest.nodeID: .inventory(invalid)
            ])).refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                streamID: fixture.streamID
            )
        }) { error in
            XCTAssertEqual(
                error as? ReviewCandidateCompleteTraversalReceiptRepositoryError,
                .invalidTraversal
            )
        }
        let afterRejectedTraversal = try await fixture.durableState()
        XCTAssertEqual(afterRejectedTraversal, before)

        let retry = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .inventory(valid)
        ])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            streamID: fixture.streamID
        )
        XCTAssertEqual(retry.outcomes.map(\.pullRequestNodeID), [fixture.firstPullRequest.nodeID])
        XCTAssertEqual(retry.outcomes.map(\.status), [.refreshed])
    }

    func testSuccessfulInventoryPersistsRawProvenanceThreadsAndComments() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let fetcher = ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .inventory(fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1"))
        ])
        let service = fixture.service(fetcher: fetcher)

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )

        XCTAssertEqual(result.outcomes.count, 1)
        XCTAssertEqual(result.outcomes[0].pullRequestNodeID, fixture.firstPullRequest.nodeID)
        XCTAssertEqual(result.outcomes[0].repositoryID, fixture.repositoryID)
        XCTAssertEqual(result.outcomes[0].status, .refreshed)
        XCTAssertFalse(result.hasRemainingCandidates)

        let persisted = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots"),
                try String.fetchOne(database, sql: "SELECT pull_request_node_id FROM review_threads WHERE github_node_id = 'THREAD_1'"),
                try String.fetchOne(database, sql: "SELECT parent_node_id FROM comments WHERE github_node_id = 'COMMENT_1'"),
                try String.fetchOne(database, sql: "SELECT body_markdown FROM comments WHERE github_node_id = 'COMMENT_1'")
            )
        }
        XCTAssertEqual(persisted.0, 2)
        XCTAssertEqual(persisted.1, fixture.firstPullRequest.nodeID.rawValue)
        XCTAssertEqual(persisted.2, "THREAD_1")
        XCTAssertEqual(persisted.3, "Please update this line.")
    }

    func testVerifiedCompleteTraversalPrunesStaleThreadsAndComments() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .inventory(
                fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1")
            )
        ])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )
        // Select the same candidate for the next authoritative traversal.
        try await fixture.vault.write { database in
            try database.execute(sql: "DELETE FROM sync_shards")
        }

        _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .inventory(fixture.emptyInventory())
        ])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt.addingTimeInterval(1),
            streamID: fixture.streamID
        )

        let persisted = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_threads"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM comments"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_complete_traversal_receipts")
            )
        }
        XCTAssertEqual(persisted.0, 0)
        XCTAssertEqual(persisted.1, 0)
        XCTAssertEqual(persisted.2, 2)
    }

    func testIncompleteSuccessfulTraversalRollsBackAndRetainsPriorThreads() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .inventory(
                fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1")
            )
        ])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )
        try await fixture.vault.write { database in
            try database.execute(sql: "DELETE FROM sync_shards")
        }
        let incomplete = GitHubPullRequestReviewThreadInventory(
            records: fixture.inventory(threadID: "THREAD_2", commentID: "COMMENT_2").records,
            rawPages: [
                .init(
                    endpoint: "graphql:TriagePullRequestReviewThreads/page=1",
                    requestKey: "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=none",
                    payload: fixture.rootPayload(
                        pullRequestNodeID: fixture.firstPullRequest.nodeID,
                        threadNodeIDs: [GitHubNodeID(rawValue: "THREAD_2")!]
                    )
                )
            ],
            metrics: .init(pageCount: 1, responseBytes: 116, queryCost: 1)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
                fixture.firstPullRequest.nodeID: .inventory(incomplete)
            ])).refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                observedAt: fixture.observedAt.addingTimeInterval(1),
                streamID: fixture.streamID
            )
        }) { error in
            XCTAssertEqual(
                error as? ReviewCandidateCompleteTraversalReceiptRepositoryError,
                .invalidTraversal
            )
        }
        let persisted = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT github_node_id FROM review_threads ORDER BY github_node_id"),
                try String.fetchAll(database, sql: "SELECT github_node_id FROM comments ORDER BY github_node_id"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_complete_traversal_receipts")
            )
        }
        XCTAssertEqual(persisted.0, ["THREAD_1"])
        XCTAssertEqual(persisted.1, ["COMMENT_1"])
        XCTAssertEqual(persisted.2, 1)
        let failures = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_failure_envelopes")
        }
        XCTAssertEqual(failures, 0)
    }

    func testRawCommentMembershipMismatchRollsBackAndDoesNotAdvanceCandidate() async throws {
        for rawCommentNodeIDs in [
            [GitHubNodeID](),
            [GitHubNodeID(rawValue: "COMMENT_NOT_IN_NORMALIZED_RECORDS")!]
        ] {
            let fixture = try await ReviewThreadRefreshFixture()
            defer { fixture.remove() }
            let valid = fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1")
            let rawPages = [
                valid.rawPages[0],
                GitHubPullRequestReviewThreadRawPage(
                    endpoint: "graphql:TriagePullRequestReviewThreadComments/thread=THREAD_1/page=1",
                    requestKey: "graphql:TriagePullRequestReviewThreadComments/thread=THREAD_1/after=none",
                    payload: fixture.commentPayload(
                        threadNodeID: GitHubNodeID(rawValue: "THREAD_1")!,
                        commentNodeIDs: rawCommentNodeIDs
                    )
                )
            ]
            let mismatched = GitHubPullRequestReviewThreadInventory(
                records: valid.records,
                rawPages: rawPages,
                metrics: .init(
                    pageCount: rawPages.count,
                    responseBytes: rawPages.reduce(0) { $0 + $1.payload.count },
                    queryCost: valid.metrics.queryCost
                )
            )
            let before = try await fixture.durableState()

            await XCTAssertThrowsErrorAsync({
                _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
                    fixture.firstPullRequest.nodeID: .inventory(mismatched)
                ])).refresh(
                    scope: fixture.scope,
                    githubOrganizationID: fixture.githubOrganizationID,
                    observedAt: fixture.observedAt,
                    streamID: fixture.streamID
                )
            }) { error in
                XCTAssertEqual(
                    error as? ReviewCandidateCompleteTraversalReceiptRepositoryError,
                    .invalidTraversal
                )
            }

            let after = try await fixture.durableState()
            XCTAssertEqual(after, before)
            let candidate = try await PullRequestReviewCandidateRepository(vault: fixture.vault)
                .fairCandidates(
                    scope: fixture.scope,
                    streamID: fixture.streamID,
                    feature: .reviewThreads,
                    limit: 1
                )
                .candidates
                .first
            XCTAssertEqual(candidate?.nodeID, fixture.firstPullRequest.nodeID)
        }
    }

    func testCrossScopeReceiptCannotAuthorizePruning() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .inventory(
                fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1")
            )
        ])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )
        let persistedReceipt = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT id FROM review_candidate_complete_traversal_receipts LIMIT 1"
            )
        }
        let wrongScope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "other-capability")!
        )
        let wrongReceipt = ReviewCandidateCompleteTraversalReceiptToken(
            id: try XCTUnwrap(UUID(uuidString: try XCTUnwrap(persistedReceipt))),
            scope: wrongScope,
            feature: .reviewThreads,
            streamID: fixture.streamID,
            candidateNodeID: fixture.firstPullRequest.nodeID,
            repositoryID: fixture.repositoryID,
            candidateSourceRevision: "revision-1"
        )

        await XCTAssertThrowsErrorAsync({
            try await PullRequestReviewCandidateRepository(vault: fixture.vault).writeTransaction(
                accountID: fixture.accountID
            ) { database in
                try PullRequestReviewThreadRepository.replace(
                    pullRequestNodeID: fixture.firstPullRequest.nodeID,
                    accountID: fixture.accountID,
                    organizationID: fixture.organizationID,
                    repositoryID: fixture.repositoryID,
                    currentUserNodeID: GitHubNodeID(rawValue: "USER_1")!,
                    records: [],
                    scope: fixture.scope,
                    streamID: fixture.streamID,
                    completeTraversalReceipt: wrongReceipt,
                    observedAt: fixture.observedAt.addingTimeInterval(1),
                    in: database
                )
            }
        }) { error in
            XCTAssertEqual(error as? PullRequestReviewThreadRepositoryError, .invalidTraversalReceipt)
        }
        let persisted = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT github_node_id FROM review_threads ORDER BY github_node_id")
        }
        XCTAssertEqual(persisted, ["THREAD_1"])
    }

    func testReceiptDigestDoesNotAuthorizeEmptyOrMismatchedReplacement() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .inventory(
                fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1")
            )
        ])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )
        let persistedReceipt = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT id FROM review_candidate_complete_traversal_receipts LIMIT 1"
            )
        }
        let receipt = ReviewCandidateCompleteTraversalReceiptToken(
            id: try XCTUnwrap(UUID(uuidString: try XCTUnwrap(persistedReceipt))),
            scope: fixture.scope,
            feature: .reviewThreads,
            streamID: fixture.streamID,
            candidateNodeID: fixture.firstPullRequest.nodeID,
            repositoryID: fixture.repositoryID,
            candidateSourceRevision: "revision-1"
        )
        let mismatchedRecords = fixture.inventory(
            threadID: "THREAD_2",
            commentID: "COMMENT_2"
        ).records
        for records in [[], mismatchedRecords] {
            await XCTAssertThrowsErrorAsync({
                try await PullRequestReviewCandidateRepository(vault: fixture.vault).writeTransaction(
                    accountID: fixture.accountID
                ) { database in
                    try PullRequestReviewThreadRepository.replace(
                        pullRequestNodeID: fixture.firstPullRequest.nodeID,
                        accountID: fixture.accountID,
                        organizationID: fixture.organizationID,
                        repositoryID: fixture.repositoryID,
                        currentUserNodeID: GitHubNodeID(rawValue: "USER_1")!,
                        records: records,
                        scope: fixture.scope,
                        streamID: fixture.streamID,
                        completeTraversalReceipt: receipt,
                        observedAt: fixture.observedAt.addingTimeInterval(1),
                        in: database
                    )
                }
            }) { error in
                XCTAssertEqual(error as? PullRequestReviewThreadRepositoryError, .invalidTraversalReceipt)
            }
        }
        let persisted = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT github_node_id FROM review_threads ORDER BY github_node_id"),
                try String.fetchAll(database, sql: "SELECT github_node_id FROM comments ORDER BY github_node_id")
            )
        }
        XCTAssertEqual(persisted.0, ["THREAD_1"])
        XCTAssertEqual(persisted.1, ["COMMENT_1"])
    }

    func testRemoteFailurePublishesTerminalEvidenceAdvancesAndStopsBeforeLaterCandidate() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let secondPullRequest = try await fixture.addPullRequest(nodeID: "PR_2", number: 2)
        let fetcher = ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .failure(.generic),
            secondPullRequest.nodeID: .inventory(
                fixture.inventory(
                    pullRequestNodeID: secondPullRequest.nodeID,
                    threadID: "THREAD_2",
                    commentID: "COMMENT_2"
                )
            )
        ])
        let before = try await fixture.durableState()

        let result = try await fixture.service(fetcher: fetcher).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )

        XCTAssertEqual(result.outcomes.map(\.pullRequestNodeID), [fixture.firstPullRequest.nodeID])
        XCTAssertEqual(result.outcomes.map(\.status), [.failed])
        let persistedThreadIDs = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT github_node_id FROM review_threads ORDER BY github_node_id")
        }
        XCTAssertEqual(persistedThreadIDs, [])
        let after = try await fixture.durableState()
        XCTAssertEqual(after.rawSnapshots, before.rawSnapshots)
        XCTAssertEqual(after.reviewThreads, before.reviewThreads)
        XCTAssertEqual(after.comments, before.comments)
        XCTAssertEqual(after.failureEnvelopes, before.failureEnvelopes + 1)
        XCTAssertEqual(after.schedulerShards, before.schedulerShards + 2)
        let rawFailure = try await fixture.vault.read { database in
            (
                try Int.fetchOne(
                    database,
                    sql: "SELECT raw_page_count FROM review_candidate_failure_envelopes LIMIT 1"
                ),
                try String.fetchOne(
                    database,
                    sql: "SELECT classification FROM review_candidate_failure_envelopes LIMIT 1"
                )
            )
        }
        XCTAssertEqual(rawFailure.0, 0)
        XCTAssertEqual(rawFailure.1, "transportFailure")

        let retry = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .inventory(
                fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1")
            ),
            secondPullRequest.nodeID: .inventory(
                fixture.inventory(
                    pullRequestNodeID: secondPullRequest.nodeID,
                    threadID: "THREAD_2",
                    commentID: "COMMENT_2"
                )
            )
        ])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )
        XCTAssertEqual(
            retry.outcomes.map(\.pullRequestNodeID),
            [secondPullRequest.nodeID]
        )
        XCTAssertEqual(retry.outcomes.map(\.status), [.refreshed])
    }

    func testCandidateLocalForbiddenAndNotFoundFailuresContinueFairCandidates() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let secondPullRequest = try await fixture.addPullRequest(nodeID: "PR_2", number: 2)
        let thirdPullRequest = try await fixture.addPullRequest(nodeID: "PR_3", number: 3)

        let result = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .failure(.forbidden),
            secondPullRequest.nodeID: .failure(.notFound),
            thirdPullRequest.nodeID: .inventory(
                fixture.inventory(
                    pullRequestNodeID: thirdPullRequest.nodeID,
                    threadID: "THREAD_3",
                    commentID: "COMMENT_3"
                )
            )
        ])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )

        XCTAssertEqual(
            result.outcomes.map(\.pullRequestNodeID),
            [fixture.firstPullRequest.nodeID, secondPullRequest.nodeID, thirdPullRequest.nodeID]
        )
        XCTAssertEqual(
            result.outcomes.map(\.status),
            [.unavailableOrPermission, .unavailableOrPermission, .refreshed]
        )
        XCTAssertEqual(result.coverageAssessment.status, .unavailable)
        let failureClassifications = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT classification FROM review_candidate_failure_envelopes ORDER BY candidate_node_id"
            )
        }
        XCTAssertEqual(failureClassifications, ["unavailableOrPermission", "unavailableOrPermission"])
    }

    func testSSOApprovalAndRateLimitFailuresStopCandidatePass() async throws {
        let cases: [(ReviewThreadFetcher.Failure, PullRequestReviewThreadRefreshOutcomeStatus)] = [
            (
                .sso,
                .ssoRequired(
                    .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso-secret")!)
                )
            ),
            (.approval, .approvalRequired),
            (.rateLimited, .rateLimited(retryAt: Date(timeIntervalSince1970: 1_060)))
        ]
        for (failure, expectedStatus) in cases {
            let fixture = try await ReviewThreadRefreshFixture()
            defer { fixture.remove() }
            let secondPullRequest = try await fixture.addPullRequest(nodeID: "PR_2", number: 2)
            let result = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
                fixture.firstPullRequest.nodeID: .failure(failure),
                secondPullRequest.nodeID: .inventory(
                    fixture.inventory(
                        pullRequestNodeID: secondPullRequest.nodeID,
                        threadID: "THREAD_2",
                        commentID: "COMMENT_2"
                    )
                )
            ])).refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                observedAt: fixture.observedAt,
                streamID: fixture.streamID
            )
            XCTAssertEqual(result.outcomes.map(\.pullRequestNodeID), [fixture.firstPullRequest.nodeID])
            XCTAssertEqual(result.outcomes.map(\.status), [expectedStatus])
        }
    }

    func testFailureWithoutInjectedEnvelopeRepositoryDoesNotAdvanceOrPersist() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let before = try await fixture.durableState()

        await XCTAssertThrowsErrorAsync({
            _ = try await fixture.service(
                fetcher: ReviewThreadFetcher(plans: [fixture.firstPullRequest.nodeID: .failure(.generic)]),
                injectFailureEnvelopeRepository: false
            ).refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                observedAt: fixture.observedAt,
                streamID: fixture.streamID
            )
        }) { _ in }

        let after = try await fixture.durableState()
        XCTAssertEqual(after, before)
    }

    func testTraversalFailurePersistsAccumulatedGraphQLPagesWithExactRequestKeys() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }

        let result = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .failure(.traversal)
        ])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )

        XCTAssertEqual(result.outcomes.map(\.status), [.failed])
        let persisted = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_candidate_failure_pages"),
                try String.fetchAll(
                    database,
                    sql: """
                        SELECT raw_api_snapshots.authority_request_key
                        FROM review_candidate_failure_pages
                        JOIN raw_api_snapshots
                          ON raw_api_snapshots.id = review_candidate_failure_pages.raw_snapshot_id
                        ORDER BY raw_api_snapshots.authority_request_key
                        """
                ),
                try String.fetchAll(
                    database,
                    sql: """
                        SELECT raw_api_snapshots.endpoint
                        FROM review_candidate_failure_pages
                        JOIN raw_api_snapshots
                          ON raw_api_snapshots.id = review_candidate_failure_pages.raw_snapshot_id
                        ORDER BY raw_api_snapshots.authority_request_key
                        """
                ),
                try String.fetchOne(
                    database,
                    sql: "SELECT request_key FROM review_candidate_failure_envelopes LIMIT 1"
                )
            )
        }
        XCTAssertEqual(persisted.0, 2)
        XCTAssertEqual(persisted.1, [
            "graphql:TriagePullRequestReviewThreadComments/thread=THREAD_1/after=none",
            "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=none"
        ])
        XCTAssertEqual(persisted.2, [
            "graphql:TriagePullRequestReviewThreadComments/thread=THREAD_1/page=1",
            "graphql:TriagePullRequestReviewThreads/page=1"
        ])
        XCTAssertEqual(
            persisted.3,
            "graphql:TriagePullRequestReviewThreadComments/thread=THREAD_1/after=none"
        )
    }

    func testFabricatedTraversalTerminalKeyDoesNotAdvanceOrPersistFailure() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let before = try await fixture.durableState()

        await XCTAssertThrowsErrorAsync({
            _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
                fixture.firstPullRequest.nodeID: .failure(.fabricatedTerminal)
            ])).refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                observedAt: fixture.observedAt,
                streamID: fixture.streamID
            )
        }) { error in
            XCTAssertEqual(error as? ReviewCandidateFailureEnvelopeRepositoryError, .invalidRawPages)
        }
        let after = try await fixture.durableState()
        XCTAssertEqual(after, before)
    }

    func testPageTwoTraversalFailureBindsEnvelopeToPageTwoRequestKey() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }

        _ = try await fixture.service(fetcher: ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .failure(.pageTwoTraversal)
        ])).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )
        let persisted = try await fixture.vault.read { database in
            (
                try String.fetchOne(
                    database,
                    sql: "SELECT request_key FROM review_candidate_failure_envelopes LIMIT 1"
                ),
                try Int.fetchOne(database, sql: "SELECT raw_page_count FROM review_candidate_failure_envelopes LIMIT 1")
            )
        }
        XCTAssertEqual(
            persisted.0,
            "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=Y3Vyc29yLTE="
        )
        XCTAssertEqual(persisted.1, 2)
    }

    func testSSOAndApprovalFailuresAreRedactedAndClassified() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let fetcher = ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .failure(.sso)
        ])

        let result = try await fixture.service(fetcher: fetcher).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )

        guard case let .ssoRequired(header) = result.outcomes[0].status else {
            return XCTFail("The selected organization's SSO recovery header must remain actionable in memory.")
        }
        XCTAssertEqual(
            header,
            .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso-secret")!)
        )
        XCTAssertEqual(result.outcomes.count, 1)
        XCTAssertEqual(result.coverageAssessment.status, .requiresSSO)
        let persistedDetail = try XCTUnwrap(result.coverageAssessment.failureDetail)
        XCTAssertFalse(persistedDetail.contains("https://"))
        XCTAssertFalse(persistedDetail.contains("sso-secret"))
        let persistedFailureDetail = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT redacted_diagnostic FROM review_candidate_failure_envelopes LIMIT 1"
            )
        }
        XCTAssertFalse(try XCTUnwrap(persistedFailureDetail).contains("https://"))
        XCTAssertFalse(try XCTUnwrap(persistedFailureDetail).contains("sso-secret"))

        let approvalFixture = try await ReviewThreadRefreshFixture()
        defer { approvalFixture.remove() }
        let approval = try await approvalFixture.service(fetcher: ReviewThreadFetcher(plans: [
            approvalFixture.firstPullRequest.nodeID: .failure(.approval)
        ])).refresh(
            scope: approvalFixture.scope,
            githubOrganizationID: approvalFixture.githubOrganizationID,
            observedAt: approvalFixture.observedAt,
            streamID: approvalFixture.streamID
        )
        XCTAssertEqual(approval.outcomes.map(\.status), [.approvalRequired])
        XCTAssertEqual(approval.coverageAssessment.status, .requiresApproval)
        let approvalDetail = try XCTUnwrap(approval.coverageAssessment.failureDetail)
        XCTAssertFalse(approvalDetail.contains("https://"))
        XCTAssertFalse(approvalDetail.contains("approval-secret"))
    }

    func testCancellationAfterFetchPreventsReplacementAndPropagates() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let fetcher = BlockingReviewThreadFetcher(inventory: fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1"))
        let service = fixture.service(fetcher: fetcher)
        let refresh = Task {
            try await service.refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                observedAt: fixture.observedAt,
                streamID: fixture.streamID
            )
        }

        await fetcher.waitUntilStarted()
        refresh.cancel()
        await fetcher.finishFetch()

        await XCTAssertThrowsErrorAsync({
            _ = try await refresh.value
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let counts = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_threads")
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testCredentialRotationDuringThreadResponseCancelsWithoutDurableWrites() async throws {
        try await assertScopeRotationDuringThreadResponse(.credential)
    }

    func testCapabilityRotationDuringThreadResponseCancelsWithoutDurableWrites() async throws {
        try await assertScopeRotationDuringThreadResponse(.capability)
    }

    private func assertScopeRotationDuringThreadResponse(
        _ rotation: ReviewThreadScopeRotation
    ) async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let fetcher = BlockingReviewThreadFetcher(
            inventory: fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1")
        )
        let service = fixture.service(fetcher: fetcher)
        let task = Task {
            try await service.refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                observedAt: fixture.observedAt,
                streamID: fixture.streamID
            )
        }

        await fetcher.waitUntilStarted()
        let before = try await fixture.durableState()
        try await fixture.rotate(rotation)
        await fetcher.finishFetch()

        await XCTAssertThrowsErrorAsync({
            _ = try await task.value
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let after = try await fixture.durableState()
        XCTAssertEqual(after, before)
    }

    func testResultRetainsRemainingCandidateSignal() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        _ = try await fixture.addPullRequest(nodeID: "PR_2", number: 2)
        let fetcher = ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .inventory(fixture.inventory(threadID: "THREAD_1", commentID: "COMMENT_1"))
        ])

        let result = try await fixture.service(fetcher: fetcher).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            limit: 1,
            observedAt: fixture.observedAt,
            streamID: fixture.streamID
        )

        XCTAssertEqual(result.outcomes.map(\.status), [.refreshed])
        XCTAssertTrue(result.hasRemainingCandidates)
    }

    func testCoverageAssessmentNeverOverstatesPartialOrFailedCandidates() {
        let nodeID = GitHubNodeID(rawValue: "PR_1")!
        let repositoryID = RepositoryID(rawValue: "REPO_1")!
        func result(
            _ status: PullRequestReviewThreadRefreshOutcomeStatus,
            hasRemaining: Bool = false
        ) -> PullRequestReviewThreadRefreshResult {
            PullRequestReviewThreadRefreshResult(
                outcomes: [
                    .init(
                        pullRequestNodeID: nodeID,
                        repositoryID: repositoryID,
                        pullRequestNumber: 1,
                        status: status
                    )
                ],
                hasRemainingCandidates: hasRemaining,
                hasBlockedKnownCandidates: false
            )
        }

        XCTAssertEqual(result(.refreshed).coverageAssessment.status, .complete)
        XCTAssertEqual(result(.refreshed, hasRemaining: true).coverageAssessment.status, .partial)
        XCTAssertEqual(
            result(
                .ssoRequired(.authorizationRequired(URL(string: "https://github.com/orgs/acme/sso")!))
            ).coverageAssessment.status,
            .requiresSSO
        )
        XCTAssertEqual(result(.approvalRequired).coverageAssessment.status, .requiresApproval)
        XCTAssertEqual(result(.unavailableOrPermission).coverageAssessment.status, .unavailable)
        XCTAssertEqual(result(.failed).coverageAssessment.status, .failed)
        XCTAssertEqual(result(.rateLimited(retryAt: nil)).coverageAssessment.status, .partial)
    }
}

private enum ReviewThreadScopeRotation {
    case credential
    case capability
}

private struct ReviewThreadDurableState: Equatable {
    let rawSnapshots: Int
    let reviews: Int
    let reviewRequests: Int
    let reviewThreads: Int
    let comments: Int
    let schedulerShards: Int
    let failureEnvelopes: Int
}

private actor ReviewThreadFetcher: PullRequestReviewThreadFetching {
    enum Plan: Sendable {
        case inventory(GitHubPullRequestReviewThreadInventory)
        case failure(Failure)
    }

    enum Failure: Error, Sendable {
        case generic
        case traversal
        case fabricatedTerminal
        case pageTwoTraversal
        case forbidden
        case notFound
        case rateLimited
        case sso
        case approval
        case unrelatedSSO
    }

    private let plans: [GitHubNodeID: Plan]

    init(plans: [GitHubNodeID: Plan]) {
        self.plans = plans
    }

    func allReviewThreads(
        pullRequestNodeID: GitHubNodeID,
        observedAt: Date
    ) async throws -> GitHubPullRequestReviewThreadInventory {
        _ = observedAt
        guard let plan = plans[pullRequestNodeID] else { throw Failure.generic }
        switch plan {
        case let .inventory(inventory):
            return inventory
        case .failure(.generic):
            throw Failure.generic
        case .failure(.forbidden):
            throw Self.remoteTraversalFailure(
                GitHubFailure(kind: .forbidden, statusCode: 403),
                pullRequestNodeID: pullRequestNodeID
            )
        case .failure(.notFound):
            throw Self.remoteTraversalFailure(
                GitHubFailure(kind: .notFound, statusCode: 404),
                pullRequestNodeID: pullRequestNodeID
            )
        case .failure(.rateLimited):
            throw Self.remoteTraversalFailure(
                GitHubFailure(kind: .rateLimited, statusCode: 429, retryAfter: 60),
                pullRequestNodeID: pullRequestNodeID
            )
        case .failure(.traversal):
            throw GitHubPullRequestReviewThreadTraversalFailure(
                reason: .missingData,
                rawPages: [
                    .init(
                        endpoint: "graphql:TriagePullRequestReviewThreads/page=1",
                        requestKey: "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=none",
                        payload: Data("{\"data\":{}}".utf8)
                    ),
                    .init(
                        endpoint: "graphql:TriagePullRequestReviewThreadComments/thread=THREAD_1/page=1",
                        requestKey: "graphql:TriagePullRequestReviewThreadComments/thread=THREAD_1/after=none",
                        payload: Data("{\"data\":{}}".utf8)
                    )
                ],
                terminalRequestKey: "graphql:TriagePullRequestReviewThreadComments/thread=THREAD_1/after=none",
                remoteFailure: nil,
                ssoHeader: nil
            )
        case .failure(.fabricatedTerminal):
            throw GitHubPullRequestReviewThreadTraversalFailure(
                reason: .missingData,
                rawPages: [
                    .init(
                        endpoint: "graphql:TriagePullRequestReviewThreads/page=1",
                        requestKey: "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=none",
                        payload: Data("{\"data\":{}}".utf8)
                    )
                ],
                terminalRequestKey: "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=fabricated",
                remoteFailure: nil,
                ssoHeader: nil
            )
        case .failure(.pageTwoTraversal):
            throw GitHubPullRequestReviewThreadTraversalFailure(
                reason: .missingData,
                rawPages: [
                    .init(
                        endpoint: "graphql:TriagePullRequestReviewThreads/page=1",
                        requestKey: "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=none",
                        payload: Data("{\"data\":{}}".utf8)
                    ),
                    .init(
                        endpoint: "graphql:TriagePullRequestReviewThreads/page=2",
                        requestKey: "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=Y3Vyc29yLTE=",
                        payload: Data("{\"data\":{}}".utf8)
                    )
                ],
                terminalRequestKey: "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=Y3Vyc29yLTE=",
                remoteFailure: nil,
                ssoHeader: nil
            )
        case .failure(.sso):
            throw Self.remoteTraversalFailure(
                GitHubFailure(
                    kind: .forbidden,
                    statusCode: 403,
                    ssoHeader: .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso-secret")!)
                ),
                pullRequestNodeID: pullRequestNodeID
            )
        case .failure(.approval):
            throw Self.remoteTraversalFailure(
                GitHubFailure(
                    kind: .forbidden,
                    statusCode: 403,
                    accessRestriction: .organizationApprovalRequired
                ),
                pullRequestNodeID: pullRequestNodeID
            )
        case .failure(.unrelatedSSO):
            throw Self.remoteTraversalFailure(
                GitHubFailure(
                    kind: .forbidden,
                    statusCode: 403,
                    ssoHeader: .partialResults([999])
                ),
                pullRequestNodeID: pullRequestNodeID
            )
        }
    }

    private nonisolated static func remoteTraversalFailure(
        _ remoteFailure: GitHubFailure,
        pullRequestNodeID: GitHubNodeID
    ) -> GitHubPullRequestReviewThreadTraversalFailure {
        let requestKey = "graphql:TriagePullRequestReviewThreads/pull-request=\(pullRequestNodeID.rawValue)/after=none/terminal"
        return .init(
            reason: .requestFailed,
            rawPages: [
                .init(
                    endpoint: "graphql:TriagePullRequestReviewThreads/page=1/terminal",
                    requestKey: requestKey,
                    payload: Data("{\"triageFailureEnvelopeVersion\":1,\"reason\":\"requestFailed\"}".utf8)
                )
            ],
            terminalRequestKey: requestKey,
            remoteFailure: remoteFailure,
            ssoHeader: remoteFailure.ssoHeader
        )
    }
}

private actor BlockingReviewThreadFetcher: PullRequestReviewThreadFetching {
    private let inventory: GitHubPullRequestReviewThreadInventory
    private var startedWaiters = [CheckedContinuation<Void, Never>]()
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    init(inventory: GitHubPullRequestReviewThreadInventory) {
        self.inventory = inventory
    }

    func allReviewThreads(
        pullRequestNodeID: GitHubNodeID,
        observedAt: Date
    ) async throws -> GitHubPullRequestReviewThreadInventory {
        _ = pullRequestNodeID
        _ = observedAt
        hasStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            fetchContinuation = continuation
        }
        return inventory
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func finishFetch() {
        let continuation = fetchContinuation
        fetchContinuation = nil
        continuation?.resume()
    }
}

private final class ReviewThreadRefreshFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "ORG_1")!
    let githubOrganizationID: UInt64 = 1
    let repositoryID = RepositoryID(rawValue: "REPO_1")!
    let observedAt = Date(timeIntervalSince1970: 1_000)
    let vault: AccountVault
    let streamID = SyncStreamID(rawValue: "pull-request-review-threads-test")!
    private(set) var firstPullRequest: NormalizedGitHubNode! = nil

    var scope: SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
    }

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "USER_1")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt,
            lastValidatedAt: observedAt
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: githubOrganizationID,
            nodeID: GitHubNodeID(rawValue: "ORG_NODE_1")!,
            login: "acme"
        )
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await AccountRepository(vault: vault).save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: observedAt
            ),
            selectedAt: observedAt
        )
        try await SyncStreamRepository(vault: vault).save(
            SyncStream(
                id: streamID,
                accountID: accountID,
                organizationID: organizationID,
                feature: .reviewThreads,
                highWater: nil,
                lastSuccessfulAt: nil,
                lastAttemptAt: observedAt,
                status: .partial,
                failureDetail: nil
            )
        )
        let repositoryID = repositoryID
        let organizationID = organizationID
        let accountID = accountID
        let observedAt = observedAt
        let observedAtMilliseconds = Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login, name,
                        is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, 1, 0, 0, ?, ?, NULL)
                    """,
                arguments: [
                    repositoryID.rawValue,
                    organizationID.rawValue,
                    "1",
                    "REPOSITORY_NODE_1",
                    "acme",
                    "widget",
                    "https://github.com/acme/widget",
                    observedAtMilliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_repository_access (account_id, repository_id, access_state, observed_at_ms)
                    VALUES (?, ?, 'available', ?)
                    """,
                arguments: [
                    accountID.rawValue,
                    repositoryID.rawValue,
                    observedAtMilliseconds
                ]
            )
        }
        firstPullRequest = try await addPullRequest(nodeID: "PR_1", number: 1)
    }

    func service(
        fetcher: any PullRequestReviewThreadFetching,
        injectFailureEnvelopeRepository: Bool = true
    ) -> PullRequestReviewThreadRefreshService {
        PullRequestReviewThreadRefreshService(
            fetcher: fetcher,
            candidateRepository: PullRequestReviewCandidateRepository(vault: vault),
            threadRepository: PullRequestReviewThreadRepository(vault: vault),
            currentUserNodeID: GitHubNodeID(rawValue: "USER_1")!,
            failureEnvelopeRepository: injectFailureEnvelopeRepository
                ? ReviewCandidateFailureEnvelopeRepository(vault: vault)
                : nil
        )
    }

    func addPullRequest(nodeID: String, number: Int) async throws -> NormalizedGitHubNode {
        let node = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: nodeID)!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            kind: .pullRequest,
            numericID: String(number),
            number: number,
            title: "Pull request \(number)",
            state: .open,
            url: URL(string: "https://github.com/acme/widget/pull/\(number)")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: observedAt,
            updatedAt: observedAt,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "revision-\(number)",
            observedAt: observedAt,
            accessibility: .accessible
        )
        try await GitHubNodeDetailsRepository(vault: vault).save(
            HydratedGitHubNode(
                node: node,
                details: .pullRequest(
                    isDraft: false,
                    mergeableState: nil,
                    headRef: "feature",
                    baseRef: "main",
                    reviewDecision: nil,
                    assigneeNodeIDs: [],
                    labelNodeIDs: [],
                    labelNames: []
                )
            ),
            accountID: accountID,
            observedAt: observedAt
        )
        return node
    }

    func inventory(
        pullRequestNodeID: GitHubNodeID? = nil,
        threadID: String,
        commentID: String
    ) -> GitHubPullRequestReviewThreadInventory {
        let pullRequestNodeID = pullRequestNodeID ?? firstPullRequest.nodeID
        let author = ActorSummary(
            id: ActorID(rawValue: "REVIEWER_1")!,
            nodeID: GitHubNodeID(rawValue: "REVIEWER_1")!,
            login: "reviewer",
            displayName: nil,
            avatarURL: nil
        )
        let comment = PullRequestReviewThreadCommentRecord(
            nodeID: GitHubNodeID(rawValue: commentID)!,
            author: author,
            body: "Please update this line.",
            createdAt: observedAt,
            updatedAt: observedAt.addingTimeInterval(1),
            url: URL(string: "https://github.com/acme/widget/pull/1#discussion_r1")!
        )
        let rawPages = [
            GitHubPullRequestReviewThreadRawPage(
                endpoint: "graphql:TriagePullRequestReviewThreads/page=1",
                requestKey: "graphql:TriagePullRequestReviewThreads/pull-request=\(pullRequestNodeID.rawValue)/after=none",
                payload: rootPayload(
                    pullRequestNodeID: pullRequestNodeID,
                    threadNodeIDs: [GitHubNodeID(rawValue: threadID)!]
                )
            ),
            GitHubPullRequestReviewThreadRawPage(
                endpoint: "graphql:TriagePullRequestReviewThreadComments/thread=\(threadID)/page=1",
                requestKey: "graphql:TriagePullRequestReviewThreadComments/thread=\(threadID)/after=none",
                payload: commentPayload(
                    threadNodeID: GitHubNodeID(rawValue: threadID)!,
                    commentNodeIDs: [GitHubNodeID(rawValue: commentID)!]
                )
            )
        ]
        return GitHubPullRequestReviewThreadInventory(
            records: [
                PullRequestReviewThreadRecord(
                    nodeID: GitHubNodeID(rawValue: threadID)!,
                    isResolved: false,
                    isOutdated: false,
                    comments: [comment],
                    updatedAt: comment.updatedAt
                )
            ],
            rawPages: rawPages,
            metrics: .init(
                pageCount: rawPages.count,
                responseBytes: rawPages.reduce(0) { $0 + $1.payload.count },
                queryCost: 2
            )
        )
    }

    func emptyInventory() -> GitHubPullRequestReviewThreadInventory {
        .init(
            records: [],
            rawPages: [
                .init(
                    endpoint: "graphql:TriagePullRequestReviewThreads/page=1",
                    requestKey: "graphql:TriagePullRequestReviewThreads/pull-request=PR_1/after=none",
                    payload: rootPayload(
                        pullRequestNodeID: firstPullRequest.nodeID,
                        threadNodeIDs: []
                    )
                )
            ],
            metrics: .init(pageCount: 1, responseBytes: 100, queryCost: 1)
        )
    }

    func rootPayload(
        pullRequestNodeID: GitHubNodeID,
        threadNodeIDs: [GitHubNodeID]
    ) -> Data {
        let nodes = threadNodeIDs.map { "{\"id\":\"\($0.rawValue)\"}" }.joined(separator: ",")
        return Data(
            """
            {"data":{"node":{"id":"\(pullRequestNodeID.rawValue)","reviewThreads":{"nodes":[\(nodes)],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
            """.utf8
        )
    }

    func commentPayload(
        threadNodeID: GitHubNodeID,
        commentNodeIDs: [GitHubNodeID]
    ) -> Data {
        let nodes = commentNodeIDs.map { "{\"id\":\"\($0.rawValue)\"}" }.joined(separator: ",")
        return Data(
            """
            {"data":{"node":{"id":"\(threadNodeID.rawValue)","comments":{"nodes":[\(nodes)],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
            """.utf8
        )
    }

    func durableState() async throws -> ReviewThreadDurableState {
        try await vault.read { database in
            ReviewThreadDurableState(
                rawSnapshots: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM raw_api_snapshots"
                )!,
                reviews: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM reviews")!,
                reviewRequests: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM review_requests"
                )!,
                reviewThreads: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM review_threads"
                )!,
                comments: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM comments")!,
                schedulerShards: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sync_shards")!,
                failureEnvelopes: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM review_candidate_failure_envelopes"
                )!
            )
        }
    }

    func rotate(_ rotation: ReviewThreadScopeRotation) async throws {
        try await vault.write { database in
            switch rotation {
            case .credential:
                try database.execute(
                    sql: "UPDATE accounts SET credential_revision = 'credential-2' WHERE id = ?",
                    arguments: [accountID.rawValue]
                )
            case .capability:
                try database.execute(
                    sql: """
                        UPDATE account_organizations
                        SET capability_revision = 'capability-2'
                        WHERE account_id = ? AND organization_id = ?
                    """,
                    arguments: [accountID.rawValue, organizationID.rawValue]
                )
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func setFirstPullRequestAccessibility(_ state: GitHubNodeAccessibility) async throws {
        try await vault.write { database in
            try database.execute(
                sql: "UPDATE github_nodes SET accessibility_state = ? WHERE github_node_id = ?",
                arguments: [state.rawValue, firstPullRequest.nodeID.rawValue]
            )
        }
    }

    func removeFirstPullRequest() async throws {
        try await vault.write { database in
            try database.execute(
                sql: "DELETE FROM github_nodes WHERE github_node_id = ?",
                arguments: [firstPullRequest.nodeID.rawValue]
            )
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        verify(error)
    }
}
