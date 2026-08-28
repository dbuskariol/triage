import XCTest
@testable import Triage

final class WorkItemGroupingDecisionRepositoryTests: XCTestCase {
    func testReplacingDecisionsRestoresEvidenceAndRemovesStaleRows() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = WorkItemGroupingDecisionRepository(vault: fixture.vault)
        let decision = fixture.decision
        try await repository.replace([decision], accountID: fixture.accountID)
        XCTAssertEqual(
            try await repository.decisions(for: fixture.accountID),
            [decision]
        )

        try await repository.replace([], accountID: fixture.accountID)
        XCTAssertTrue(try await repository.decisions(for: fixture.accountID).isEmpty)
    }

    func testRejectsDecisionReferencingNodeOutsideVaultAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let foreignNode = fixture.node(
            id: GitHubNodeID(rawValue: "foreign-node")!,
            accountID: AccountID.make()
        )
        let decision = WorkItemGroupingDecision(
            sourceNodeID: fixture.firstNode.nodeID,
            destinationNodeID: foreignNode.nodeID,
            relation: .closes,
            strength: .strong,
            evidence: [],
            decidedAt: fixture.date
        )

        do {
            try await WorkItemGroupingDecisionRepository(vault: fixture.vault).replace(
                [decision],
                accountID: fixture.accountID
            )
            XCTFail("Expected a node scope mismatch.")
        } catch {
            XCTAssertEqual(
                error as? WorkItemGroupingDecisionRepositoryError,
                .nodeScopeMismatch
            )
        }
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "github")!
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let vault: AccountVault
        let firstNode: NormalizedGitHubNode
        let secondNode: NormalizedGitHubNode
        let decision: WorkItemGroupingDecision

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
                nodeID: GitHubNodeID(rawValue: "account-node")!,
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
                nodeID: GitHubNodeID(rawValue: "organization-node")!,
                login: "github"
            )
            let access = OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: date
            )
            let accounts = AccountRepository(vault: vault)
            try await accounts.save(
                account,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!
            )
            try await accounts.save(organization, access: access, selectedAt: date)

            firstNode = node(id: GitHubNodeID(rawValue: "first-node")!, accountID: accountID)
            secondNode = node(id: GitHubNodeID(rawValue: "second-node")!, accountID: accountID)
            let nodes = GitHubNodeRepository(vault: vault)
            try await nodes.save(firstNode)
            try await nodes.save(secondNode)
            decision = WorkItemGroupingDecision(
                sourceNodeID: firstNode.nodeID,
                destinationNodeID: secondNode.nodeID,
                relation: .closes,
                strength: .strong,
                evidence: [
                    EvidenceReference(
                        id: EvidenceID(rawValue: "link-evidence")!,
                        source: .restTimeline,
                        nodeID: firstNode.nodeID,
                        sourceRevision: "revision-1",
                        observedAt: date,
                        excerpt: "Linked pull request closes this issue."
                    )
                ],
                decidedAt: date
            )
        }

        func node(id: GitHubNodeID, accountID: AccountID) -> NormalizedGitHubNode {
            NormalizedGitHubNode(
                nodeID: id,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                kind: .issue,
                numericID: nil,
                number: nil,
                title: "Grouping node",
                state: .open,
                url: URL(string: "https://github.com/github/triage/issues/1")!,
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
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
