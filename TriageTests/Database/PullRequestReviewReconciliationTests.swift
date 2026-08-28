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
        pullRequest = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "MDExOlB1bGxSZXF1ZXN0MQ==")!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
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
