import Foundation
import XCTest
@testable import Triage

final class OrganizationInventoryRefreshServiceTests: XCTestCase {
    func testRepositorySuccessSurvivesIndependentTeamFailure() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 200, body: fixture.repositoryPayload()),
            .http(
                statusCode: 403,
                body: Data(#"{"message":"forbidden"}"#.utf8),
                headers: ["X-GitHub-SSO": "partial-results; organizations=999"]
            )
        ])
        let service = try fixture.service(session: session)

        let result = try await service.refreshInventory(
            account: fixture.account,
            organization: fixture.organization
        )

        guard case let .success(summaries, repositoryCoverage) = result.repositories else {
            return XCTFail("Repository inventory should succeed.")
        }
        XCTAssertEqual(summaries.map(\.name), ["repo"])
        XCTAssertEqual(repositoryCoverage.status, .complete)
        let persistedRepositoryCoverage = try await fixture.coverage(feature: .repositories)
        XCTAssertEqual(repositoryCoverage, persistedRepositoryCoverage)

        guard case let .failure(classification, teamCoverage) = result.teams else {
            return XCTFail("Team inventory should return its own failure outcome.")
        }
        XCTAssertEqual(classification, .unavailableOrPermission)
        XCTAssertEqual(teamCoverage.status, .unavailable)
        let repositories = try await fixture.repositories()
        let paths = await session.paths()
        XCTAssertEqual(repositories.map(\.name), ["repo"])
        XCTAssertEqual(paths, ["/orgs/acme/repos", "/orgs/acme/teams"])
    }

    func testRepositoryFailureStillAttemptsSuccessfulTeamsWithoutFabricatingRepositories() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 500, body: Data(#"{"message":"unavailable"}"#.utf8)),
            .http(statusCode: 200, body: Data("[]".utf8))
        ])
        let service = try fixture.service(session: session)

        let result = try await service.refreshInventory(
            account: fixture.account,
            organization: fixture.organization
        )

        guard case let .failure(classification, coverage) = result.repositories else {
            return XCTFail("Repository failure must remain explicit.")
        }
        XCTAssertEqual(classification, .failed)
        XCTAssertEqual(coverage.status, .failed)
        let repositories = try await fixture.repositories()
        XCTAssertTrue(repositories.isEmpty)

        guard case let .success(teams, teamCoverage) = result.teams else {
            return XCTFail("Teams should still be attempted after repository failure.")
        }
        XCTAssertTrue(teams.isEmpty)
        XCTAssertEqual(teamCoverage.status, .complete)
        let paths = await session.paths()
        XCTAssertEqual(paths, ["/orgs/acme/repos", "/orgs/acme/teams"])
    }

    func testRepositorySSOFailureReturnsScopedTransientRecoveryAndStillCommitsTeams() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let recoveryURL = URL(string: "https://github.com/orgs/acme/sso-inventory-recovery")!
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 403,
                body: Data(#"{"message":"SSO required"}"#.utf8),
                headers: ["X-GitHub-SSO": "required; url=\(recoveryURL.absoluteString)"]
            ),
            .http(statusCode: 200, body: Data("[]".utf8))
        ])

        let result = try await fixture.service(session: session).refreshInventory(
            account: fixture.account,
            organization: fixture.organization
        )

        guard case let .failure(.ssoRequired(header), repositoryCoverage) = result.repositories else {
            return XCTFail("Repository SSO must retain its selected-organization recovery header in memory.")
        }
        XCTAssertEqual(header, .authorizationRequired(recoveryURL))
        XCTAssertEqual(repositoryCoverage.status, .requiresSSO)
        XCTAssertNil(repositoryCoverage.intervalStart)
        XCTAssertNil(repositoryCoverage.intervalEnd)
        XCTAssertFalse(repositoryCoverage.failureDetail?.contains(recoveryURL.absoluteString) == true)
        guard case let .success(teams, teamCoverage) = result.teams else {
            return XCTFail("An independent team refresh should still succeed.")
        }
        XCTAssertTrue(teams.isEmpty)
        XCTAssertEqual(teamCoverage.status, .complete)
    }

    func testUnknownTeamMembershipRetainsPriorMembershipAndReturnsPartialOutcome() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        try await fixture.seedActiveTeamMembership()
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 200, body: Data("[]".utf8)),
            .http(statusCode: 200, body: fixture.changedTeamPayload()),
            .http(statusCode: 404, body: Data(#"{"message":"hidden"}"#.utf8))
        ])
        let service = try fixture.service(session: session)

        let result = try await service.refreshInventory(
            account: fixture.account,
            organization: fixture.organization
        )

        guard case let .failure(classification, coverage) = result.teams else {
            return XCTFail("Hidden team membership must not be treated as authoritative non-membership.")
        }
        XCTAssertEqual(classification, .partial)
        XCTAssertEqual(coverage.status, .partial)
        let teams = try await fixture.teams()
        XCTAssertEqual(teams.map(\.id), [TeamID(rawValue: "T_1")!])
        XCTAssertEqual(teams.map(\.name), ["Triage"])
        XCTAssertEqual(teams.first?.membershipState, "active")
    }

    func testCancellationDuringTeamRefreshPropagatesAfterRepositoryCommit() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 200, body: fixture.repositoryPayload()),
            .cancellation
        ])
        let service = try fixture.service(session: session)

        do {
            _ = try await service.refreshInventory(
                account: fixture.account,
                organization: fixture.organization
            )
            XCTFail("Cancellation must propagate instead of becoming a stream failure outcome.")
        } catch is CancellationError {
            // Expected.
        }

        let repositories = try await fixture.repositories()
        let repositoryCoverage = try await fixture.coverage(feature: .repositories)
        let paths = await session.paths()
        XCTAssertEqual(repositories.map(\.name), ["repo"])
        XCTAssertEqual(repositoryCoverage.status, .complete)
        XCTAssertEqual(paths, ["/orgs/acme/repos", "/orgs/acme/teams"])
    }

    func testRepositoryCancellationDoesNotStartTeams() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .httpAndCancel(statusCode: 200, body: fixture.repositoryPayload())
        ])
        let service = try fixture.service(session: session)

        do {
            _ = try await service.refreshInventory(
                account: fixture.account,
                organization: fixture.organization
            )
            XCTFail("Cancellation must propagate.")
        } catch is CancellationError {
            // Expected.
        }

        let paths = await session.paths()
        let repositories = try await fixture.repositories()
        let coverage = try await fixture.coverage(feature: .repositories)
        XCTAssertEqual(paths, ["/orgs/acme/repos"])
        XCTAssertTrue(repositories.isEmpty)
        XCTAssertEqual(coverage.status, .partial)
        XCTAssertNil(coverage.intervalStart)
        XCTAssertNil(coverage.intervalEnd)
    }
}

