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

    func testDiscussionReplacementAndCoverageRollbackTogether() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = DiscussionRepository(vault: fixture.vault)
        let invalidAccountID = AccountID.make()
        let coverage = fixture.coverage(
            accountID: invalidAccountID,
            feature: .discussions,
            stream: "discussions-acme-R_1",
            status: .complete
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                [fixture.discussion(id: "D_atomic", title: "Must roll back")],
                rawPages: [.init(endpoint: "graphql:atomic", payload: Data("{}".utf8))],
                accountID: fixture.account.id,
                organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                observedAt: fixture.date,
                coverageRecords: [coverage]
            )
        }

        let counts = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM discussions")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM coverage_records")!
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
    }

    func testProjectItemLinksOnlyToAnExistingNodeInTheCurrentScope() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let project = fixture.project()
        let contentNodeID = GitHubNodeID(rawValue: "I_1")!
        try await fixture.vault.write { database in
            try GitHubNodeRepository.save(
                .init(
                    nodeID: contentNodeID,
                    accountID: fixture.account.id,
                    organizationID: fixture.organization.id,
                    repositoryID: fixture.repositoryID,
                    kind: .issue,
                    numericID: "9",
                    number: 1,
                    title: "Relevant issue",
                    state: .open,
                    url: URL(string: "https://github.com/acme/repo/issues/1")!,
                    bodyMarkdown: nil,
                    authorID: nil,
                    createdAt: fixture.date,
                    updatedAt: fixture.date,
                    closedAt: nil,
                    mergedAt: nil,
                    sourceRevision: "one",
                    observedAt: fixture.date,
                    accessibility: .accessible
                ),
                in: database
            )
        }
        try await repository.replaceProjects(
            [project], rawPages: [], accountID: fixture.account.id,
            organization: fixture.organization, observedAt: fixture.date
        )
        let item = fixture.projectItem(project: project, contentNodeID: contentNodeID)
        try await repository.replaceItems(
            [item], project: project, rawPages: [], accountID: fixture.account.id,
            organization: fixture.organization, observedAt: fixture.date
        )

        let link = try await fixture.vault.read { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT content_node_id, content_node_reference FROM project_items"
            )
            return (row?["content_node_id"] as String?, row?["content_node_reference"] as String?)
        }
        XCTAssertEqual(link.0, contentNodeID.rawValue)
        XCTAssertEqual(link.1, contentNodeID.rawValue)
    }

    func testDiscussionSynchronizationPersistsMetadataAndUnavailableNestedCoverageAtomically() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let session = OneShotDiscussionSession(.data(discussionInventoryResponse()))
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )
        let streamID = SyncStreamID(rawValue: "discussions-acme-R_1")!
        let prior = fixture.date.addingTimeInterval(-3_600)

        let result = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositoryID: fixture.repositoryID,
            repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
            streamID: streamID,
            previousHighWater: prior,
            observedAt: fixture.date
        )

        XCTAssertEqual(result.coverage.status, .complete)
        XCTAssertEqual(result.commentCoverage, .unavailable)
        XCTAssertEqual(result.replyCoverage, .unavailable)
        let coverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertEqual(
            Set(coverage.map(\.feature)),
            [.discussions, .discussionComments, .discussionReplies]
        )
        XCTAssertEqual(
            coverage.first(where: { $0.feature == .discussions })?.intervalStart,
            prior.addingTimeInterval(-5 * 60)
        )
        let stream = try await SyncStreamRepository(vault: fixture.vault)
            .stream(withID: streamID, accountID: fixture.account.id)
        XCTAssertEqual(stream?.highWater, fixture.date)
    }

    func testProjectReferenceBackfillCannotCrossParentProjectOrganization() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let contentNodeID = GitHubNodeID(rawValue: "I_scope")!
        try await fixture.vault.write { database in
            try GitHubNodeRepository.save(
                .init(
                    nodeID: contentNodeID, accountID: fixture.account.id,
                    organizationID: fixture.organization.id, repositoryID: fixture.repositoryID,
                    kind: .issue, numericID: "19", number: 19, title: "Scoped issue",
                    state: .open, url: URL(string: "https://github.com/acme/repo/issues/19")!,
                    bodyMarkdown: nil, authorID: nil, createdAt: fixture.date,
                    updatedAt: fixture.date, closedAt: nil, mergedAt: nil,
                    sourceRevision: "scope", observedAt: fixture.date, accessibility: .accessible
                ),
                in: database
            )
        }
        let otherOrganization = GitHubOrganization(
            id: OrganizationID(rawValue: "beta")!, githubOrganizationID: 22,
            nodeID: GitHubNodeID(rawValue: "O_22")!, login: "beta"
        )
        try await AccountRepository(vault: fixture.vault).save(
            otherOrganization,
            access: .init(
                accountID: fixture.account.id, organizationID: otherOrganization.id,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-2")!,
                capabilities: [], checkedAt: fixture.date
            )
        )
        let otherProject = GitHubProjectV2Record(
            nodeID: GitHubNodeID(rawValue: "P_2")!, number: 2, title: "Other",
            description: nil, url: URL(string: "https://github.com/orgs/beta/projects/2")!,
            updatedAt: fixture.date, state: .open
        )
        try await repository.replaceProjects(
            [otherProject], rawPages: [], accountID: fixture.account.id,
            organization: otherOrganization, observedAt: fixture.date
        )
        let otherItem = GitHubProjectV2ItemRecord(
            nodeID: GitHubNodeID(rawValue: "PVTI_2")!, projectNodeID: otherProject.nodeID,
            contentNodeID: contentNodeID, contentKind: .issue, updatedAt: fixture.date,
            fieldValues: [], fieldValuesComplete: true
        )
        try await repository.replaceItems(
            [otherItem], project: otherProject, rawPages: [], accountID: fixture.account.id,
            organization: otherOrganization, observedAt: fixture.date
        )

        try await repository.resolveContentReferences(
            accountID: fixture.account.id,
            organizationID: fixture.organization.id
        )

        let linked = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT content_node_id FROM project_items WHERE github_node_id = 'PVTI_2'"
            )
        }
        XCTAssertNil(linked)
    }

    func testDiscussionSynchronizationCancellationPublishesNoFailureCoverage() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let session = OneShotDiscussionSession(.cancellation)
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await service.refresh(
                scope: fixture.scope,
                organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!,
                previousHighWater: nil,
                observedAt: fixture.date
            )
        }, verify: { error in
            XCTAssertTrue(error is CancellationError)
        })
        let coverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertTrue(coverage.isEmpty)
    }

    func testDiscussionMissingDataRetainsRawFailureWithoutAdvancingHighWater() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let session = OneShotDiscussionSession(
            .data(Data(#"{"data":null}"#.utf8))
        )
        let streamID = SyncStreamID(rawValue: "discussions-acme-R_1")!
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await service.refresh(
                scope: fixture.scope, organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: streamID, previousHighWater: nil, observedAt: fixture.date
            )
        }, verify: { error in
            guard case GitHubDiscussionClientError.missingData = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        })

        let persisted = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM normalization_failures")!
            )
        }
        XCTAssertEqual(persisted.0, 1)
        XCTAssertEqual(persisted.1, 1)
        let coverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id, organizationID: fixture.organization.id
        )
        XCTAssertEqual(coverage.first?.status, .partial)
        let stream = try await SyncStreamRepository(vault: fixture.vault).stream(
            withID: streamID, accountID: fixture.account.id
        )
        XCTAssertNil(stream?.highWater)
    }

    func testDiscussionPartialResultsRetainRawEvidenceAndPersistPartialCoverage() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let header = "partial-results; organizations=\(fixture.organization.githubOrganizationID)"
        let session = OneShotDiscussionSession(
            .response(discussionInventoryResponse(), ["X-GitHub-SSO": header])
        )
        let streamID = SyncStreamID(rawValue: "discussions-acme-R_1")!
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await service.refresh(
                scope: fixture.scope,
                organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: streamID,
                previousHighWater: nil,
                observedAt: fixture.date
            )
        }, verify: { error in
            guard case let GitHubDiscussionClientError.ssoResponse(pages, parsedHeader) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(parsedHeader, GitHubSSOHeader(value: header))
            XCTAssertEqual(pages.count, 1)
        })

        let persisted = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!
        }
        XCTAssertEqual(persisted, 1)
        let coverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertEqual(coverage.first?.status, .partial)
        let stream = try await SyncStreamRepository(vault: fixture.vault)
            .stream(withID: streamID, accountID: fixture.account.id)
        XCTAssertNil(stream?.highWater)
    }

    func testDiscussionUndecodableResponseRetainsRawFailureWithoutAdvancingHighWater() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let malformed = Data("{".utf8)
        let session = OneShotDiscussionSession(.data(malformed))
        let streamID = SyncStreamID(rawValue: "discussions-acme-R_1")!
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await service.refresh(
                scope: fixture.scope, organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: streamID, previousHighWater: nil, observedAt: fixture.date
            )
        }, verify: { error in
            guard case let GitHubDiscussionClientError.undecodableResponse(pages) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(pages.count, 1)
            XCTAssertEqual(pages[0].payload, malformed)
        })

        let persisted = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM normalization_failures")!,
                try Data.fetchOne(database, sql: "SELECT payload FROM raw_api_snapshots")
            )
        }
        XCTAssertEqual(persisted.0, 1)
        XCTAssertEqual(persisted.1, 1)
        XCTAssertEqual(persisted.2, malformed)
        let coverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id, organizationID: fixture.organization.id
        )
        XCTAssertEqual(coverage.first?.status, .partial)
        let stream = try await SyncStreamRepository(vault: fixture.vault).stream(
            withID: streamID, accountID: fixture.account.id
        )
        XCTAssertNil(stream?.highWater)
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
        root = FileManager.default.temporaryDirectory
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

    func projectItem(
        project: GitHubProjectV2Record,
        displayValue: String? = nil,
        complete: Bool = true,
        contentNodeID: GitHubNodeID? = nil
    ) -> GitHubProjectV2ItemRecord {
        .init(
            nodeID: GitHubNodeID(rawValue: "PVTI_1")!, projectNodeID: project.nodeID, contentNodeID: contentNodeID,
            contentKind: contentNodeID == nil ? nil : .issue, updatedAt: date,
            fieldValues: [.init(fieldName: "Status", valueKind: "ProjectV2ItemFieldSingleSelectValue",
                                displayValue: displayValue, dateValue: nil, actorNodeID: nil,
                                context: complete ? "ProjectV2ItemFieldSingleSelectValue" : "unsupported union",
                                isAuthoritative: complete)],
            fieldValuesComplete: complete
        )
    }

    func coverage(
        accountID: AccountID,
        feature: CoverageFeature,
        stream: String,
        status: CoverageStatus
    ) -> CoverageRecord {
        .init(
            accountID: accountID,
            organizationID: organization.id,
            repositoryID: repositoryID,
            feature: feature,
            streamID: SyncStreamID(rawValue: stream)!,
            intervalStart: date,
            intervalEnd: date,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
            status: status,
            lastSuccessfulAt: status == .complete ? date : nil,
            failureDetail: nil
        )
    }

    var scope: SynchronizationScope {
        .init(
            accountID: account.id,
            organizationID: organization.id,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line,
    verify: ((Error) -> Void)? = nil
) async {
    do {
        try await expression()
        XCTFail("Expected error.", file: file, line: line)
    } catch {
        verify?(error)
    }
}

private enum OneShotDiscussionResult: Sendable {
    case data(Data)
    case response(Data, [String: String])
    case cancellation
}

private actor OneShotDiscussionSession: HTTPSession {
    private let result: OneShotDiscussionResult

    init(_ result: OneShotDiscussionResult) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let headers: [String: String]?
        switch result {
        case let .data(value):
            data = value
            headers = nil
        case let .response(value, responseHeaders):
            data = value
            headers = responseHeaders
        case .cancellation:
            throw CancellationError()
        }
        return (
            data,
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers
            )!
        )
    }
}

private func discussionInventoryResponse() -> Data {
    Data("""
    {"data":{"node":{"id":"R_1","discussions":{"nodes":[{"id":"D_1","number":1,"title":"Discussion","body":null,"url":"https://github.com/acme/repo/discussions/1","createdAt":"1970-01-01T00:16:40Z","updatedAt":"1970-01-01T00:16:40Z","closedAt":null,"isAnswered":false,"category":null,"answer":null,"comments":{"totalCount":0}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}
