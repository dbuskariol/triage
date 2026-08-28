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
            observedAt: fixture.date
        )
        try await repository.replace(
            reviews: [review(nodeID: "MDM6UmV2aWV3Mg==", state: "CHANGES_REQUESTED")],
            pullRequestNodeID: fixture.pullRequest.nodeID,
            observedAt: fixture.date
        )

        let persistedNodeIDs = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT github_node_id FROM reviews ORDER BY github_node_id"
            )
        }
        XCTAssertEqual(persistedNodeIDs, ["MDM6UmV2aWV3Mg=="])
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
            observedAt: fixture.date
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                GitHubRequestedReviewersDTO(
                    users: [.init(nodeID: "", login: "invalid", slug: nil)],
                    teams: []
                ),
                pullRequestNodeID: fixture.pullRequest.nodeID,
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
            candidateRepository: PullRequestReviewCandidateRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.date
        )

        XCTAssertEqual(result.refreshedPullRequestNodeIDs, [fixture.pullRequest.nodeID])
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
                )
            )
        }
        XCTAssertEqual(persisted.0, 2)
        XCTAssertEqual(persisted.1, ["R_1"])
        XCTAssertEqual(persisted.2, ["U_1"])
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
                    "MDEwOlJlcG9zaXRvcnkx",
                    "github",
                    "triage",
                    "https://github.com/github/triage",
                    Int64((date.timeIntervalSince1970 * 1_000).rounded())
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
}

private enum FixtureError: Error, Equatable {
    case expectedRollback
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
