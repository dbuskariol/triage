import Foundation
import GRDB
import XCTest
@testable import Triage

final class PullRequestReviewCandidateRepositoryTests: XCTestCase {
    func testFairSchedulerInterleavesSmallRepositoryBeforeSecondLargeRepositoryCandidate() async throws {
        let fixture = try await FairReviewFixture()
        defer { fixture.remove() }
        try await fixture.addRepository(id: "repo-a", nodeID: "REPO_A", name: "large")
        try await fixture.addRepository(id: "repo-b", nodeID: "REPO_B", name: "small")
        try await fixture.addPullRequest(repositoryID: "repo-a", nodeID: "PR_A1", number: 1)
        try await fixture.addPullRequest(repositoryID: "repo-a", nodeID: "PR_A2", number: 2)
        try await fixture.addPullRequest(repositoryID: "repo-a", nodeID: "PR_A3", number: 3)
        try await fixture.addPullRequest(repositoryID: "repo-b", nodeID: "PR_B1", number: 1)

        let inventory = try await fixture.repository().fairCandidates(
            scope: fixture.scope,
            streamID: fixture.streamID,
            feature: .reviews,
            limit: 3
        )

        XCTAssertEqual(inventory.candidates.map(\.nodeID.rawValue), ["PR_A1", "PR_B1", "PR_A2"])
        XCTAssertTrue(inventory.hasRemainingCandidates)
    }

    func testScheduleOrderIsDeterministicAndPersistsAcrossRepositoryRestart() async throws {
        let fixture = try await FairReviewFixture()
        defer { fixture.remove() }
        try await fixture.addRepository(id: "repo-a", nodeID: "REPO_A", name: "large")
        try await fixture.addRepository(id: "repo-b", nodeID: "REPO_B", name: "small")
        try await fixture.addPullRequest(repositoryID: "repo-a", nodeID: "PR_A1", number: 1)
        try await fixture.addPullRequest(repositoryID: "repo-a", nodeID: "PR_A2", number: 2)
        try await fixture.addPullRequest(repositoryID: "repo-b", nodeID: "PR_B1", number: 1)

        let repository = fixture.repository()
        let first = try await repository.fairCandidates(
            scope: fixture.scope,
            streamID: fixture.streamID,
            feature: .reviews,
            limit: 1
        )
        let repeated = try await repository.fairCandidates(
            scope: fixture.scope,
            streamID: fixture.streamID,
            feature: .reviews,
            limit: 1
        )
        XCTAssertEqual(first.candidates.map(\.nodeID), repeated.candidates.map(\.nodeID))

        let firstCandidate = try XCTUnwrap(first.candidates.first)
        try await fixture.advance(firstCandidate, feature: .reviews)
        let restartedRepository = try await fixture.reopenedRepository()
        let afterRestart = try await restartedRepository.fairCandidates(
            scope: fixture.scope,
            streamID: fixture.streamID,
            feature: .reviews,
            limit: 1
        )

        XCTAssertEqual(afterRestart.candidates.map(\.nodeID.rawValue), ["PR_B1"])
        XCTAssertTrue(afterRestart.hasRemainingCandidates)
    }

    func testEmptyAndInaccessiblePullRequestsDoNotCreateCandidatesOrCompletionClaims() async throws {
        let fixture = try await FairReviewFixture()
        defer { fixture.remove() }
        try await fixture.addRepository(id: "repo-a", nodeID: "REPO_A", name: "private")
        try await fixture.addPullRequest(
            repositoryID: "repo-a",
            nodeID: "PR_INACCESSIBLE",
            number: 1,
            accessibility: .inaccessible
        )

        let inventory = try await fixture.repository().fairCandidates(
            scope: fixture.scope,
            streamID: fixture.streamID,
            feature: .reviews,
            limit: 50
        )

        XCTAssertTrue(inventory.candidates.isEmpty)
        XCTAssertFalse(inventory.hasRemainingCandidates)
        XCTAssertTrue(inventory.hasBlockedKnownCandidates)
        let state = try await fixture.scheduleState()
        XCTAssertEqual(state.streamStatus, .partial)
        XCTAssertEqual(state.shardCount, 0)
    }

