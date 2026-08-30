import GRDB
import XCTest
@testable import Triage

final class RoleDiscoveryPlanTests: XCTestCase {
    func testPlanIncludesExactDocumentedRoleStreams() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let plan = try RoleDiscoveryPlan(
            organizationLogin: "github",
            userLogin: "octocat",
            now: Date(timeIntervalSince1970: 90 * 24 * 60 * 60),
            calendar: calendar
        )

        XCTAssertEqual(plan.streams.map(\.kind), RoleDiscoveryStreamKind.allCases)
        XCTAssertEqual(plan.streams.count, 11)
        XCTAssertEqual(
            plan.streams.first { $0.kind == .openReviewRequested }?.queries.first?.value,
            "org:github is:open review-requested:octocat"
        )
        XCTAssertEqual(
            plan.streams.first { $0.kind == .recentMergedReviewInvolvement }?.queries.first?.value,
            "org:github is:merged reviewed-by:octocat closed:>=1970-01-01"
        )
        XCTAssertTrue(
            plan.streams
                .filter { $0.kind.rawValue.hasPrefix("recent-") }
                .flatMap(\.queries)
                .allSatisfy { $0.value.contains("closed:>=") }
        )
    }

    func testTeamReviewStreamUsesOnlyConfirmedActiveVisibleTeams() throws {
        let activeTeam = TeamInventorySummary(
            id: TeamID(rawValue: "T_active")!,
            nodeID: GitHubNodeID(rawValue: "T_active")!,
            slug: "mac-apps",
            name: "Mac Apps",
            privacy: "closed",
            membershipState: "active"
        )
        let pendingTeam = TeamInventorySummary(
            id: TeamID(rawValue: "T_pending")!,
            nodeID: GitHubNodeID(rawValue: "T_pending")!,
            slug: "pending-team",
            name: "Pending Team",
            privacy: "secret",
            membershipState: "pending"
        )
        let plan = try RoleDiscoveryPlan(
            organizationLogin: "github",
            userLogin: "octocat",
            teams: [pendingTeam, activeTeam],
            now: Date(timeIntervalSince1970: 1_000_000)
        )

        let stream = try XCTUnwrap(
            plan.streams.first { $0.kind == .openTeamReviewRequested }
        )
        XCTAssertEqual(stream.queries.count, 1)
        XCTAssertEqual(
            stream.queries.first?.value,
            "org:github is:open team-review-requested:github/mac-apps"
        )
        XCTAssertEqual(
            stream.streamID(parent: SyncStreamID(rawValue: "role-org")!).rawValue,
            "role-org-open-team-review-requested"
        )
    }

    func testSourceSpecificFailureDoesNotPreventIndependentRoleStream() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".role-stream-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "org-1")!
        let credentialRevision = CredentialRevision(rawValue: "credential-1")!
        let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_1")!,
            login: "github"
        )
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: credentialRevision
        )
        try await AccountRepository(vault: vault).save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: observedAt
            ),
            selectedAt: observedAt
        )
        let plan = try RoleDiscoveryPlan(
            organizationLogin: organization.login,
            userLogin: account.login,
            now: observedAt
        )
        let assigned = try XCTUnwrap(plan.streams.first { $0.kind == .openAssigned })
        let authored = try XCTUnwrap(plan.streams.first { $0.kind == .openAuthored })
        let selectedStreams = [assigned, authored]
        let parentStreamID = SyncStreamID(rawValue: "role-org-1")!
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 1_000),
            end: observedAt
        )
        for stream in selectedStreams {
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
                    feature: .roleDiscovery,
                    streamID: stream.streamID(parent: parentStreamID),
                    intervalStart: range.start,
                    intervalEnd: range.end,
                    credentialRevision: credentialRevision,
                    capabilityRevision: capabilityRevision,
                    status: .partial,
                    lastSuccessfulAt: nil,
                    failureDetail: nil
                ),
                attemptedAt: observedAt
            )
        }
        let client = RoleIsolationSearchClient()
        let recorder = RoleOutcomeRecorder()

        do {
            _ = try await RoleDiscoverySynchronizer(
                searchClient: client,
                workItemRepository: WorkItemRepository(vault: vault),
                shardRepository: SyncShardRepository(vault: vault),
                clock: { observedAt }
            ).synchronize(
                plan: plan,
                accountID: accountID,
                organizationID: organizationID,
                githubOrganizationID: organization.githubOrganizationID,
                streamID: parentStreamID,
                searchRange: range,
                accessibleRepositoryNames: [],
                repositoryID: { _ in nil },
                streams: selectedStreams,
                recordStreamOutcome: { stream, outcome in
                    await recorder.record(stream: stream.kind, outcome: outcome)
                }
            )
            XCTFail("Expected the first source-specific failure to remain visible.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.kind, .notFound)
        }

        let requestedRelationships = await client.requestedRelationships()
        XCTAssertEqual(requestedRelationships, [.assigned, .authored])
        let outcomes = await recorder.outcomes()
        XCTAssertEqual(outcomes.map(\.stream), [.openAssigned, .openAuthored])
        XCTAssertEqual(outcomes.map(\.outcome.status), [.unavailable, .complete])
    }

    func testSearchSynchronizationCreatesCandidateWithoutAuthoritativeRelationsOrReasons() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".role-candidate-authority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "org-1")!
        let repositoryID = RepositoryID(rawValue: "repo-1")!
        let credentialRevision = CredentialRevision(rawValue: "credential-1")!
        let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_1")!,
            login: "github"
        )
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: credentialRevision
        )
        try await AccountRepository(vault: vault).save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: observedAt
            ),
            selectedAt: observedAt
        )
        try await insertRoleDiscoveryRepository(
            into: vault,
            organizationID: organizationID,
            repositoryID: repositoryID,
            observedAt: observedAt
        )
        let parentStreamID = SyncStreamID(rawValue: "role-org-1")!
        let plan = try RoleDiscoveryPlan(
            organizationLogin: organization.login,
            userLogin: account.login,
            now: observedAt
        )
        let stream = try XCTUnwrap(plan.streams.first { $0.kind == .openAssigned })
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 1_000),
            end: observedAt
        )
        try await CoverageRepository(vault: vault).save(
            CoverageRecord(
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                feature: .roleDiscovery,
                streamID: stream.streamID(parent: parentStreamID),
                intervalStart: range.start,
                intervalEnd: range.end,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: observedAt
        )
        let body = Data(
            """
            {"total_count":1,"incomplete_results":false,"items":[{"id":1,"node_id":"I_1","number":1,"title":"Candidate only","state":"open","html_url":"https://github.com/github/triage/issues/1","created_at":"1970-01-01T00:16:40Z","updated_at":"1970-01-01T00:33:20Z","closed_at":null,"repository_url":"https://api.github.com/repos/github/triage"}]}
            """.utf8
        )
        let searchClient = GitHubIssueSearchClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: RoleSearchSession(body: body)),
                credential: SecretValue("token")
            )
        )

        let result = try await RoleDiscoverySynchronizer(
            searchClient: searchClient,
            workItemRepository: WorkItemRepository(vault: vault),
            shardRepository: SyncShardRepository(vault: vault),
            clock: { observedAt }
        ).synchronize(
            plan: plan,
            accountID: accountID,
            organizationID: organizationID,
            githubOrganizationID: organization.githubOrganizationID,
            streamID: parentStreamID,
            searchRange: range,
            accessibleRepositoryNames: ["github/triage"],
            repositoryID: { _ in repositoryID },
            streams: [stream]
        )

        XCTAssertEqual(result.candidateNodeIDs, [GitHubNodeID(rawValue: "I_1")!])
        let workItems = try await WorkItemRepository(vault: vault).fetch(
            accountID: accountID,
            organizationID: organizationID
        )
        let workItem = try XCTUnwrap(workItems.first)
        XCTAssertTrue(workItem.relations.isEmpty)
        XCTAssertTrue(workItem.attentionReasons.isEmpty)
        XCTAssertFalse(workItem.isVisibleInInbox(at: observedAt))
        let snapshots = try await RawAPISnapshotRepository(vault: vault).snapshots(for: accountID)
        XCTAssertEqual(snapshots.count, 1)
    }
}

