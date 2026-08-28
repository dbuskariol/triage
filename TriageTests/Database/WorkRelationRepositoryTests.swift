import XCTest
@testable import Triage

final class WorkRelationRepositoryTests: XCTestCase {
    func testReplacingRelationsPersistsEvidenceAndRemovesStaleRelations() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let workItemRepository = WorkItemRepository(vault: fixture.vault)
        let workItemID = try await workItemRepository.ensureWorkItem(for: fixture.node)
        let relation = fixture.relation
        let repository = WorkRelationRepository(vault: fixture.vault)

        try await repository.replace(
            [relation],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID
        )

        let persisted = try await workItemRepository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].id, workItemID)
        XCTAssertEqual(persisted[0].relations, [relation])

        try await repository.replace(
            [],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID
        )
        let relationCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relations")
        }
        let evidenceCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relation_evidence")
        }
        XCTAssertEqual(relationCount, 0)
        XCTAssertEqual(evidenceCount, 0)
    }

    func testRejectsRelationsForAnotherVaultAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        do {
            try await WorkRelationRepository(vault: fixture.vault).replace(
                [fixture.relation],
                accountID: AccountID.make(),
                subjectNodeID: fixture.node.nodeID
            )
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? WorkRelationRepositoryError, .accountScopeMismatch)
        }
    }

    func testRejectsRelationsForANodeOutsideTheVaultAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        do {
            try await WorkRelationRepository(vault: fixture.vault).replace(
                [],
                accountID: fixture.accountID,
                subjectNodeID: GitHubNodeID(rawValue: "MDU6SXNzdWU5OTk=")!
            )
            XCTFail("Expected a source node scope mismatch.")
        } catch {
            XCTAssertEqual(error as? WorkRelationRepositoryError, .subjectNodeScopeMismatch)
        }
    }

    func testRawAPISnapshotsRoundTripWithinTheirAccountScope() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: "/repos/github/triage/issues/1",
            eTag: "\"revision-1\"",
            parserVersion: 1,
            observedAt: fixture.date,
            payload: Data("{\"number\":1}".utf8)
        )
        let repository = RawAPISnapshotRepository(vault: fixture.vault)
        try await repository.save(snapshot)

        XCTAssertEqual(
            try await repository.snapshots(for: fixture.accountID),
            [snapshot]
        )

        do {
            try await repository.save(
                RawAPISnapshot(
                    id: RawAPISnapshotID.make(),
                    accountID: AccountID.make(),
                    githubNodeID: fixture.node.nodeID,
                    endpoint: snapshot.endpoint,
                    eTag: nil,
                    parserVersion: 1,
                    observedAt: fixture.date,
                    payload: snapshot.payload
                )
            )
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? RawAPISnapshotRepositoryError, .accountScopeMismatch)
        }
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "github")!
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let vault: AccountVault
        let node: NormalizedGitHubNode
        let relation: WorkRelation

        init() async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            let accountNodeID = GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!
            let account = GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: accountNodeID,
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
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: date
            )
            let accountRepository = AccountRepository(vault: vault)
            try await accountRepository.save(
                account,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!
            )
            try await accountRepository.save(organization, access: access, selectedAt: date)

            node = NormalizedGitHubNode(
                nodeID: GitHubNodeID(rawValue: "MDU6SXNzdWUx")!,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                kind: .issue,
                numericID: "1",
                number: 1,
                title: "Fix work item projection",
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
            try await GitHubNodeRepository(vault: vault).save(node)
            relation = WorkRelation(
                kind: .assigned,
                subjectNodeID: node.nodeID,
                objectNodeID: accountNodeID,
                confidence: .confirmed,
                evidence: [
                    EvidenceReference(
                        id: EvidenceID(rawValue: "assignment-1")!,
                        source: .restSearch,
                        nodeID: node.nodeID,
                        sourceRevision: node.sourceRevision,
                        observedAt: date,
                        excerpt: "assignee:octocat"
                    )
                ],
                observedAt: date
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
