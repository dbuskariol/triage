import Foundation
import XCTest
@testable import Triage

final class DerivedIntelligenceRepositoryTests: XCTestCase {
    func testReplaceAtomicallyRemovesStaleDerivedRowsAndRefreshesFTS() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)

        try await repository.replace(fixture.snapshot(reasonID: "stale", title: "Stale searchable title"))
        try await repository.replace(fixture.snapshot(reasonID: "current", title: "Current searchable title"))

        let workItems = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(workItems.count, 1)
        XCTAssertEqual(workItems[0].attentionReasons.map(\.id), ["current"])
        XCTAssertEqual(workItems[0].attentionReasons[0].evidence.map(\.id.rawValue), ["evidence-current"])
        XCTAssertEqual(workItems[0].score, AttentionScore(value: 900, breakdown: ["attentionReason": 900]))

        let search = SearchRepository(vault: fixture.vault)
        let staleResults = try await search.search(
            "stale", accountID: fixture.accountID, organizationID: fixture.organizationID
        )
        XCTAssertTrue(staleResults.isEmpty)
        let currentResults = try await search.search(
            "current", accountID: fixture.accountID, organizationID: fixture.organizationID
        )
        XCTAssertEqual(currentResults.compactMap(\.workItemID), [fixture.workItemID])
    }

    func testRejectsPartialSnapshotWithoutChangingExistingDerivedState() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(fixture.snapshot(reasonID: "current", title: "Current title"))

        let incomplete = DerivedIntelligencePersistenceSnapshot(
            scope: fixture.scope,
            evaluatedAt: fixture.date,
            items: []
        )
        do {
            try await repository.replace(incomplete)
            XCTFail("Expected incomplete snapshot rejection.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .incompleteWorkItemSnapshot)
        }

        let reasonIDs = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT id FROM attention_reasons ORDER BY id")
        }
        XCTAssertEqual(reasonIDs, ["current"])
    }

    func testPersistedWaitingWakeUpReasonMakesWaitingWorkEligibleForInbox() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await WorkflowRepository(vault: fixture.vault).save(
            WorkflowState(status: .waiting, updatedAt: fixture.date),
            for: fixture.workItemID
        )
        try await DerivedIntelligenceRepository(vault: fixture.vault).replace(
            fixture.snapshot(
                reasonID: "wake-up",
                title: "Waiting title",
                ruleID: WaitingAttentionRuleID.awaitedActorResponded.rawValue
            )
        )

        let workItems = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        let workItem = try XCTUnwrap(workItems.first)
        XCTAssertEqual(workItem.workflow.status, .waiting)
        XCTAssertEqual(InboxEligibilityRule().disposition(for: workItem, at: fixture.date), .inbox)
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID(rawValue: "derived-account")!
        let organizationID = OrganizationID(rawValue: "derived-organization")!
        let workItemID: WorkItemID
        let nodeID = GitHubNodeID(rawValue: "derived-node")!
        let date = Date(timeIntervalSinceReferenceDate: 10_000)
        let vault: AccountVault

        var scope: SynchronizationScope {
            SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: CredentialRevision(rawValue: "credential")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability")!
            )
        }

        init() async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(".derived-intelligence-repository-tests-\(UUID().uuidString)", isDirectory: true)
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            try await AccountRepository(vault: vault).save(
                GitHubAccount(
                    id: accountID,
                    githubUserID: 1,
                    nodeID: GitHubNodeID(rawValue: "derived-user")!,
                    login: "octocat",
                    authenticationKind: .oauth,
                    credentialID: CredentialID.make(),
                    credentialStatus: .active,
                    createdAt: date,
                    lastValidatedAt: date
                ),
                credentialRevision: CredentialRevision(rawValue: "credential")!
            )
            try await AccountRepository(vault: vault).save(
                GitHubOrganization(
                    id: organizationID,
                    githubOrganizationID: 2,
                    nodeID: GitHubNodeID(rawValue: "derived-organization-node")!,
                    login: "github"
                ),
                access: OrganizationAccess(
                    accountID: accountID,
                    organizationID: organizationID,
                    state: .available,
                    capabilityRevision: CapabilityRevision(rawValue: "capability")!,
                    capabilities: [],
                    checkedAt: date
                ),
                selectedAt: date
            )
            let node = NormalizedGitHubNode(
                nodeID: nodeID,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                kind: .issue,
                numericID: "1",
                number: 1,
                title: "Derived intelligence",
                state: .open,
                url: URL(string: "https://github.com/github/triage/issues/1")!,
                bodyMarkdown: nil,
                authorID: nil,
                createdAt: date,
                updatedAt: date,
                closedAt: nil,
                mergedAt: nil,
                sourceRevision: "revision",
                observedAt: date,
                accessibility: .accessible
            )
            try await GitHubNodeRepository(vault: vault).save(node)
            workItemID = try await WorkItemRepository(vault: vault).ensureWorkItem(for: node)
        }

        func snapshot(
            reasonID: String,
            title: String,
            ruleID: String = "changesRequested"
        ) -> DerivedIntelligencePersistenceSnapshot {
            let reason = AttentionReason(
                id: reasonID,
                category: ruleID == WaitingAttentionRuleID.awaitedActorResponded.rawValue ? .waiting : .pullRequest,
                ruleID: ruleID,
                ruleVersion: 1,
                strength: 900,
                title: "Changes requested",
                explanation: "A reviewer requested changes.",
                evidence: [
                    EvidenceReference(
                        id: EvidenceID(rawValue: "evidence-\(reasonID)")!,
                        source: .restReview,
                        locator: .legacyUnverified,
                        authority: .legacyUnverified,
                        nodeID: nodeID,
                        confidence: .provisional,
                        confirmation: .provisional,
                        observedAt: date
                    )
                ],
                evaluatedAt: date
            )
            return DerivedIntelligencePersistenceSnapshot(
                scope: scope,
                evaluatedAt: date,
                items: [
                    DerivedIntelligencePersistenceItem(
                        workItemID: workItemID,
                        attentionReasons: [reason],
                        score: AttentionScore(value: 900, breakdown: ["attentionReason": 900]),
                        searchDocument: SearchDocument(
                            accountID: accountID,
                            organizationID: organizationID,
                            workItemID: workItemID,
                            nodeID: nodeID,
                            title: title,
                            body: "",
                            repository: "",
                            labels: "",
                            people: "",
                            projectValues: "",
                            actionText: "",
                            localNote: ""
                        )
                    )
                ]
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
