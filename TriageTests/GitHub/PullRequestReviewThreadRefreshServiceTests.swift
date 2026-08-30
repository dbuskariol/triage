import Foundation
import GRDB
import XCTest
@testable import Triage

final class PullRequestReviewThreadRefreshServiceTests: XCTestCase {
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
            observedAt: fixture.observedAt
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
        XCTAssertEqual(persisted.0, 1)
        XCTAssertEqual(persisted.1, fixture.firstPullRequest.nodeID.rawValue)
        XCTAssertEqual(persisted.2, "THREAD_1")
        XCTAssertEqual(persisted.3, "Please update this line.")
    }

    func testFailureDoesNotPreventLaterSuccessAndOutcomesRemainInCandidateOrder() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let secondPullRequest = try await fixture.addPullRequest(nodeID: "PR_2", number: 2)
        let fetcher = ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .failure(.generic),
            secondPullRequest.nodeID: .inventory(fixture.inventory(threadID: "THREAD_2", commentID: "COMMENT_2"))
        ])

        let result = try await fixture.service(fetcher: fetcher).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.outcomes.map(\.pullRequestNodeID), [fixture.firstPullRequest.nodeID, secondPullRequest.nodeID])
        XCTAssertEqual(result.outcomes.map(\.status), [.failed, .refreshed])
        let persistedThreadIDs = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT github_node_id FROM review_threads ORDER BY github_node_id")
        }
        XCTAssertEqual(persistedThreadIDs, ["THREAD_2"])
    }

    func testSSOAndApprovalFailuresAreRedactedAndClassified() async throws {
        let fixture = try await ReviewThreadRefreshFixture()
        defer { fixture.remove() }
        let secondPullRequest = try await fixture.addPullRequest(nodeID: "PR_2", number: 2)
        let thirdPullRequest = try await fixture.addPullRequest(nodeID: "PR_3", number: 3)
        let fetcher = ReviewThreadFetcher(plans: [
            fixture.firstPullRequest.nodeID: .failure(.sso),
            secondPullRequest.nodeID: .failure(.approval),
            thirdPullRequest.nodeID: .failure(.unrelatedSSO)
        ])

        let result = try await fixture.service(fetcher: fetcher).refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.observedAt
        )

        guard case let .ssoRequired(header) = result.outcomes[0].status else {
            return XCTFail("The selected organization's SSO recovery header must remain actionable in memory.")
        }
        XCTAssertEqual(
            header,
            .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso-secret")!)
        )
        XCTAssertEqual(result.outcomes[1].status, .approvalRequired)
        XCTAssertEqual(result.outcomes[2].status, .unavailableOrPermission)
        let persistedDetail = try XCTUnwrap(result.coverageAssessment.failureDetail)
        XCTAssertFalse(persistedDetail.contains("https://"))
        XCTAssertFalse(persistedDetail.contains("sso-secret"))
        XCTAssertFalse(persistedDetail.contains("approval-secret"))
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
                observedAt: fixture.observedAt
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
                observedAt: fixture.observedAt
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
            observedAt: fixture.observedAt
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
                hasRemainingCandidates: hasRemaining
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
}

private actor ReviewThreadFetcher: PullRequestReviewThreadFetching {
    enum Plan: Sendable {
        case inventory(GitHubPullRequestReviewThreadInventory)
        case failure(Failure)
    }

    enum Failure: Error, Sendable {
        case generic
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
        case .failure(.sso):
            throw GitHubGraphQLError.requestFailed(
                GitHubFailure(
                    kind: .forbidden,
                    statusCode: 403,
                    ssoHeader: .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso-secret")!)
                )
            )
        case .failure(.approval):
            throw GitHubGraphQLError.requestFailed(
                GitHubFailure(
                    kind: .forbidden,
                    statusCode: 403,
                    accessRestriction: .organizationApprovalRequired
                )
            )
        case .failure(.unrelatedSSO):
            throw GitHubGraphQLError.requestFailed(
                GitHubFailure(
                    kind: .forbidden,
                    statusCode: 403,
                    ssoHeader: .partialResults([999])
                )
            )
        }
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
        let repositoryID = repositoryID
        let organizationID = organizationID
        let observedAt = observedAt
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
                    Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
                ]
            )
        }
        firstPullRequest = try await addPullRequest(nodeID: "PR_1", number: 1)
    }

    func service(fetcher: any PullRequestReviewThreadFetching) -> PullRequestReviewThreadRefreshService {
        PullRequestReviewThreadRefreshService(
            fetcher: fetcher,
            candidateRepository: PullRequestReviewCandidateRepository(vault: vault),
            threadRepository: PullRequestReviewThreadRepository(vault: vault),
            currentUserNodeID: GitHubNodeID(rawValue: "USER_1")!
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

    func inventory(threadID: String, commentID: String) -> GitHubPullRequestReviewThreadInventory {
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
            rawPages: [
                GitHubPullRequestReviewThreadRawPage(
                    endpoint: "graphql:TriagePullRequestReviewThreads/page=1",
                    payload: Data("{\"data\":{}}".utf8)
                )
            ],
            metrics: .init(pageCount: 1, responseBytes: 11, queryCost: 1)
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
                comments: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM comments")!
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
