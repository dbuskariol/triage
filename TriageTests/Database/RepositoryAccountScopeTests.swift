import XCTest
@testable import Triage

final class RepositoryAccountScopeTests: XCTestCase {
    func testNodeWorkItemAndSearchRepositoriesRejectAnotherVaultAccount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vaultAccountID = AccountID.make()
        let foreignAccountID = AccountID.make()
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: vaultAccountID,
            vaultKey: try VaultKey.generate()
        )
        let node = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "MDU6SXNzdWUx")!,
            accountID: foreignAccountID,
            organizationID: OrganizationID(rawValue: "github")!,
            repositoryID: nil,
            kind: .issue,
            numericID: "1",
            number: 1,
            title: "Foreign account node",
            state: .open,
            url: URL(string: "https://github.com/github/triage/issues/1")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: .now,
            updatedAt: .now,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "revision-1",
            observedAt: .now,
            accessibility: .accessible
        )

        do {
            try await GitHubNodeRepository(vault: vault).save(node)
            XCTFail("Expected a node account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? GitHubNodeRepositoryError, .accountScopeMismatch)
        }
        do {
            _ = try await WorkItemRepository(vault: vault).ensureWorkItem(for: node)
            XCTFail("Expected a work item account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? WorkItemRepositoryError, .accountScopeMismatch)
        }
        do {
            _ = try await SearchRepository(vault: vault).search(
                "foreign",
                accountID: foreignAccountID,
                organizationID: node.organizationID
            )
            XCTFail("Expected a search account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? SearchRepositoryError, .accountScopeMismatch)
        }

        let foreignWorkItemID = WorkItemID.make()
        do {
            try await WorkflowRepository(vault: vault).save(
                WorkflowState(
                    status: .active,
                    isPinned: false,
                    priority: .normal,
                    updatedAt: .now
                ),
                for: foreignWorkItemID
            )
            XCTFail("Expected a workflow work item scope mismatch.")
        } catch {
            XCTAssertEqual(error as? WorkflowRepositoryError, .workItemScopeMismatch)
        }
        do {
            try await AttentionReasonRepository(vault: vault).replaceDiscoveryReasons(
                workItemID: foreignWorkItemID,
                reasons: []
            )
            XCTFail("Expected an attention work item scope mismatch.")
        } catch {
            XCTAssertEqual(error as? AttentionReasonRepositoryError, .workItemScopeMismatch)
        }
        do {
            try await AttentionScoreRepository(vault: vault).save(
                AttentionScore(value: 1, breakdown: ["direct": 1]),
                for: foreignWorkItemID
            )
            XCTFail("Expected an attention score work item scope mismatch.")
        } catch {
            XCTAssertEqual(error as? AttentionScoreRepositoryError, .workItemScopeMismatch)
        }
        do {
            try await WorkItemGraphRepository(vault: vault).replace(
                workItemID: foreignWorkItemID,
                members: [],
                contextLinks: []
            )
            XCTFail("Expected a work item graph scope mismatch.")
        } catch {
            XCTAssertEqual(error as? WorkItemGraphRepositoryError, .workItemScopeMismatch)
        }
        do {
            try await TimelineRepository(vault: vault).save(
                TimelineEventSummary(
                    id: GitHubEventID(rawValue: "event-1")!,
                    subjectNodeID: GitHubNodeID(rawValue: "MDU6SXNzdWU5OTk=")!,
                    kind: .commented,
                    actor: nil,
                    occurredAt: .now,
                    url: nil,
                    body: nil
                ),
                sourceRevision: "event-1"
            )
            XCTFail("Expected a timeline subject scope mismatch.")
        } catch {
            XCTAssertEqual(error as? TimelineRepositoryError, .subjectNodeScopeMismatch)
        }
        do {
            try await PullRequestReviewRepository(vault: vault).save(
                review: GitHubPullRequestReviewDTO(
                    id: 1,
                    nodeID: "MDM6UmV2aWV3MQ==",
                    state: "APPROVED",
                    body: nil,
                    submittedAt: nil
                ),
                pullRequestNodeID: GitHubNodeID(rawValue: "MDQ6UHVsbFJlcXVlc3Q5OTk=")!
            )
            XCTFail("Expected a pull request scope mismatch.")
        } catch {
            XCTAssertEqual(error as? PullRequestReviewRepositoryError, .pullRequestNodeScopeMismatch)
        }
    }
}
