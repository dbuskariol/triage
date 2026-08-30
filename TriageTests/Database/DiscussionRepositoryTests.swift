import Foundation
import GRDB
import XCTest
@testable import Triage

final class DiscussionRepositoryTests: XCTestCase {
    func testInvalidReplacementPreservesPriorDiscussionAndRawSnapshotsAreStored() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = DiscussionRepository(vault: fixture.vault)
        let valid = fixture.discussion(id: "D_1", title: "Retained")
        let raw = GitHubDiscussionRawPage(endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1",
                                          payload: Data("{}".utf8))
        try await repository.replace([valid], rawPages: [raw], accountID: fixture.account.id, organization: fixture.organization,
                                     repositoryID: fixture.repositoryID, observedAt: fixture.date)

        let invalid = fixture.discussion(id: "D_2", title: "")
        await XCTAssertThrowsErrorAsync {
            try await repository.replace([invalid], rawPages: [raw], accountID: fixture.account.id, organization: fixture.organization,
                                         repositoryID: fixture.repositoryID, observedAt: fixture.date)
        }
        let persisted = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT title FROM github_nodes WHERE kind = 'discussion'"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")
            )
        }
        XCTAssertEqual(persisted.0, ["Retained"])
        XCTAssertEqual(persisted.1, 1)
    }

    func testIncompleteProjectFieldValuesRetainLastCompleteValues() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let project = fixture.project()
        let raw = GitHubProjectV2RawPage(endpoint: "graphql:TriageOrganizationProjectsV2/organization=O_2/page=1",
                                         payload: Data("{}".utf8))
        try await repository.replaceProjects([project], rawPages: [raw], accountID: fixture.account.id,
                                             organization: fixture.organization, observedAt: fixture.date)
        let complete = fixture.projectItem(project: project, displayValue: "Ready", complete: true)
        try await repository.replaceItems([complete], project: project, rawPages: [raw], accountID: fixture.account.id,
                                          organization: fixture.organization, observedAt: fixture.date)
        let incomplete = fixture.projectItem(project: project, displayValue: nil, complete: false)
        try await repository.replaceItems([incomplete], project: project, rawPages: [raw], accountID: fixture.account.id,
                                          organization: fixture.organization, observedAt: fixture.date)

        let values = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT display_value FROM project_field_values")
        }
        XCTAssertEqual(values, ["Ready"])
    }
}

private final class DiscussionFixture: @unchecked Sendable {
    let root: URL
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let repositoryID = RepositoryID(rawValue: "R_1")!
    let date = Date(timeIntervalSince1970: 1_000)

    init() async throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".triage-discussion-test-\(UUID().uuidString)", isDirectory: true)
        let accountID = AccountID.make()
        account = .init(id: accountID, githubUserID: 1, nodeID: GitHubNodeID(rawValue: "U_1")!, login: "octocat",
                        authenticationKind: .oauth, credentialID: CredentialID.make(), credentialStatus: .active,
                        createdAt: date, lastValidatedAt: date)
        organization = .init(id: OrganizationID(rawValue: "acme")!, githubOrganizationID: 2,
                             nodeID: GitHubNodeID(rawValue: "O_2")!, login: "acme")
        vault = try await VaultRegistry(rootDirectory: root).open(accountID: accountID, vaultKey: VaultKey.generate())
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(account, credentialRevision: CredentialRevision(rawValue: "credential-1")!)
        try await accounts.save(
            organization,
            access: .init(accountID: accountID, organizationID: organization.id, state: .available,
                          capabilityRevision: CapabilityRevision(rawValue: "capability-1")!, capabilities: [], checkedAt: date)
        )
        _ = try await accounts.save(
            repository: .init(id: 3, nodeID: repositoryID.rawValue, name: "repo", isPrivate: true, isArchived: false,
                              hasDiscussions: true, htmlURL: URL(string: "https://github.com/acme/repo")!, updatedAt: date,
                              owner: .init(login: "acme")),
            organizationID: organization.id, accountID: accountID
        )
    }

    func discussion(id: String, title: String) -> GitHubDiscussionRecord {
        .init(nodeID: GitHubNodeID(rawValue: id)!, number: 1, title: title, body: nil,
              url: URL(string: "https://github.com/acme/repo/discussions/1")!, createdAt: date, updatedAt: date,
              closedAt: nil, state: .open, categoryName: nil, answerCommentNodeID: nil, commentsCount: 0)
    }

    func project() -> GitHubProjectV2Record {
        .init(nodeID: GitHubNodeID(rawValue: "P_1")!, number: 1, title: "Roadmap", description: nil,
              url: URL(string: "https://github.com/orgs/acme/projects/1")!, updatedAt: date, state: .open)
    }

    func projectItem(project: GitHubProjectV2Record, displayValue: String?, complete: Bool) -> GitHubProjectV2ItemRecord {
        .init(
            nodeID: GitHubNodeID(rawValue: "PVTI_1")!, projectNodeID: project.nodeID, contentNodeID: nil,
            contentKind: nil, updatedAt: date,
            fieldValues: [.init(fieldName: "Status", valueKind: "ProjectV2ItemFieldSingleSelectValue",
                                displayValue: displayValue, dateValue: nil, actorNodeID: nil,
                                context: complete ? "ProjectV2ItemFieldSingleSelectValue" : "unsupported union",
                                isAuthoritative: complete)],
            fieldValuesComplete: complete
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error.", file: file, line: line)
    } catch {}
}
