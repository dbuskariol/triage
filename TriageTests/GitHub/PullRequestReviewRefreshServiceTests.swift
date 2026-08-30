import Foundation
import GRDB
import XCTest
@testable import Triage

final class PullRequestReviewRefreshServiceTests: XCTestCase {
    func testSelectedOrganizationPartialRequestedReviewersRetainsBothCachedInventories() async throws {
        let fixture = try await PullRequestReviewRefreshFixture()
        defer { fixture.remove() }
        try await fixture.seedCachedReviewState()
        let service = try fixture.service(responses: [
            fixture.reviewsPath: .response(Data("[]".utf8)),
            fixture.requestedReviewersPath: .response(
                Data(#"{"users":[],"teams":[]}"#.utf8),
                headers: [
                    "X-GitHub-SSO": "partial-results; organizations=\(fixture.githubOrganizationID)"
                ]
            )
        ])

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.date.addingTimeInterval(10)
        )

        XCTAssertEqual(result.refreshedPullRequestNodeIDs, [])
        XCTAssertEqual(
            result.ssoHeader?.scoped(to: fixture.githubOrganizationID),
            .partialResults([fixture.githubOrganizationID])
        )
        let cached = try await fixture.persistedReviewState(for: fixture.pullRequest.nodeID)
        XCTAssertEqual(cached.reviewNodeIDs, [fixture.cachedReviewNodeID.rawValue])
        XCTAssertEqual(cached.requestedReviewerNodeIDs, [fixture.cachedReviewerNodeID.rawValue])
    }

    func testUnrelatedOrganizationPartialHeaderAllowsCleanReplacement() async throws {
        let fixture = try await PullRequestReviewRefreshFixture()
        defer { fixture.remove() }
        try await fixture.seedCachedReviewState()
        let service = try fixture.service(responses: [
            fixture.reviewsPath: .response(
                fixture.reviewPayload(nodeID: fixture.replacementReviewNodeID.rawValue),
                headers: ["X-GitHub-SSO": "partial-results; organizations=999"]
            ),
            fixture.requestedReviewersPath: .response(
                fixture.requestedReviewersPayload(nodeID: fixture.replacementReviewerNodeID.rawValue)
            )
        ])

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.date.addingTimeInterval(10)
        )

