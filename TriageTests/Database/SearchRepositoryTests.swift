import XCTest
@testable import Triage

final class SearchRepositoryTests: XCTestCase {
    func testRebuildIndexesEncryptedCachedContentByOrganization() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "github")!
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let accountRepository = AccountRepository(vault: vault)
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
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
        let access = OrganizationAccess(
            accountID: accountID,
            organizationID: organizationID,
            state: .available,
            capabilityRevision: CapabilityRevision(rawValue: "cap-1")!,
            capabilities: [],
            checkedAt: date
        )
        try await accountRepository.save(account, credentialRevision: CredentialRevision(rawValue: "cred-1")!)
        try await accountRepository.save(organization, access: access, selectedAt: date)

        let node = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "MDU6SXNzdWUx")!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            kind: .issue,
            numericID: "1",
            number: 1,
            title: "Harden local search",
            state: .open,
            url: URL(string: "https://github.com/github/triage/issues/1")!,
            bodyMarkdown: "Keep every cache page encrypted with SQLCipher.",
            authorID: nil,
            createdAt: date,
            updatedAt: date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "1",
            observedAt: date,
            accessibility: .accessible
        )
        try await GitHubNodeRepository(vault: vault).save(node)
        let workItemID = try await WorkItemRepository(vault: vault).ensureWorkItem(for: node)
        let commentNode = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: "MDEyOklzc3VlQ29tbWVudDE=")!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            kind: .issueComment,
            numericID: "2",
            number: nil,
            title: "Comment",
            state: .open,
            url: URL(string: "https://github.com/github/triage/issues/1#issuecomment-2")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: date,
            updatedAt: date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "2",
            observedAt: date,
            accessibility: .accessible
        )
        try await GitHubNodeRepository(vault: vault).save(commentNode)
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO comments (
                        github_node_id, parent_node_id, author_id, kind, body_markdown,
                        created_at_ms, updated_at_ms, html_url
                    ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    commentNode.nodeID.rawValue,
                    node.nodeID.rawValue,
                    GitHubContentKind.issueComment.rawValue,
                    "Search the comment body too.",
                    1_000,
                    1_000,
                    commentNode.url.absoluteString
                ]
            )
        }
        try await WorkflowRepository(vault: vault).save(
            WorkflowState(
                status: .active,
                isPinned: false,
                priority: .normal,
                localNote: "Remember to validate the FTS index.",
                updatedAt: date
            ),
            for: workItemID
        )
        try await WorkflowRepository(vault: vault).save(
            ActionItem(
                id: ActionItemID.make(),
                workItemID: workItemID,
                title: "Review SQLite query",
                origin: .manual,
                state: .open,
                priority: .normal,
                createdAt: date,
                updatedAt: date
            )
        )

        let repository = SearchRepository(vault: vault)
        try await repository.rebuild(accountID: accountID, organizationID: organizationID)

        for query in ["harden", "sqlcipher", "comment", "validate", "sqlite"] {
            let results = try await repository.search(
                query,
                accountID: accountID,
                organizationID: organizationID
            )
            XCTAssertEqual(results.compactMap(\.workItemID), [workItemID])
        }
    }

    func testSearchTreatsOperatorsAsPlainText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: AccountID.make(),
            vaultKey: try VaultKey.generate()
        )
        let repository = SearchRepository(vault: vault)

        let results = try await repository.search(
            "OR NEAR \"",
            accountID: AccountID.make(),
            organizationID: OrganizationID(rawValue: "github")!
        )

        XCTAssertTrue(results.isEmpty)
    }
}
