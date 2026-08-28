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
    }
}
