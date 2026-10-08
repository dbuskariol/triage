import Foundation
import XCTest
@testable import Triage

final class AIConsentRepositoryTests: XCTestCase {
    func testReplyModelIsStoredSeparatelyAndDefaultsToTheTriageChoice() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".triage-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let organizationID = try XCTUnwrap(OrganizationID(rawValue: "org"))
        let vault = try await VaultRegistry(rootDirectory: directory).open(accountID: accountID, vaultKey: VaultKey.generate())
        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID, githubUserID: 1, nodeID: GitHubNodeID(rawValue: "account-node")!,
                login: "me", authenticationKind: .oauth, credentialID: CredentialID(rawValue: "credential")!,
                credentialStatus: .active, createdAt: Date()
            ),
            credentialRevision: CredentialRevision(rawValue: "revision")!
        )
        try await vault.writeTransaction { database in
            try database.execute(sql: """
                INSERT INTO organizations (id, github_organization_id, github_node_id, login, updated_at_ms)
                VALUES ('org', '2', 'org-node', 'octo', 1)
                """)
            try database.execute(sql: """
                INSERT INTO account_organizations (account_id, organization_id, access_state, capability_revision, checked_at_ms)
                VALUES (?, 'org', 'available', 'cap', 1)
                """, arguments: [accountID.rawValue])
        }
        let repository = AIConsentRepository(vault: vault)
        let triage = CopilotModelChoice(modelID: "big-model", reasoningEffort: "high", contextTier: "long_context")

        try await repository.save(.init(accountID: accountID, organizationID: organizationID, isEnabled: true,
                                        selectedModelID: triage.modelID, reasoningEffort: triage.reasoningEffort,
                                        contextTier: triage.contextTier, updatedAt: .now))
        var consent = try await repository.consent(for: accountID, organizationID: organizationID)
        XCTAssertNil(consent.replyChoice)
        XCTAssertEqual(consent.effectiveReplyChoice, triage)

        let reply = CopilotModelChoice(modelID: "fast-model", reasoningEffort: "low", contextTier: nil)
        try await repository.save(.init(accountID: accountID, organizationID: organizationID, isEnabled: true,
                                        selectedModelID: triage.modelID, reasoningEffort: triage.reasoningEffort,
                                        contextTier: triage.contextTier, replyChoice: reply, updatedAt: .now))
        consent = try await repository.consent(for: accountID, organizationID: organizationID)
        XCTAssertEqual(consent.triageChoice, triage)
        XCTAssertEqual(consent.effectiveReplyChoice, reply)
    }
}
