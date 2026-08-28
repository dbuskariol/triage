import XCTest
@testable import Triage

final class SearchShardExecutorTests: XCTestCase {
    func testOversizedSearchBisectsAndPersistsCompletedShards() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let client = SearchClient { query, _ in
            let rootRange = "updated:1970-01-01T00:00:00Z..1970-01-01T00:02:00Z"
            let isRoot = query.value.contains(rootRange)
            return GitHubResponse(
                value: GitHubIssueSearchPage(
                    totalCount: isRoot ? 1_001 : 1,
                    incompleteResults: false,
                    items: []
                ),
                payload: Data(),
                etag: nil,
                lastModified: nil,
                ssoHeader: nil
            )
        }
        let executor = SearchShardExecutor(
            client: client,
            shardRepository: SyncShardRepository(vault: fixture.vault),
            clock: { fixture.date }
        )
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .involves
        )

        try await executor.execute(
            query: query,
            range: SearchTimeRange(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 120)
            ),
            streamID: fixture.streamID,
            accountID: fixture.accountID,
            accessibleRepositoryNames: [],
            handlePage: { _, _, _ in }
        )

        let shards = try await SyncShardRepository(vault: fixture.vault).shards(
            for: fixture.streamID,
            accountID: fixture.accountID
        )
        XCTAssertEqual(shards.count, 3)
        XCTAssertTrue(shards.allSatisfy { $0.state == .completed })
        XCTAssertEqual(
            shards.filter { $0.pageCursor == "1" }.count,
            2
        )
    }
}

private actor SearchClient: GitHubIssueSearchExecuting {
    typealias ResponseFactory = @Sendable (
        GitHubIssueSearchQuery,
        Int
    ) -> GitHubResponse<GitHubIssueSearchPage>

    private let responseFactory: ResponseFactory

    init(responseFactory: @escaping ResponseFactory) {
        self.responseFactory = responseFactory
    }

    func searchResponse(
        _ query: GitHubIssueSearchQuery,
        page: Int
    ) async throws -> GitHubResponse<GitHubIssueSearchPage> {
        responseFactory(query, page)
    }
}

private final class Fixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "github")!
    let streamID = SyncStreamID(rawValue: "issues-discovery")!
    let credentialRevision = CredentialRevision(rawValue: "credential-1")!
    let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!
    let date = Date(timeIntervalSinceReferenceDate: 1_000)
    let vault: AccountVault

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
        let access = OrganizationAccess(
            accountID: accountID,
            organizationID: organizationID,
            state: .available,
            capabilityRevision: capabilityRevision,
            capabilities: [],
            checkedAt: date
        )
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(account, credentialRevision: credentialRevision)
        try await accounts.save(organization, access: access, selectedAt: date)
        try await CoverageRepository(vault: vault).save(
            CoverageRecord(
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                feature: .roleDiscovery,
                streamID: streamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: date
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