    func testRevokedRepositoryAccessExcludesRetainedPullRequests() async throws {
        let fixture = try await FairReviewFixture()
        defer { fixture.remove() }
        try await fixture.addRepository(id: "repo-a", nodeID: "REPO_A", name: "revoked")
        try await fixture.addRepository(id: "repo-b", nodeID: "REPO_B", name: "available")
        try await fixture.addPullRequest(repositoryID: "repo-a", nodeID: "PR_REVOKED", number: 1)
        try await fixture.addPullRequest(repositoryID: "repo-b", nodeID: "PR_AVAILABLE", number: 1)
        try await fixture.setRepositoryAccess(id: "repo-a", state: "revoked")

        let inventory = try await fixture.repository().fairCandidates(
            scope: fixture.scope,
            streamID: fixture.streamID,
            feature: .reviews,
            limit: 10
        )

        XCTAssertEqual(inventory.candidates.map(\.nodeID.rawValue), ["PR_AVAILABLE"])
        XCTAssertFalse(inventory.hasRemainingCandidates)
        XCTAssertTrue(inventory.hasBlockedKnownCandidates)
    }

    func testMissingOrFeatureMismatchedScheduleStreamFailsClosed() async throws {
        let fixture = try await FairReviewFixture(seedReviewStream: false)
        defer { fixture.remove() }
        try await fixture.addRepository(id: "repo-a", nodeID: "REPO_A", name: "repo")
        try await fixture.addPullRequest(repositoryID: "repo-a", nodeID: "PR_A1", number: 1)

        do {
            _ = try await fixture.repository().fairCandidates(
                scope: fixture.scope,
                streamID: fixture.streamID,
                feature: .reviews,
                limit: 1
            )
            XCTFail("Expected the caller-owned stream requirement to fail closed.")
        } catch let error as PullRequestReviewCandidateRepositoryError {
            XCTAssertEqual(error, .missingScheduleStream)
        }

        try await fixture.seedStream(feature: .reviewThreads)
        do {
            _ = try await fixture.repository().fairCandidates(
                scope: fixture.scope,
                streamID: fixture.streamID,
                feature: .reviews,
                limit: 1
            )
            XCTFail("Expected a mismatched feature stream to fail closed.")
        } catch let error as PullRequestReviewCandidateRepositoryError {
            XCTAssertEqual(error, .invalidScheduleScope)
        }
    }

    func testStaleScopeFailsBeforeCreatingSchedulerState() async throws {
        let fixture = try await FairReviewFixture()
        defer { fixture.remove() }
        try await fixture.addRepository(id: "repo-a", nodeID: "REPO_A", name: "repo")
        try await fixture.addPullRequest(repositoryID: "repo-a", nodeID: "PR_A1", number: 1)
        try await fixture.rotateCredential()

        do {
            _ = try await fixture.repository().fairCandidates(
                scope: fixture.scope,
                streamID: fixture.streamID,
                feature: .reviews,
                limit: 1
            )
            XCTFail("Expected stale scope rejection.")
        } catch let error as OrganizationSchedulerStateRepositoryError {
            XCTAssertEqual(error, .staleSynchronizationScope)
        }

        let state = try await fixture.scheduleState()
        XCTAssertEqual(state.shardCount, 0)
    }
}