        XCTAssertEqual(result.refreshedPullRequestNodeIDs, [fixture.pullRequest.nodeID])
        XCTAssertNil(result.ssoHeader?.scoped(to: fixture.githubOrganizationID))
        let persisted = try await fixture.persistedReviewState(for: fixture.pullRequest.nodeID)
        XCTAssertEqual(persisted.reviewNodeIDs, [fixture.replacementReviewNodeID.rawValue])
        XCTAssertEqual(
            persisted.requestedReviewerNodeIDs,
            [fixture.replacementReviewerNodeID.rawValue]
        )
    }

    func testCompleteCleanEmptyResponsesClearOnlyExactPullRequestState() async throws {
        let fixture = try await PullRequestReviewRefreshFixture()
        defer { fixture.remove() }
        try await fixture.seedCachedReviewState()
        let secondPullRequestNodeID = try await fixture.seedInaccessibleSecondPullRequestState()
        let service = try fixture.service(responses: [
            fixture.reviewsPath: .response(Data("[]".utf8)),
            fixture.requestedReviewersPath: .response(Data(#"{"users":[],"teams":[]}"#.utf8))
        ])

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: fixture.githubOrganizationID,
            observedAt: fixture.date.addingTimeInterval(10)
        )

        XCTAssertEqual(result.refreshedPullRequestNodeIDs, [fixture.pullRequest.nodeID])
        let cleared = try await fixture.persistedReviewState(for: fixture.pullRequest.nodeID)
        XCTAssertEqual(cleared.reviewNodeIDs, [])
        XCTAssertEqual(cleared.requestedReviewerNodeIDs, [])
        let retained = try await fixture.persistedReviewState(for: secondPullRequestNodeID)
        XCTAssertEqual(retained.reviewNodeIDs, [fixture.secondReviewNodeID.rawValue])
        XCTAssertEqual(retained.requestedReviewerNodeIDs, [fixture.secondReviewerNodeID.rawValue])
    }

    func testSecondFetchFailureRetainsBothCachedInventories() async throws {
        let fixture = try await PullRequestReviewRefreshFixture()
        defer { fixture.remove() }
        try await fixture.seedCachedReviewState()
        let service = try fixture.service(responses: [
            fixture.reviewsPath: .response(Data("[]".utf8)),
            fixture.requestedReviewersPath: .failure(.networkConnectionLost)
        ])

        do {
            _ = try await service.refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                observedAt: fixture.date.addingTimeInterval(10)
            )
            XCTFail("Expected the second fetch to fail.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }

        let cached = try await fixture.persistedReviewState(for: fixture.pullRequest.nodeID)
        XCTAssertEqual(cached.reviewNodeIDs, [fixture.cachedReviewNodeID.rawValue])
        XCTAssertEqual(cached.requestedReviewerNodeIDs, [fixture.cachedReviewerNodeID.rawValue])
    }

    func testSecondFetchCancellationRetainsBothCachedInventories() async throws {
        let fixture = try await PullRequestReviewRefreshFixture()
        defer { fixture.remove() }
        try await fixture.seedCachedReviewState()
        let service = try fixture.service(responses: [
            fixture.reviewsPath: .response(Data("[]".utf8)),
            fixture.requestedReviewersPath: .cancellation
        ])

        do {
            _ = try await service.refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                observedAt: fixture.date.addingTimeInterval(10)
            )
            XCTFail("Expected the second fetch to be cancelled.")
        } catch is CancellationError {
            // Expected.
        }

        let cached = try await fixture.persistedReviewState(for: fixture.pullRequest.nodeID)
        XCTAssertEqual(cached.reviewNodeIDs, [fixture.cachedReviewNodeID.rawValue])
        XCTAssertEqual(cached.requestedReviewerNodeIDs, [fixture.cachedReviewerNodeID.rawValue])
    }

    func testCredentialRotationDuringReviewResponseCancelsWithoutDurableWrites() async throws {
        try await assertScopeRotationDuringReviewResponse(.credential)
    }

    func testCapabilityRotationDuringReviewResponseCancelsWithoutDurableWrites() async throws {
        try await assertScopeRotationDuringReviewResponse(.capability)
    }

    private func assertScopeRotationDuringReviewResponse(
        _ rotation: PullRequestReviewScopeRotation
    ) async throws {
        let fixture = try await PullRequestReviewRefreshFixture()
        defer { fixture.remove() }
        let gate = PullRequestReviewResponseGate()
        let service = try fixture.service(
            responses: [
                fixture.reviewsPath: .response(
                    fixture.reviewPayload(nodeID: fixture.replacementReviewNodeID.rawValue)
                ),
                fixture.requestedReviewersPath: .response(
                    fixture.requestedReviewersPayload(
                        nodeID: fixture.replacementReviewerNodeID.rawValue
                    )
                )
            ],
            gate: gate
        )
        let task = Task {
            try await service.refresh(
                scope: fixture.scope,
                githubOrganizationID: fixture.githubOrganizationID,
                observedAt: fixture.date.addingTimeInterval(10)
            )
        }

        await gate.waitUntilEntered()
        let before = try await fixture.durableState()
        try await fixture.rotate(rotation)
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected scope rotation to cancel review refresh.")
        } catch is CancellationError {
            // Expected supersession.
        }
        let after = try await fixture.durableState()
        XCTAssertEqual(after, before)
    }
}

private enum PullRequestReviewScopeRotation {
    case credential
    case capability
}

private struct PullRequestReviewDurableState: Equatable {
    let rawSnapshots: Int
    let reviews: Int
    let reviewRequests: Int
}