private func insertRoleDiscoveryRepository(
    into vault: AccountVault,
    organizationID: OrganizationID,
    repositoryID: RepositoryID,
    observedAt: Date
) async throws {
    let milliseconds = Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
    try await vault.write { database in
        try database.execute(
            sql: """
                INSERT INTO repositories (
                    id, organization_id, github_repository_id, github_node_id, owner_login, name,
                    is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                ) VALUES (?, ?, '3', 'R_1', 'github', 'triage', 1, 0, 0, ?, ?, NULL)
                """,
            arguments: [
                repositoryID.rawValue,
                organizationID.rawValue,
                "https://github.com/github/triage",
                milliseconds
            ]
        )
    }
}

private actor RoleSearchSession: HTTPSession {
    let body: Data

    init(body: Data) {
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private actor RoleIsolationSearchClient: GitHubIssueSearchExecuting {
    private var relationships = [GitHubIssueSearchRelationship]()

    func searchResponse(
        _ query: GitHubIssueSearchQuery,
        page _: Int
    ) async throws -> GitHubResponse<GitHubIssueSearchPage> {
        relationships.append(query.relationship)
        if case .assigned = query.relationship {
            throw GitHubFailure(kind: .notFound, statusCode: 404)
        }
        return GitHubResponse(
            value: GitHubIssueSearchPage(
                totalCount: 0,
                incompleteResults: false,
                items: []
            ),
            payload: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8),
            etag: nil,
            lastModified: nil,
            ssoHeader: nil
        )
    }

    func requestedRelationships() -> [GitHubIssueSearchRelationship] {
        relationships
    }
}

private actor RoleOutcomeRecorder {
    struct Entry: Sendable {
        let stream: RoleDiscoveryStreamKind
        let outcome: RoleDiscoveryStreamOutcome
    }

    private var entries = [Entry]()

    func record(stream: RoleDiscoveryStreamKind, outcome: RoleDiscoveryStreamOutcome) {
        entries.append(Entry(stream: stream, outcome: outcome))
    }

    func outcomes() -> [Entry] {
        entries
    }
}