private final class FairReviewFixture: @unchecked Sendable {
    struct ScheduleState {
        let streamStatus: CoverageStatus?
        let shardCount: Int
    }

    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "org")!
    let vaultKey: VaultKey
    let vault: AccountVault
    let date = Date(timeIntervalSinceReferenceDate: 1_000)
    let streamID = SyncStreamID(rawValue: "fair-review-test")!

    var scope: SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
    }

    init(seedReviewStream: Bool = true) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        vaultKey = try VaultKey.generate()
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: vaultKey
        )
        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: GitHubNodeID(rawValue: "USER_1")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: date,
                lastValidatedAt: date
            ),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await AccountRepository(vault: vault).save(
            GitHubOrganization(
                id: organizationID,
                githubOrganizationID: 1,
                nodeID: GitHubNodeID(rawValue: "ORG_1")!,
                login: "acme"
            ),
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: date
            ),
            selectedAt: date
        )
        if seedReviewStream {
            try await seedStream(feature: .reviews)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func repository() -> PullRequestReviewCandidateRepository {
        PullRequestReviewCandidateRepository(vault: vault)
    }

    func reopenedRepository() async throws -> PullRequestReviewCandidateRepository {
        let reopened = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: vaultKey
        )
        return PullRequestReviewCandidateRepository(vault: reopened)
    }

    func addRepository(id: String, nodeID: String, name: String) async throws {
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login, name,
                        is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, 1, 0, 0, ?, ?, NULL)
                    """,
                arguments: [
                    id, organizationID.rawValue, "github-\(id)", nodeID, "acme", name,
                    "https://github.com/acme/\(name)", Self.milliseconds(date)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_repository_access (account_id, repository_id, access_state, observed_at_ms)
                    VALUES (?, ?, 'available', ?)
                    """,
                arguments: [accountID.rawValue, id, Self.milliseconds(date)]
            )
        }
    }

    func setRepositoryAccess(id: String, state: String) async throws {
        try await vault.write { database in
            try database.execute(
                sql: """
                    UPDATE account_repository_access
                    SET access_state = ?, observed_at_ms = ?
                    WHERE account_id = ? AND repository_id = ?
                    """,
                arguments: [state, Self.milliseconds(date), accountID.rawValue, id]
            )
        }
    }

    func seedStream(feature: CoverageFeature) async throws {
        try await SyncStreamRepository(vault: vault).save(
            SyncStream(
                id: streamID,
                accountID: accountID,
                organizationID: organizationID,
                feature: feature,
                highWater: nil,
                lastSuccessfulAt: nil,
                lastAttemptAt: date,
                status: .partial,
                failureDetail: nil
            )
        )
    }

    func addPullRequest(
        repositoryID: String,
        nodeID: String,
        number: Int,
        accessibility: GitHubNodeAccessibility = .accessible
    ) async throws {
        let node = NormalizedGitHubNode(
            nodeID: GitHubNodeID(rawValue: nodeID)!,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: RepositoryID(rawValue: repositoryID)!,
            kind: .pullRequest,
            numericID: "github-\(nodeID)",
            number: number,
            title: nodeID,
            state: .open,
            url: URL(string: "https://github.com/acme/repo/pull/\(number)")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: date,
            updatedAt: date,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "revision-\(nodeID)",
            observedAt: date,
            accessibility: accessibility
        )
        try await GitHubNodeDetailsRepository(vault: vault).save(
            HydratedGitHubNode(
                node: node,
                details: .pullRequest(
                    isDraft: false,
                    mergeableState: nil,
                    headRef: "feature",
                    baseRef: "main",
                    reviewDecision: nil,
                    assigneeNodeIDs: [],
                    labelNodeIDs: [],
                    labelNames: []
                )
            ),
            accountID: accountID,
            observedAt: date
        )
    }

    func advance(
        _ candidate: PullRequestReviewCandidate,
        feature: CoverageFeature
    ) async throws {
        try await repository().writeTransaction(accountID: accountID) { database in
            try PullRequestReviewCandidateRepository.advanceFairSchedule(
                after: candidate,
                scope: scope,
                streamID: streamID,
                feature: feature,
                at: date,
                in: database
            )
        }
    }

    func rotateCredential() async throws {
        try await vault.write { database in
            try database.execute(
                sql: "UPDATE accounts SET credential_revision = 'credential-2' WHERE id = ?",
                arguments: [accountID.rawValue]
            )
        }
    }

    func scheduleState() async throws -> ScheduleState {
        try await vault.read { database in
            ScheduleState(
                streamStatus: try String.fetchOne(
                    database,
                    sql: "SELECT state FROM sync_streams WHERE id = ?",
                    arguments: [streamID.rawValue]
                ).flatMap(CoverageStatus.init(rawValue:)),
                shardCount: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sync_shards")!
            )
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