private final class OrganizationInventoryFixture: @unchecked Sendable {
    let root: URL
    let registry: VaultRegistry
    let vaultKey: VaultKey
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let observedAt = Date(timeIntervalSinceReferenceDate: 10_000)

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".triage-organization-inventory-\(UUID().uuidString)", isDirectory: true)
        registry = try VaultRegistry(rootDirectory: root)
        vaultKey = try VaultKey.generate()
        let accountID = AccountID.make()
        vault = try await registry.open(accountID: accountID, vaultKey: vaultKey)
        account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt,
            lastValidatedAt: observedAt
        )
        organization = GitHubOrganization(
            id: OrganizationID(rawValue: "acme")!,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_2")!,
            login: "acme"
        )
        let accountRepository = AccountRepository(vault: vault)
        try await accountRepository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await accountRepository.save(
            organization,
            access: OrganizationAccess(
                accountID: account.id,
                organizationID: organization.id,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: observedAt
            )
        )
    }

    func service(session: ScriptedInventorySession) throws -> OrganizationInventoryRefreshService {
        let client = GitHubRepositoryTeamClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: session),
                credential: SecretValue("test-token")
            )
        )
        return OrganizationInventoryRefreshService(
            vaultRegistry: registry,
            vaultKeyReader: { _ in self.vaultKey },
            repositoryTeamClientFactory: { _, _, _ in client },
            clock: { self.observedAt }
        )
    }

    func repositories() async throws -> [RepositorySummary] {
        try await RepositoryInventoryRepository(vault: vault).repositories(
            accountID: account.id,
            organization: organization
        )
    }

    func teams() async throws -> [TeamInventorySummary] {
        try await TeamInventoryRepository(vault: vault).teams(
            accountID: account.id,
            organization: organization
        )
    }

    func coverage(feature: CoverageFeature) async throws -> CoverageRecord {
        guard let coverage = try await CoverageRepository(vault: vault).records(
            for: account.id,
            organizationID: organization.id
        ).first(where: { $0.feature == feature }) else {
            throw OrganizationInventoryFixtureError.missingCoverage
        }
        return coverage
    }

    func seedActiveTeamMembership() async throws {
        let response = GitHubResponse(
            value: GitHubTeamMembershipDTO(state: "active", role: "member"),
            payload: Data(#"{"state":"active","role":"member"}"#.utf8),
            etag: nil,
            lastModified: nil,
            ssoHeader: nil
        )
        _ = try await TeamInventoryRepository(vault: vault).replace(
            teams: [team()],
            memberships: [
                TeamMembershipObservation(
                    teamID: TeamID(rawValue: "T_1")!,
                    membership: .member(response)
                )
            ],
            accountID: account.id,
            organization: organization,
            observedAt: observedAt
        )
    }

    func repositoryPayload() -> Data {
        Data(
            #"[{"id":1,"node_id":"R_1","name":"repo","private":true,"archived":false,"has_discussions":true,"html_url":"https://github.com/acme/repo","updated_at":"2026-01-01T00:00:00Z","owner":{"login":"acme"}}]"#.utf8
        )
    }

    func teamPayload() -> Data {
        Data(#"[{"id":1,"node_id":"T_1","name":"Triage","slug":"triage","privacy":"closed"}]"#.utf8)
    }

    func changedTeamPayload() -> Data {
        Data(#"[{"id":2,"node_id":"T_2","name":"Replacement","slug":"replacement","privacy":"closed"}]"#.utf8)
    }

    func team() -> GitHubTeamDTO {
        GitHubTeamDTO(id: 1, nodeID: "T_1", name: "Triage", slug: "triage", privacy: "closed")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum OrganizationInventoryFixtureError: Error {
    case missingCoverage
}

private actor ScriptedInventorySession: HTTPSession {
    enum Response: Sendable {
        case http(statusCode: Int, body: Data, headers: [String: String] = [:])
        case httpAndCancel(statusCode: Int, body: Data, headers: [String: String] = [:])
        case cancellation
    }

    private var responses: [Response]
    private var requestedPaths = [String]()

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestedPaths.append(request.url!.path)
        guard !responses.isEmpty else {
            throw GitHubTransportError.unexpectedResponse
        }
        switch responses.removeFirst() {
        case let .http(statusCode, body, headers):
            return (
                body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: headers
                )!
            )
        case let .httpAndCancel(statusCode, body, headers):
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return (
                body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: headers
                )!
            )
        case .cancellation:
            throw CancellationError()
        }
    }

    func paths() -> [String] {
        requestedPaths
    }
}
