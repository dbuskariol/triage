import Foundation
import XCTest
@testable import Triage

final class PullRequestReviewReconciliationTests: XCTestCase {
    func testCompleteReviewHistoryReplacesStaleReviews() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = PullRequestReviewRepository(vault: fixture.vault)

        try await repository.replace(
            reviews: [review(nodeID: "MDM6UmV2aWV3MQ==", state: "APPROVED")],
            pullRequestNodeID: fixture.pullRequest.nodeID,
            replacementProof: try await fixture.reviewProof(
                reviews: [review(nodeID: "MDM6UmV2aWV3MQ==", state: "APPROVED")]
            ),
            observedAt: fixture.date
        )
        try await repository.replace(
            reviews: [review(nodeID: "MDM6UmV2aWV3Mg==", state: "CHANGES_REQUESTED")],
            pullRequestNodeID: fixture.pullRequest.nodeID,
            replacementProof: try await fixture.reviewProof(
                reviews: [review(nodeID: "MDM6UmV2aWV3Mg==", state: "CHANGES_REQUESTED")]
            ),
            observedAt: fixture.date
        )

        let persistedNodeIDs = try await fixture.vault.read { database in
            (
                try String.fetchAll(
                    database,
                    sql: "SELECT github_node_id FROM reviews ORDER BY github_node_id"
                ),
                try String.fetchAll(
                    database,
                    sql: "SELECT github_node_id FROM github_nodes WHERE kind = ? ORDER BY github_node_id",
                    arguments: [GitHubContentKind.pullRequestReview.rawValue]
                )
            )
        }
        XCTAssertEqual(persistedNodeIDs.0, ["MDM6UmV2aWV3Mg=="])
        XCTAssertEqual(persistedNodeIDs.1, ["MDM6UmV2aWV3Mg=="])
    }

    func testReviewNodeCannotBeReboundToAnotherPullRequest() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = PullRequestReviewRepository(vault: fixture.vault)
        let review = review(nodeID: "R_shared", state: "APPROVED")
        try await repository.replace(
            reviews: [review],
            pullRequestNodeID: fixture.pullRequest.nodeID,
            replacementProof: try await fixture.reviewProof(reviews: [review]),
            observedAt: fixture.date
        )
        let secondPullRequest = fixture.pullRequest(
            nodeID: GitHubNodeID(rawValue: "PR_2")!,
            number: 2,
            title: "Another pull request"
        )
        try await GitHubNodeDetailsRepository(vault: fixture.vault).save(
            HydratedGitHubNode(
                node: secondPullRequest,
                details: .pullRequest(
                    isDraft: false,
                    mergeableState: nil,
                    headRef: "other",
                    baseRef: "main",
                    reviewDecision: nil,
                    assigneeNodeIDs: [],
                    labelNodeIDs: [],
                    labelNames: []
                )
            ),
            accountID: fixture.accountID,
            observedAt: fixture.date
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                reviews: [review],
                pullRequestNodeID: secondPullRequest.nodeID,
                replacementProof: try await fixture.reviewProof(
                    reviews: [review],
                    for: secondPullRequest
                ),
                observedAt: fixture.date.addingTimeInterval(1)
            )
        } verify: { error in
            XCTAssertEqual(
                error as? PullRequestReviewRepositoryError,
                .reviewNodeScopeMismatch
            )
        }

        let persisted = try await fixture.vault.read { database in
            (
                try String.fetchOne(
                    database,
                    sql: "SELECT pull_request_node_id FROM reviews WHERE github_node_id = ?",
                    arguments: [review.nodeID]
                ),
                try String.fetchOne(
                    database,
                    sql: "SELECT repository_id FROM github_nodes WHERE github_node_id = ?",
                    arguments: [review.nodeID]
                )
            )
        }
        XCTAssertEqual(persisted.0, fixture.pullRequest.nodeID.rawValue)
        XCTAssertEqual(persisted.1, fixture.repositoryID.rawValue)
    }

    func testInvalidRequestedReviewerDoesNotEraseExistingRequests() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = PullRequestReviewRequestRepository(vault: fixture.vault)
        let valid = GitHubRequestedReviewersDTO(
            users: [.init(nodeID: "MDQ6VXNlcjI=", login: "reviewer", slug: nil)],
            teams: []
        )
        try await repository.replace(
            valid,
            pullRequestNodeID: fixture.pullRequest.nodeID,
            replacementProof: try await fixture.reviewProof(requestedReviewers: valid),
            observedAt: fixture.date
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                GitHubRequestedReviewersDTO(
                    users: [.init(nodeID: "", login: "invalid", slug: nil)],
                    teams: []
                ),
                pullRequestNodeID: fixture.pullRequest.nodeID,
                replacementProof: try await fixture.reviewProof(
                    requestedReviewers: GitHubRequestedReviewersDTO(
                        users: [.init(nodeID: "", login: "invalid", slug: nil)], teams: []
                    )
                ),
                observedAt: fixture.date
            )
        } verify: { error in
            XCTAssertEqual(
                error as? PullRequestReviewRequestRepositoryError,
                .invalidReviewerNodeID
            )
        }

        let persistedNodeIDs = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT requested_reviewer_node_id FROM review_requests"
            )
        }
        XCTAssertEqual(persistedNodeIDs, ["MDQ6VXNlcjI="])
    }

    func testTransactionScopedHydratedWriteRollsBackOnFailure() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = GitHubNodeDetailsRepository(vault: fixture.vault)
        let updatedNode = fixture.node(title: "Should not persist")

        await XCTAssertThrowsErrorAsync {
            try await repository.writeTransaction(accountID: fixture.accountID) { database in
                try GitHubNodeDetailsRepository.save(
                    HydratedGitHubNode(
                        node: updatedNode,
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
                    accountID: fixture.accountID,
                    observedAtMilliseconds: 2_000,
                    in: database
                )
                throw FixtureError.expectedRollback
            }
        } verify: { error in
            XCTAssertEqual(error as? FixtureError, .expectedRollback)
        }

        let persistedTitle = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT title FROM github_nodes WHERE github_node_id = ?",
                arguments: [fixture.pullRequest.nodeID.rawValue]
            )
        }
        XCTAssertEqual(persistedTitle, fixture.pullRequest.title)
    }

    func testCrossPullRequestReceiptCannotAuthorizeReviewDeletion() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = PullRequestReviewRepository(vault: fixture.vault)
        try await repository.replace(
            reviews: [review(nodeID: "R_retained", state: "APPROVED")],
            pullRequestNodeID: fixture.pullRequest.nodeID,
            replacementProof: try await fixture.reviewProof(
                reviews: [review(nodeID: "R_retained", state: "APPROVED")]
            ),
            observedAt: fixture.date
        )
        let otherPullRequest = fixture.pullRequest(
            nodeID: GitHubNodeID(rawValue: "PR_receipt_other")!,
            number: 2,
            title: "Receipt other"
        )
        try await GitHubNodeDetailsRepository(vault: fixture.vault).save(
            HydratedGitHubNode(
                node: otherPullRequest,
                details: .pullRequest(
                    isDraft: false, mergeableState: nil, headRef: "other", baseRef: "main",
                    reviewDecision: nil, assigneeNodeIDs: [], labelNodeIDs: [], labelNames: []
                )
            ),
            accountID: fixture.accountID,
            observedAt: fixture.date
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                reviews: [],
                pullRequestNodeID: fixture.pullRequest.nodeID,
                replacementProof: try await fixture.reviewProof(
                    reviews: [],
                    for: otherPullRequest
                ),
                observedAt: fixture.date.addingTimeInterval(1)
            )
        } verify: { error in
            XCTAssertEqual(error as? PullRequestReviewRepositoryError, .invalidTraversalReceipt)
        }
        let retained = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT github_node_id FROM reviews WHERE pull_request_node_id = ?",
                arguments: [fixture.pullRequest.nodeID.rawValue]
            )
        }
        XCTAssertEqual(retained, ["R_retained"])
    }

    func testDigestMismatchedReplacementCannotDeleteExistingReviews() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = PullRequestReviewRepository(vault: fixture.vault)
        let retainedReview = review(nodeID: "R_digest_retained", state: "APPROVED")
        try await repository.replace(
            reviews: [retainedReview],
            pullRequestNodeID: fixture.pullRequest.nodeID,
            replacementProof: try await fixture.reviewProof(reviews: [retainedReview]),
            observedAt: fixture.date
        )
        let validEmptyProof = try await fixture.reviewProof(reviews: [])

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                reviews: [self.review(nodeID: "R_digest_replacement", state: "CHANGES_REQUESTED")],
                pullRequestNodeID: fixture.pullRequest.nodeID,
                replacementProof: validEmptyProof,
                observedAt: fixture.date.addingTimeInterval(1)
            )
        } verify: { error in
            XCTAssertEqual(error as? PullRequestReviewRepositoryError, .invalidTraversalReceipt)
        }
        let retained = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT github_node_id FROM reviews WHERE pull_request_node_id = ?",
                arguments: [fixture.pullRequest.nodeID.rawValue]
            )
        }
        XCTAssertEqual(retained, [retainedReview.nodeID])
    }

    func testReviewThreadReplacementWithoutCompleteReceiptRetainsStaleNodesAndComputesResponseRequirement() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = PullRequestReviewThreadRepository(vault: fixture.vault)
        let reviewer = ActorSummary(
            id: ActorID(rawValue: "U_2")!,
            nodeID: GitHubNodeID(rawValue: "U_2")!,
            login: "reviewer",
            displayName: nil,
            avatarURL: nil
        )
        let record = PullRequestReviewThreadRecord(
            nodeID: GitHubNodeID(rawValue: "T_1")!,
            isResolved: false,
            isOutdated: false,
            comments: [
                PullRequestReviewThreadCommentRecord(
                    nodeID: GitHubNodeID(rawValue: "C_1")!,
                    author: reviewer,
                    body: "Please update",
                    createdAt: fixture.date,
                    updatedAt: fixture.date.addingTimeInterval(1),
                    url: URL(string: "https://github.com/github/triage/pull/1#discussion_r1")!
                )
            ],
            updatedAt: fixture.date.addingTimeInterval(1)
        )
        try await repository.replace(
            pullRequestNodeID: fixture.pullRequest.nodeID,
            organizationID: fixture.organizationID,
            repositoryID: fixture.repositoryID,
            currentUserNodeID: GitHubNodeID(rawValue: "U_1")!,
            inventory: .init(
                records: [record],
                rawPages: [.init(endpoint: "graphql:TriagePullRequestReviewThreads", payload: Data("{}".utf8))],
                metrics: .init(pageCount: 1, responseBytes: 2, queryCost: 1)
            ),
            observedAt: fixture.date.addingTimeInterval(2)
        )
        let initial = try await fixture.vault.read { database in
            (
                try Bool.fetchOne(
                    database,
                    sql: "SELECT requires_current_user_response FROM review_threads WHERE github_node_id = 'T_1'"
                ),
                try Int.fetchOne(
                    database,
                    sql: "SELECT unresolved_thread_count FROM pull_requests WHERE github_node_id = ?",
                    arguments: [fixture.pullRequest.nodeID.rawValue]
                )
            )
        }
        XCTAssertEqual(initial.0, true)
        XCTAssertEqual(initial.1, 1)
        try await repository.replace(
            pullRequestNodeID: fixture.pullRequest.nodeID,
            organizationID: fixture.organizationID,
            repositoryID: fixture.repositoryID,
            currentUserNodeID: GitHubNodeID(rawValue: "U_1")!,
            inventory: .init(
                records: [],
                rawPages: [],
                metrics: .init(pageCount: 0, responseBytes: 0, queryCost: 0)
            ),
            observedAt: fixture.date.addingTimeInterval(3)
        )

        let persisted = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM review_threads"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM comments"),
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM github_nodes WHERE github_node_id IN ('T_1', 'C_1')"
                ),
                try Int.fetchOne(
                    database,
                    sql: "SELECT unresolved_thread_count FROM pull_requests WHERE github_node_id = ?",
                    arguments: [fixture.pullRequest.nodeID.rawValue]
                ),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")
            )
        }
        XCTAssertEqual(persisted.0, 1)
        XCTAssertEqual(persisted.1, 1)
        XCTAssertEqual(persisted.2, 2)
        XCTAssertEqual(persisted.3, 1)
        XCTAssertEqual(persisted.4, 1)
    }

    func testRefreshPersistsReviewSourcesAndReconciledStateAtomically() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let restClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: ReviewRefreshSession(responses: [
                    "/repos/github/triage/pulls/1/reviews?per_page=100": Data(
                        #"[{"id":1,"node_id":"R_1","state":"APPROVED","body":"Looks good","submitted_at":"2025-01-01T00:00:00Z"}]"#.utf8
                    ),
                    "/repos/github/triage/pulls/1/requested_reviewers": Data(
                        #"{"users":[{"node_id":"U_1","login":"reviewer"}],"teams":[]}"#.utf8
                    )
                ])
            ),
            credential: SecretValue("token")
        )
        let service = PullRequestReviewRefreshService(
            client: GitHubPullRequestClient(client: restClient),
            candidateRepository: PullRequestReviewCandidateRepository(vault: fixture.vault),
            corroborationOverride: .agreement
        )

        let result = try await service.refresh(
            scope: SynchronizationScope(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
            ),
            githubOrganizationID: 2,
            observedAt: fixture.date,
            streamID: fixture.reviewStreamID
        )

        XCTAssertEqual(result.refreshedPullRequestNodeIDs, [fixture.pullRequest.nodeID])
        XCTAssertFalse(result.hasRemainingCandidates)
        let persisted = try await fixture.vault.read { database in
            (
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM raw_api_snapshots WHERE github_node_id = ?",
                    arguments: [fixture.pullRequest.nodeID.rawValue]
                ),
                try String.fetchAll(
                    database,
                    sql: "SELECT github_node_id FROM reviews ORDER BY github_node_id"
                ),
                try String.fetchAll(
                    database,
                    sql: "SELECT requested_reviewer_node_id FROM review_requests"
                ),
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM review_candidate_complete_traversal_receipts"
                ),
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM review_candidate_complete_traversal_segments"
                ),
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM review_candidate_complete_traversal_pages"
                ),
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*)
                        FROM review_candidate_complete_traversal_pages
                        WHERE is_terminal = 1
                        """
                )
            )
        }
        XCTAssertEqual(persisted.0, 2)
        XCTAssertEqual(persisted.1, ["R_1"])
        XCTAssertEqual(persisted.2, ["U_1"])
        XCTAssertEqual(persisted.3, 1)
        XCTAssertEqual(persisted.4, 2)
        XCTAssertEqual(persisted.5, 2)
        XCTAssertEqual(persisted.6, 2)
    }

    private func review(nodeID: String, state: String) -> GitHubPullRequestReviewDTO {
        GitHubPullRequestReviewDTO(
            id: 1,
            nodeID: nodeID,
            state: state,
            body: nil,
            submittedAt: nil
        )
    }
}

private final class Fixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "github")!
    let repositoryID = RepositoryID(rawValue: "triage")!
    let date = Date(timeIntervalSinceReferenceDate: 1_000)
    let vault: AccountVault
    let pullRequest: NormalizedGitHubNode
    let reviewStreamID = SyncStreamID(rawValue: "pull-request-review-reconciliation-test")!

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjE=")!,
            login: "github"
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
                checkedAt: date
            ),
            selectedAt: date
        )
        try await SyncStreamRepository(vault: vault).save(
            SyncStream(
                id: reviewStreamID,
                accountID: accountID,
                organizationID: organizationID,
                feature: .reviews,
                highWater: nil,
                lastSuccessfulAt: nil,
                lastAttemptAt: date,
                status: .partial,
                failureDetail: nil
            )
        )
        let fixtureRepositoryID = repositoryID
        let fixtureOrganizationID = organizationID
        let fixtureAccountID = accountID
        let fixtureDate = date
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login, name,
                        is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, 1, 0, 0, ?, ?, NULL)
                    """,
                arguments: [
                    fixtureRepositoryID.rawValue,
                    fixtureOrganizationID.rawValue,
                    "1",
                    "MDEwOlJlcG9zaXRvcnkx",
                    "github",
                    "triage",
                    "https://github.com/github/triage",
                    Int64((fixtureDate.timeIntervalSince1970 * 1_000).rounded())
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_repository_access (account_id, repository_id, access_state, observed_at_ms)
                    VALUES (?, ?, 'available', ?)
                    """,
                arguments: [
                    fixtureAccountID.rawValue,
                    fixtureRepositoryID.rawValue,
                    Int64((fixtureDate.timeIntervalSince1970 * 1_000).rounded())
                ]
            )
        }
        pullRequest = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "MDExOlB1bGxSZXF1ZXN0MQ==")!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            kind: .pullRequest,
            numericID: "1",
            number: 1,
            title: "Review reconciliation",
            state: .open,
            url: URL(string: "https://github.com/github/triage/pull/1")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: date,
            updatedAt: date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "revision-1",
            observedAt: date,
            accessibility: .accessible
        )
        try await GitHubNodeDetailsRepository(vault: vault).save(
            HydratedGitHubNode(
                node: pullRequest,
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
            observedAt: date
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func node(title: String) -> NormalizedGitHubNode {
        NormalizedGitHubNode(
            nodeID: pullRequest.nodeID,
            accountID: pullRequest.accountID,
            organizationID: pullRequest.organizationID,
            repositoryID: pullRequest.repositoryID,
            kind: pullRequest.kind,
            numericID: pullRequest.numericID,
            number: pullRequest.number,
            title: title,
            state: pullRequest.state,
            url: pullRequest.url,
            bodyMarkdown: pullRequest.bodyMarkdown,
            authorID: pullRequest.authorID,
            createdAt: pullRequest.createdAt,
            updatedAt: pullRequest.updatedAt,
            closedAt: pullRequest.closedAt,
            mergedAt: pullRequest.mergedAt,
            sourceRevision: pullRequest.sourceRevision,
            observedAt: pullRequest.observedAt,
            accessibility: pullRequest.accessibility
        )
    }

    func pullRequest(
        nodeID: GitHubNodeID,
        number: Int,
        title: String
    ) -> NormalizedGitHubNode {
        NormalizedGitHubNode(
            nodeID: nodeID,
            accountID: pullRequest.accountID,
            organizationID: pullRequest.organizationID,
            repositoryID: pullRequest.repositoryID,
            kind: .pullRequest,
            numericID: String(number),
            number: number,
            title: title,
            state: .open,
            url: URL(string: "https://github.com/github/triage/pull/\(number)")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: date,
            updatedAt: date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "revision-\(number)",
            observedAt: date,
            accessibility: .accessible
        )
    }

    func reviewReceipt(
        for pullRequest: NormalizedGitHubNode? = nil,
        reviews: [GitHubPullRequestReviewDTO] = [],
        requestedReviewers: GitHubRequestedReviewersDTO = .init(users: [], teams: [])
    ) async throws -> ReviewCandidateCompleteTraversalReceiptToken {
        let pullRequest = pullRequest ?? self.pullRequest
        guard let pullRequestNumber: Int = pullRequest.number else {
            throw FixtureError.missingPullRequestNumber
        }
        let scope = SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
        let candidate = PullRequestReviewCandidate(
            nodeID: pullRequest.nodeID,
            repositoryID: repositoryID,
            repository: try GitHubRepositoryPath(owner: "github", repository: "triage"),
            number: pullRequestNumber,
            sourceRevision: pullRequest.sourceRevision
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reviewPayload = try encoder.encode(reviews)
        let requestedReviewerPayload = try encoder.encode(requestedReviewers)
        let page = { (requestKey: String, payload: Data) in
            ReviewCandidateTraversalPage(
                ordinal: 1,
                rawSnapshotID: .make(),
                requestIdentity: .init(
                    scope: scope,
                    feature: .reviews,
                    streamID: self.reviewStreamID,
                    requestKey: requestKey
                ),
                endpoint: requestKey,
                payload: payload,
                isTerminal: true
            )
        }
        return try await ReviewCandidateCompleteTraversalReceiptRepository(vault: vault).persist(
            .init(
                scope: scope,
                feature: .reviews,
                streamID: self.reviewStreamID,
                candidate: candidate,
                candidateSourceRevision: pullRequest.sourceRevision,
                parserVersion: 1,
                observedAt: date,
                normalizedDigest: PullRequestReviewReplacementProof.normalizedDigest(
                    reviews: reviews,
                    requestedReviewers: requestedReviewers
                ),
                segments: [
                    .init(
                        kind: .reviewHistory,
                        pages: [page(
                            "GET /repos/github/triage/pulls/\(pullRequestNumber)/reviews?per_page=100",
                            reviewPayload
                        )]
                    ),
                    .init(
                        kind: .requestedReviewers,
                        pages: [page(
                            "GET /repos/github/triage/pulls/\(pullRequestNumber)/requested_reviewers",
                            requestedReviewerPayload
                        )]
                    )
                ]
            )
        )
    }

    func reviewProof(
        reviews: [GitHubPullRequestReviewDTO] = [],
        requestedReviewers: GitHubRequestedReviewersDTO = .init(users: [], teams: []),
        for pullRequest: NormalizedGitHubNode? = nil
    ) async throws -> PullRequestReviewReplacementProof {
        let receipt = try await reviewReceipt(
            for: pullRequest,
            reviews: reviews,
            requestedReviewers: requestedReviewers
        )
        return try await vault.writeTransaction { database in
            try PullRequestReviewReplacementProof.make(
                reviews: reviews,
                requestedReviewers: requestedReviewers,
                completeTraversalReceipt: receipt,
                in: database
            )
        }
    }
}

private enum FixtureError: Error, Equatable {
    case expectedRollback
    case missingPullRequestNumber
}

private actor ReviewRefreshSession: HTTPSession {
    private let responses: [String: Data]

    init(responses: [String: Data]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let pathAndQuery = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard let response = responses[pathAndQuery] else {
            throw URLError(.resourceUnavailable)
        }
        return (
            response,
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
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