private final class PullRequestReviewRefreshFixture: @unchecked Sendable {
    struct PersistedReviewState: Equatable {
        let reviewNodeIDs: [String]
        let requestedReviewerNodeIDs: [String]
    }

    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "github")!
    let githubOrganizationID: UInt64 = 2
    let repositoryID = RepositoryID(rawValue: "triage")!
    let date = Date(timeIntervalSinceReferenceDate: 1_000)
    let vault: AccountVault
    let pullRequest: NormalizedGitHubNode
    let cachedReviewNodeID = GitHubNodeID(rawValue: "R_cached")!
    let cachedReviewerNodeID = GitHubNodeID(rawValue: "U_cached")!
    let replacementReviewNodeID = GitHubNodeID(rawValue: "R_replacement")!
    let replacementReviewerNodeID = GitHubNodeID(rawValue: "U_replacement")!
    let secondReviewNodeID = GitHubNodeID(rawValue: "R_second")!
    let secondReviewerNodeID = GitHubNodeID(rawValue: "U_second")!

    var scope: SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
    }

    var reviewsPath: String { "/repos/github/triage/pulls/1/reviews?per_page=100" }
    var requestedReviewersPath: String { "/repos/github/triage/pulls/1/requested_reviewers" }

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: GitHubNodeID(rawValue: "U_account")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: date,
                lastValidatedAt: date
            ),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await AccountRepository(vault: vault).save(
            GitHubOrganization(
                id: organizationID,
                githubOrganizationID: githubOrganizationID,
                nodeID: GitHubNodeID(rawValue: "O_github")!,
                login: "github"
            ),
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
        let fixtureRepositoryID = repositoryID
        let fixtureOrganizationID = organizationID
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
                    "R_repository",
                    "github",
                    "triage",
                    "https://github.com/github/triage",
                    Self.milliseconds(fixtureDate)
                ]
            )
        }
        pullRequest = Self.pullRequest(
            nodeID: GitHubNodeID(rawValue: "PR_1")!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            number: 1,
            date: date,
            accessibility: .accessible
        )
        try await savePullRequest(pullRequest)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func service(
        responses: [String: PullRequestReviewRefreshSession.Outcome],
        gate: PullRequestReviewResponseGate? = nil
    ) throws -> PullRequestReviewRefreshService {
        let restClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: PullRequestReviewRefreshSession(responses: responses, gate: gate)
            ),
            credential: SecretValue("token")
        )
        return PullRequestReviewRefreshService(
            client: GitHubPullRequestClient(client: restClient),
            candidateRepository: PullRequestReviewCandidateRepository(vault: vault)
        )
    }

    func durableState() async throws -> PullRequestReviewDurableState {
        try await vault.read { database in
            PullRequestReviewDurableState(
                rawSnapshots: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM raw_api_snapshots"
                )!,
                reviews: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM reviews")!,
                reviewRequests: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM review_requests"
                )!
            )
        }
    }

    func rotate(_ rotation: PullRequestReviewScopeRotation) async throws {
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

    func seedCachedReviewState() async throws {
        try await seedReviewState(
            pullRequestNodeID: pullRequest.nodeID,
            reviewNodeID: cachedReviewNodeID,
            reviewerNodeID: cachedReviewerNodeID
        )
    }

    func seedInaccessibleSecondPullRequestState() async throws -> GitHubNodeID {
        let secondPullRequest = Self.pullRequest(
            nodeID: GitHubNodeID(rawValue: "PR_2")!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            number: 2,
            date: date.addingTimeInterval(1),
            accessibility: .accessible
        )
        try await savePullRequest(secondPullRequest)
        try await seedReviewState(
            pullRequestNodeID: secondPullRequest.nodeID,
            reviewNodeID: secondReviewNodeID,
            reviewerNodeID: secondReviewerNodeID
        )
        try await vault.write { database in
            try database.execute(
                sql: "UPDATE github_nodes SET accessibility_state = ? WHERE github_node_id = ?",
                arguments: [
                    GitHubNodeAccessibility.inaccessible.rawValue,
                    secondPullRequest.nodeID.rawValue
                ]
            )
        }
        return secondPullRequest.nodeID
    }

    func persistedReviewState(for pullRequestNodeID: GitHubNodeID) async throws -> PersistedReviewState {
        try await vault.read { database in
            PersistedReviewState(
                reviewNodeIDs: try String.fetchAll(
                    database,
                    sql: """
                        SELECT github_node_id
                        FROM reviews
                        WHERE pull_request_node_id = ?
                        ORDER BY github_node_id
                        """,
                    arguments: [pullRequestNodeID.rawValue]
                ),
                requestedReviewerNodeIDs: try String.fetchAll(
                    database,
                    sql: """
                        SELECT requested_reviewer_node_id
                        FROM review_requests
                        WHERE pull_request_node_id = ?
                        ORDER BY requested_reviewer_node_id
                        """,
                    arguments: [pullRequestNodeID.rawValue]
                )
            )
        }
    }

    func reviewPayload(nodeID: String) -> Data {
        Data(
            """
            [{"id":2,"node_id":"\(nodeID)","state":"APPROVED","body":"Ready"}]
            """.utf8
        )
    }

    func requestedReviewersPayload(nodeID: String) -> Data {
        Data(
            """
            {"users":[{"node_id":"\(nodeID)","login":"reviewer"}],"teams":[]}
            """.utf8
        )
    }

    private func seedReviewState(
        pullRequestNodeID: GitHubNodeID,
        reviewNodeID: GitHubNodeID,
        reviewerNodeID: GitHubNodeID
    ) async throws {
        try await PullRequestReviewRepository(vault: vault).replace(
            reviews: [
                GitHubPullRequestReviewDTO(
                    id: 1,
                    nodeID: reviewNodeID.rawValue,
                    state: "APPROVED",
                    body: "Cached review",
                    submittedAt: date
                )
            ],
            pullRequestNodeID: pullRequestNodeID,
            observedAt: date
        )
        try await PullRequestReviewRequestRepository(vault: vault).replace(
            GitHubRequestedReviewersDTO(
                users: [
                    .init(nodeID: reviewerNodeID.rawValue, login: "cached-reviewer", slug: nil)
                ],
                teams: []
            ),
            pullRequestNodeID: pullRequestNodeID,
            observedAt: date
        )
    }

    private func savePullRequest(_ node: NormalizedGitHubNode) async throws {
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
            observedAt: node.observedAt
        )
    }

    private static func pullRequest(
        nodeID: GitHubNodeID,
        accountID: AccountID,
        organizationID: OrganizationID,
        repositoryID: RepositoryID,
        number: Int,
        date: Date,
        accessibility: GitHubNodeAccessibility
    ) -> NormalizedGitHubNode {
        NormalizedGitHubNode(
            nodeID: nodeID,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            kind: .pullRequest,
            numericID: String(number),
            number: number,
            title: "Pull request \(number)",
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
            accessibility: accessibility
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private actor PullRequestReviewRefreshSession: HTTPSession {
    enum Outcome: Sendable {
        case response(Data, headers: [String: String] = [:])
        case failure(URLError.Code)
        case cancellation
    }

    private let responses: [String: Outcome]
    private let gate: PullRequestReviewResponseGate?

    init(
        responses: [String: Outcome],
        gate: PullRequestReviewResponseGate? = nil
    ) {
        self.responses = responses
        self.gate = gate
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let pathAndQuery = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard let outcome = responses[pathAndQuery] else {
            throw URLError(.resourceUnavailable)
        }
        if let gate {
            await gate.enterAndWait()
        }
        switch outcome {
        case let .response(body, headers):
            return (
                body,
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                )!
            )
        case let .failure(code):
            throw URLError(code)
        case .cancellation:
            throw CancellationError()
        }
    }
}

private actor PullRequestReviewResponseGate {
    private var entered = false
    private var released = false
    private var enteredWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
